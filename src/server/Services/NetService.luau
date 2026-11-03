--!strict
--[[
	NetService: the only entry point for client requests.

	Pipeline for every Action(stationId):
	  1. Type and shape validation (malformed payloads are dropped and count as strikes)
	  2. Station lookup against the authoritative layout
	  3. Guard rate limit, per player per action kind
	  4. Session loaded?
	  5. Server-side proximity check against the pad in the player's OWN zone (hub pads: shared)
	  6. EconomyService rejects pads that are not revealed for this player yet
	  7. EconomyService does the math and state change
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Types = require(Shared.Types)
local Stations = require(Shared.Config.Stations)

local Guard = require(script.Parent.Parent.Modules.Guard)
local ArenaService = require(script.Parent.ArenaService)
local EconomyService = require(script.Parent.EconomyService)
local ExperimentService = require(script.Parent.ExperimentService)

local NetService = {}

local SYNC_REQUEST = "__sync"
local MAX_ID_LENGTH = 48
local KICK_STRIKES = 150 -- sustained, extreme spam only; normal over-sending is just dropped

local KEY_BY_KIND: { [Types.StationKind]: string } = {
	Deed = "Purchase",
	StandMain = "Run",
	Multiplier = "Purchase",
	Speed = "Purchase",
	Manager = "Purchase",
	Statue = "Purchase",
	Buff = "Buff",
	Evolve = "Evolution",
}

local guard = Guard.new({
	Run = { rate = 10, burst = 15 }, -- the client re-sends ~4/s while standing on a stand pad
	Purchase = { rate = 8, burst = 12 },
	Buff = { rate = 2, burst = 3 },
	Evolution = { rate = 0.5, burst = 1 },
	Sync = { rate = 0.2, burst = 2 },
	Malformed = { rate = 0.05, burst = 3 },
}, KICK_STRIKES, function(player: Player, key: string, strikes: number)
	warn(string.format("[NetService] %s (%d) exceeded %d strikes on %s; kicking", player.Name, player.UserId, strikes, key))
	player:Kick("Too many requests. Please rejoin!")
end)

local function malformed(player: Player)
	guard:allow(player, "Malformed")
end

local function onAction(player: Player, stationId: unknown, ...: unknown)
	if typeof(stationId) ~= "string" or #stationId == 0 or #stationId > MAX_ID_LENGTH or select("#", ...) > 0 then
		malformed(player)
		return
	end
	if stationId == SYNC_REQUEST then
		if guard:allow(player, "Sync") then
			EconomyService.resync(player)
			ExperimentService.push(player)
		end
		return
	end

	local station = Stations.BY_ID[stationId]
	if not station then
		malformed(player)
		return
	end
	if not guard:allow(player, KEY_BY_KIND[station.kind]) then
		return
	end
	if not EconomyService.isActive(player) then
		return
	end
	if not ArenaService.isNear(player, station) then
		return
	end
	EconomyService.handleAction(player, station)
end

function NetService.init()
	Net.get().Action.OnServerEvent:Connect(onAction)
	Players.PlayerRemoving:Connect(function(player)
		guard:removePlayer(player)
	end)
end

return NetService
