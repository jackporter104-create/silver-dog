--!strict
--[[
	DataSchema: converts between live PlayerData and the plain table stored in DataStores.

	* fromSaved() treats input as untrusted. It repairs each field independently, so one bad
	  field never wipes a whole profile, and it reports what it repaired.
	* validateSaved() is the gate before EVERY write. If it fails, the write is refused, so
	  corrupt data is never persisted.
	* Version 1 saves (generator/investor economy) are migrated by starting a fresh stand
	  economy. All-time earnings and processed receipts are kept.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BigNumber = require(Shared.BigNumber)
local Types = require(Shared.Types)
local EconomyMath = require(Shared.EconomyMath)
local Economy = require(Shared.Config.Economy)
local Evolution = require(Shared.Config.Evolution)
local Statues = require(Shared.Config.Statues)

type BigNumber = BigNumber.BigNumber
type PlayerData = Types.PlayerData

export type SavedStand = { level: number, multiplier: number, speed: number, managerHired: boolean, revealed: number }
export type SavedBuff = { unlocked: boolean, activeUntil: number, readyAt: number }

export type SavedData = {
	version: number,
	currency: { number },
	lifetimeEarned: { number },
	totalEarned: { number },
	bestCurrency: { number },
	stands: { [string]: SavedStand },
	buffs: { [string]: SavedBuff },
	evolution: { level: number, perks: { [string]: number } },
	statues: { [string]: boolean },
	lastOnline: number,
	totalRuns: number,
	starterPackClaimed: boolean,
	receipts: { [string]: number },
}

local DataSchema = {}

local MAX_INTEGER = 2 ^ 53

function DataSchema.default(): PlayerData
	return {
		version = Economy.DATA_VERSION,
		currency = BigNumber.ZERO,
		lifetimeEarned = BigNumber.ZERO,
		totalEarned = BigNumber.ZERO,
		bestCurrency = BigNumber.ZERO,
		stands = EconomyMath.startingStands(),
		buffs = {},
		evolution = { level = 1, perks = {} },
		statues = {},
		lastOnline = 0,
		totalRuns = 0,
		starterPackClaimed = false,
		receipts = {},
	}
end

local function isInteger(value: unknown, min: number, max: number): boolean
	return typeof(value) == "number" and value == value and value == math.floor(value) and value >= min and value <= max
end

local function readInteger(value: unknown, min: number, max: number, fallback: number, field: string, repairs: { string }): number
	if isInteger(value, min, max) then
		return value :: number
	end
	if value ~= nil then
		table.insert(repairs, field)
	end
	return fallback
end

local function readBig(value: unknown, field: string, repairs: { string }): BigNumber
	if value == nil then
		return BigNumber.ZERO
	end
	local parsed = BigNumber.deserialize(value)
	if parsed and not BigNumber.isNegative(parsed) then
		return parsed
	end
	table.insert(repairs, field)
	return BigNumber.ZERO
end

local function asTable(value: unknown): { [any]: any }?
	return if typeof(value) == "table" then value :: any else nil
end

local function readReceipts(raw: unknown, data: PlayerData)
	local receipts = asTable(raw)
	if receipts then
		for id, time in receipts do
			if typeof(id) == "string" and #id <= 64 and isInteger(time, 0, MAX_INTEGER) then
				data.receipts[id] = time
			end
		end
	end
end

-- Returns sanitized data and the list of fields that had to be repaired.
function DataSchema.fromSaved(raw: unknown): (PlayerData, { string })
	local data = DataSchema.default()
	local repairs: { string } = {}
	local t = asTable(raw)
	if not t then
		if raw ~= nil then
			table.insert(repairs, "<root>")
		end
		return data, repairs
	end

	if t.version ~= Economy.DATA_VERSION then
		-- v1 used a different economy. Start fresh, keep all-time stats and receipts.
		table.insert(repairs, "migrated from v" .. tostring(t.version))
		data.totalEarned = readBig(t.totalEarned, "totalEarned", repairs)
		data.starterPackClaimed = t.starterPackClaimed == true
		readReceipts(t.receipts, data)
		return data, repairs
	end

	data.currency = readBig(t.currency, "currency", repairs)
	data.lifetimeEarned = readBig(t.lifetimeEarned, "lifetimeEarned", repairs)
	data.totalEarned = readBig(t.totalEarned, "totalEarned", repairs)
	data.bestCurrency = BigNumber.max(readBig(t.bestCurrency, "bestCurrency", repairs), data.currency)
	data.lastOnline = readInteger(t.lastOnline, 0, MAX_INTEGER, 0, "lastOnline", repairs)
	data.totalRuns = readInteger(t.totalRuns, 0, MAX_INTEGER, 0, "totalRuns", repairs)
	data.starterPackClaimed = t.starterPackClaimed == true

	local stands = asTable(t.stands)
	if stands then
		for _, def in Economy.STANDS do
			local s = asTable(stands[def.id])
			if s then
				local level = readInteger(s.level, 0, 1, 0, def.id .. ".level", repairs)
				local multiplier = readInteger(s.multiplier, 0, Economy.MAX_MULTIPLIER_LEVEL, 0, def.id .. ".multiplier", repairs)
				local speed = readInteger(s.speed, 0, Economy.MAX_SPEED_LEVEL, 0, def.id .. ".speed", repairs)
				local managerHired = s.managerHired == true and level > 0
				-- Saves from before progressive pads have no `revealed`: derive it from upgrades.
				local derived = if managerHired or speed > 0 then 3 elseif multiplier > 0 then 2 elseif level > 0 then 1 else 0
				local revealed = if s.revealed == nil then derived else readInteger(s.revealed, 0, 3, derived, def.id .. ".revealed", repairs)
				data.stands[def.id] = {
					level = level,
					multiplier = multiplier,
					speed = speed,
					managerHired = managerHired,
					-- Never hide a pad the player has already used.
					revealed = if level > 0 then math.max(revealed, if managerHired or speed > 0 then 3 elseif multiplier > 0 then 2 else 0) else 0,
				}
			end
		end
	end
	-- The starting stand is always owned.
	local start = data.stands[Economy.STARTING_STAND]
	if not start or start.level == 0 then
		data.stands[Economy.STARTING_STAND] = EconomyMath.startingStands()[Economy.STARTING_STAND]
	end

	local buffs = asTable(t.buffs)
	if buffs then
		for _, def in Economy.BUFFS do
			local b = asTable(buffs[def.id])
			if b then
				data.buffs[def.id] = {
					unlocked = b.unlocked == true,
					activeUntil = readInteger(b.activeUntil, 0, MAX_INTEGER, 0, def.id .. ".activeUntil", repairs),
					readyAt = readInteger(b.readyAt, 0, MAX_INTEGER, 0, def.id .. ".readyAt", repairs),
				}
			end
		end
	end

	local evolution = asTable(t.evolution)
	if evolution then
		data.evolution.level = readInteger(evolution.level, 1, Evolution.MAX_LEVEL, 1, "evolution.level", repairs)
		local perks = asTable(evolution.perks)
		if perks then
			for _, perk in Evolution.PERKS do
				local stacks = readInteger(perks[perk.id], 0, Evolution.MAX_LEVEL, 0, "perks." .. perk.id, repairs)
				if stacks > 0 then
					data.evolution.perks[perk.id] = stacks
				end
			end
		end
	end

	local statues = asTable(t.statues)
	if statues then
		for _, statue in Statues.LIST do
			if statues[statue.id] == true then
				data.statues[statue.id] = true
			end
		end
	end

	readReceipts(t.receipts, data)
	return data, repairs
end

local function pruneReceipts(receipts: { [string]: number }): { [string]: number }
	local entries: { { id: string, time: number } } = {}
	for id, time in receipts do
		table.insert(entries, { id = id, time = time })
	end
	if #entries <= Economy.LIMITS.maxReceipts then
		return table.clone(receipts)
	end
	table.sort(entries, function(a, b)
		return a.time > b.time
	end)
	local kept: { [string]: number } = {}
	for i = 1, Economy.LIMITS.maxReceipts do
		kept[entries[i].id] = entries[i].time
	end
	return kept
end

function DataSchema.toSaved(data: PlayerData): SavedData
	local stands: { [string]: SavedStand } = {}
	for id, s in data.stands do
		stands[id] = { level = s.level, multiplier = s.multiplier, speed = s.speed, managerHired = s.managerHired, revealed = s.revealed }
	end
	local buffs: { [string]: SavedBuff } = {}
	for id, b in data.buffs do
		buffs[id] = { unlocked = b.unlocked, activeUntil = math.floor(b.activeUntil), readyAt = math.floor(b.readyAt) }
	end
	return {
		version = Economy.DATA_VERSION,
		currency = BigNumber.serialize(data.currency),
		lifetimeEarned = BigNumber.serialize(data.lifetimeEarned),
		totalEarned = BigNumber.serialize(data.totalEarned),
		bestCurrency = BigNumber.serialize(data.bestCurrency),
		stands = stands,
		buffs = buffs,
		evolution = { level = data.evolution.level, perks = table.clone(data.evolution.perks) },
		statues = table.clone(data.statues),
		lastOnline = data.lastOnline,
		totalRuns = data.totalRuns,
		starterPackClaimed = data.starterPackClaimed,
		receipts = pruneReceipts(data.receipts),
	}
end

local function validBig(value: { number }): boolean
	local parsed = BigNumber.deserialize(value)
	return parsed ~= nil and not BigNumber.isNegative(parsed) and #value == 2
end

-- Strict pre-write validation. Any failure aborts the save.
function DataSchema.validateSaved(saved: SavedData): (boolean, string?)
	if saved.version ~= Economy.DATA_VERSION then
		return false, "version"
	end
	for _, field in { "currency", "lifetimeEarned", "totalEarned", "bestCurrency" } do
		if not validBig((saved :: any)[field]) then
			return false, field
		end
	end
	if not isInteger(saved.lastOnline, 0, MAX_INTEGER) or not isInteger(saved.totalRuns, 0, MAX_INTEGER) then
		return false, "counters"
	end
	if typeof(saved.starterPackClaimed) ~= "boolean" then
		return false, "starterPackClaimed"
	end
	for id, s in saved.stands do
		if not Economy.STAND_BY_ID[id] then
			return false, "stands." .. tostring(id)
		end
		if
			not isInteger(s.level, 0, 1)
			or not isInteger(s.multiplier, 0, Economy.MAX_MULTIPLIER_LEVEL)
			or not isInteger(s.speed, 0, Economy.MAX_SPEED_LEVEL)
			or typeof(s.managerHired) ~= "boolean"
			or not isInteger(s.revealed, 0, 3)
		then
			return false, "stands." .. id
		end
	end
	for id, b in saved.buffs do
		if not Economy.BUFF_BY_ID[id] or typeof(b.unlocked) ~= "boolean" or not isInteger(b.activeUntil, 0, MAX_INTEGER) or not isInteger(b.readyAt, 0, MAX_INTEGER) then
			return false, "buffs." .. tostring(id)
		end
	end
	if not isInteger(saved.evolution.level, 1, Evolution.MAX_LEVEL) then
		return false, "evolution.level"
	end
	for id, stacks in saved.evolution.perks do
		if not Evolution.PERK_BY_ID[id] or not isInteger(stacks, 0, Evolution.MAX_LEVEL) then
			return false, "perks." .. tostring(id)
		end
	end
	for id, owned in saved.statues do
		if not Statues.BY_ID[id] or owned ~= true then
			return false, "statues." .. tostring(id)
		end
	end
	local receiptCount = 0
	for id, time in saved.receipts do
		receiptCount += 1
		if typeof(id) ~= "string" or not isInteger(time, 0, MAX_INTEGER) then
			return false, "receipts"
		end
	end
	if receiptCount > Economy.LIMITS.maxReceipts then
		return false, "receipts.count"
	end
	return true, nil
end

return DataSchema
