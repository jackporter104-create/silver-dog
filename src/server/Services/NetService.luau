--!strict
--[[
	NetService: the only entry point for client requests.

	Pipeline for every Action(stationId, option):
	  1. Type and shape validation (malformed payloads are dropped and count as strikes)
	  2. Station lookup against the authoritative layout
	  3. Guard rate limit, per player per station kind
	  4. Session loaded?
	  5. Server-side proximity check (character within the station radius)
	  6. EconomyService does the math and state change
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
local MAX_OPTION = 16
local KICK_STRIKES = 150 -- sustained, extreme spam only; normal over-clicking is just dropped

local KEY_BY_KIND: { [Types.StationKind]: string } = {
	Clam = "Click",
	Generator = "Purchase",
	ClickUpgrade = "Purchase",
	Investor = "Purchase",
	AutoClicker = "Purchase",
	Statue = "Purchase",
	Battery = "Battery",
	Evolution = "Evolution",
}

local guard = Guard.new({
	Click = { rate = 15, burst = 25 }, -- humans peak around 12-15 taps/s
	Purchase = { rate = 8, burst = 12 },
	Battery = { rate = 1, burst = 2 },
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

local function onAction(player: Player, stationId: unknown, option: unknown)
	if typeof(stationId) ~= "string" or #stationId == 0 or #stationId > MAX_ID_LENGTH then
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

	local parsedOption = 1
	if option ~= nil then
		if typeof(option) ~= "number" or option ~= option or option % 1 ~= 0 or option < 0 or option > MAX_OPTION then
			malformed(player)
			return
		end
		parsedOption = option
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
	EconomyService.handleAction(player, station, parsedOption)
end

function NetService.init()
	Net.get().Action.OnServerEvent:Connect(onAction)
	Players.PlayerRemoving:Connect(function(player)
		guard:removePlayer(player)
	end)
end

return NetService
