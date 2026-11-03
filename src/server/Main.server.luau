--!strict
-- Server bootstrap: initialises services in dependency order and owns the player lifecycle.

local Players = game:GetService("Players")

local Services = script.Parent.Services
local DataService = require(Services.DataService)
local SeasonService = require(Services.SeasonService)
local ExperimentService = require(Services.ExperimentService)
local ArenaService = require(Services.ArenaService)
local EconomyService = require(Services.EconomyService)
local NetService = require(Services.NetService)
local MonetizationService = require(Services.MonetizationService)
local DevService = require(Services.DevService)

DataService.init()
SeasonService.init()
ExperimentService.init()
ArenaService.init()
EconomyService.init()
NetService.init()
MonetizationService.init()
DevService.init()

local function onPlayerAdded(player: Player)
	-- Claim a zone first so the character spawns in it while data loads.
	if not ArenaService.assignZone(player) then
		player:Kick("This ocean is full (8 reefs). Please join another server!")
		return
	end
	local data = DataService.loadAsync(player)
	if not data then
		ArenaService.releaseZone(player)
		if player:IsDescendantOf(Players) then
			player:Kick("We couldn't load your ocean safely. Please rejoin in a moment!")
		end
		return
	end
	if not player:IsDescendantOf(Players) then
		-- Left while loading: release the session lock we just took.
		DataService.saveAsync(player, true)
		DataService.unload(player)
		ArenaService.releaseZone(player)
		return
	end
	local entitlements = MonetizationService.resolveEntitlements(player)
	EconomyService.startSession(player, data, entitlements)
	ExperimentService.onPlayerReady(player)
end

local function onPlayerRemoving(player: Player)
	EconomyService.endSession(player)
	ExperimentService.onPlayerRemoving(player)
	DataService.saveAsync(player, true)
	DataService.unload(player)
	ArenaService.releaseZone(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

game:BindToClose(function()
	DataService.saveAllAndRelease()
end)

DataService.startAutosave()
