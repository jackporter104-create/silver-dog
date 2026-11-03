--!strict
--[[
	DataService: session-locked, validated persistence.

	* Every DataStore call is wrapped in pcall with exponential-backoff retries.
	* A session lock in the record stops two servers from writing the same profile, which
	  prevents item duplication and rollback.
	* DataSchema.validateSaved gates every write. Invalid data is never saved.
	* lastOnline is stamped with server os.time() and drives offline earnings. Client time
	  is never used.
	* In Studio without API access, it falls back to in-memory storage (with a warning).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("Shared").Types)
local DataSchema = require(script.Parent.Parent.Modules.DataSchema)

type PlayerData = Types.PlayerData

local DataService = {}

local STORE_NAME = "OceanIdle_Profiles_v1"
local BACKUP_STORE_NAME = "OceanIdle_Backups_v1"
local MAX_ATTEMPTS = 5
local LOCK_TIMEOUT = 180 -- seconds; stale locks from crashed servers are taken over
local LOCK_WAIT_ATTEMPTS = 6
local AUTOSAVE_INTERVAL = 60
local SESSION_ID = HttpService:GenerateGUID(false)

type Profile = {
	data: PlayerData,
	saving: boolean,
	lockLost: boolean,
	released: boolean,
}

local profiles: { [Player]: Profile } = {}
local store: DataStore? = nil
local backupStore: DataStore? = nil
local memoryStore: { [string]: any } = {}
local useMemory = false

local function keyFor(userId: number): string
	return "u_" .. userId
end

local function withRetries<T>(label: string, callback: () -> T): (boolean, T?)
	for attempt = 1, MAX_ATTEMPTS do
		local ok, result = pcall(callback)
		if ok then
			return true, result
		end
		warn(string.format("[DataService] %s failed (attempt %d/%d): %s", label, attempt, MAX_ATTEMPTS, tostring(result)))
		if attempt < MAX_ATTEMPTS then
			task.wait(math.min(2 ^ attempt, 16))
		end
	end
	return false, nil
end

-- UpdateAsync with a pure transform. Returning nil from the transform cancels the write.
local function update(key: string, transform: (any) -> any): boolean
	if useMemory then
		local result = transform(memoryStore[key])
		if result ~= nil then
			memoryStore[key] = result
		end
		return true
	end
	local activeStore = store
	assert(activeStore, "DataService not initialised")
	local ok = withRetries("UpdateAsync " .. key, function()
		return activeStore:UpdateAsync(key, transform)
	end)
	return ok
end

local function backupRaw(key: string, raw: unknown)
	local activeBackup = backupStore
	if useMemory or not activeBackup then
		return
	end
	local ok, err = pcall(function()
		activeBackup:SetAsync(key .. "_" .. os.time(), raw)
	end)
	if not ok then
		warn("[DataService] backup failed: " .. tostring(err))
	end
end

function DataService.init()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
		backupStore = DataStoreService:GetDataStore(BACKUP_STORE_NAME)
	end
	if RunService:IsStudio() then
		local probeOk = ok and pcall(function()
			(result :: DataStore):GetAsync("__probe")
		end)
		if not probeOk then
			useMemory = true
			warn("[DataService] DataStores unavailable in Studio. Using in-memory data (nothing persists).")
		end
	elseif not ok then
		error("[DataService] DataStoreService unavailable: " .. tostring(result))
	end
end

-- Loads and session-locks a profile. Returns nil if it could not be loaded safely.
function DataService.loadAsync(player: Player): PlayerData?
	local key = keyFor(player.UserId)
	for _ = 1, LOCK_WAIT_ATTEMPTS do
		local lockedElsewhere = false
		local raw: unknown = nil
		local ok = update(key, function(old: any): any
			lockedElsewhere = false
			raw = nil
			if old ~= nil and typeof(old) ~= "table" then
				-- Unreadable record: keep it untouched and load defaults in memory only.
				raw = old
				return nil
			end
			local session = if old then old.session else nil
			if typeof(session) == "table" and session.id ~= SESSION_ID and typeof(session.time) == "number" and os.time() - session.time < LOCK_TIMEOUT then
				lockedElsewhere = true
				return nil
			end
			raw = if old then old.data else nil
			local record = if old then old else {}
			record.session = { id = SESSION_ID, time = os.time() }
			return record
		end)
		if not ok then
			return nil
		end
		if not lockedElsewhere then
			if not player:IsDescendantOf(Players) then
				return nil
			end
			local data, repairs = DataSchema.fromSaved(raw)
			if #repairs > 0 then
				warn(string.format("[DataService] Repaired %d field(s) for %d: %s", #repairs, player.UserId, table.concat(repairs, ", ")))
				backupRaw(key, raw)
			end
			profiles[player] = { data = data, saving = false, lockLost = false, released = false }
			return data
		end
		task.wait(LOCK_TIMEOUT / LOCK_WAIT_ATTEMPTS)
		if not player:IsDescendantOf(Players) then
			return nil
		end
	end
	return nil
end

function DataService.get(player: Player): PlayerData?
	local profile = profiles[player]
	return if profile then profile.data else nil
end

-- Validates, then writes. `release` drops the session lock (on leave or shutdown).
function DataService.saveAsync(player: Player, release: boolean): boolean
	local profile = profiles[player]
	if not profile or profile.lockLost or profile.released then
		return false
	end
	while profile.saving do
		task.wait(0.1)
	end
	if profile.released then
		return false
	end
	profile.saving = true

	profile.data.lastOnline = os.time()
	local saved = DataSchema.toSaved(profile.data)
	local valid, reason = DataSchema.validateSaved(saved)
	if not valid then
		profile.saving = false
		warn(string.format("[DataService] Refusing to save invalid data for %d (field: %s)", player.UserId, tostring(reason)))
		return false
	end

	local lockLost = false
	local ok = update(keyFor(player.UserId), function(old: any): any
		lockLost = false
		local session = if typeof(old) == "table" then old.session else nil
		if typeof(session) == "table" and session.id ~= SESSION_ID then
			lockLost = true
			return nil
		end
		return {
			data = saved,
			session = if release then nil else { id = SESSION_ID, time = os.time() },
			savedAt = os.time(),
		}
	end)

	profile.saving = false
	if lockLost then
		profile.lockLost = true
		warn(string.format("[DataService] Session lock for %d taken by another server; saves disabled here", player.UserId))
		return false
	end
	if ok and release then
		profile.released = true
	end
	return ok
end

function DataService.unload(player: Player)
	profiles[player] = nil
end

function DataService.startAutosave()
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for player in profiles do
				task.spawn(DataService.saveAsync, player, false)
			end
		end
	end)
end

-- Saves and releases everyone on shutdown, waiting for all writes to finish.
function DataService.saveAllAndRelease()
	local pending = 0
	for player in profiles do
		pending += 1
		task.spawn(function()
			DataService.saveAsync(player, true)
			pending -= 1
		end)
	end
	local deadline = os.clock() + 25
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end

return DataService
