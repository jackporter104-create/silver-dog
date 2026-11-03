--!strict
--[[
	SeasonService: resolves the active season from server time, publishes its id to clients
	through a ReplicatedStorage attribute (used for visuals), and pushes economy modifiers
	to subscribers. Re-evaluates every minute, so events start and end without a restart.
	Studio/testing override: set ReplicatedStorage attribute "SeasonOverride" to a season id.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Seasons = require(Shared.Config.Seasons)

type SeasonDefinition = Types.SeasonDefinition

local SeasonService = {}

local ATTRIBUTE = "SeasonId"
local OVERRIDE_ATTRIBUTE = "SeasonOverride"
local CHECK_INTERVAL = 60

local current: SeasonDefinition = Seasons.get(Seasons.DEFAULT_ID)
local listeners: { (SeasonDefinition) -> () } = {}

local function resolve(): SeasonDefinition
	local override = ReplicatedStorage:GetAttribute(OVERRIDE_ATTRIBUTE)
	if typeof(override) == "string" and Seasons.BY_ID[override] then
		return Seasons.BY_ID[override]
	end
	return Seasons.resolve(os.time())
end

local function refresh()
	local season = resolve()
	if season.id == current.id and ReplicatedStorage:GetAttribute(ATTRIBUTE) == season.id then
		return
	end
	current = season
	ReplicatedStorage:SetAttribute(ATTRIBUTE, season.id)
	print("[SeasonService] Active season: " .. season.displayName)
	for _, listener in listeners do
		task.spawn(listener, season)
	end
end

function SeasonService.init()
	refresh()
	ReplicatedStorage:GetAttributeChangedSignal(OVERRIDE_ATTRIBUTE):Connect(refresh)
	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			refresh()
		end
	end)
end

function SeasonService.current(): SeasonDefinition
	return current
end

function SeasonService.modifiers(): Types.EconomyModifiers
	return current.economy
end

function SeasonService.onChanged(listener: (SeasonDefinition) -> ())
	table.insert(listeners, listener)
end

return SeasonService
