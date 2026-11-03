--!strict
--[[
	ExperimentService: deterministic A/B bucketing plus live UI overrides.

	* Bucket = FNV-1a(UserId .. ":" .. experimentKey) mod total weight. It is stable across
	  servers and never stored.
	* The resulting UiConfig goes to the client, which restyles the HUD on the fly.
	* Live overrides (for example from a DataStore key edited by staff) are polled, validated
	  and re-pushed to every player without a server restart.
	* Assignments are exposed as a player attribute for analytics joins.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Experiments = require(Shared.Config.Experiments)

type UiConfig = Types.UiConfig

local ExperimentService = {}

local LIVE_STORE = "OceanIdle_LiveConfig_v1"
local LIVE_KEY = "ui"
local POLL_INTERVAL = 120

local liveOverrides: Experiments.UiOverrides = {}
local assignments: { [Player]: { [string]: string } } = {}

local function fnv1a(text: string): number
	local hash = 2166136261
	for i = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, i))
		-- 32-bit multiply by the FNV prime (16777619) without losing precision.
		hash = (bit32.lshift(hash, 24) + bit32.lshift(hash, 8) + hash * 0x93) % 2 ^ 32
	end
	return hash
end

local function pickVariant(userId: number, experiment: Experiments.Experiment): Experiments.Variant
	local total = 0
	for _, variant in experiment.variants do
		total += variant.weight
	end
	local roll = fnv1a(userId .. ":" .. experiment.key) % math.max(total, 1)
	for _, variant in experiment.variants do
		roll -= variant.weight
		if roll < 0 then
			return variant
		end
	end
	return experiment.variants[1]
end

-- Validates any override (variants or live) against hard limits. Invalid fields are dropped.
local function sanitize(raw: any): Experiments.UiOverrides
	local result: Experiments.UiOverrides = {}
	if typeof(raw) ~= "table" then
		return result
	end
	local limits = Experiments.LIMITS
	if typeof(raw.tapButtonScale) == "number" and raw.tapButtonScale == raw.tapButtonScale then
		result.tapButtonScale = math.clamp(raw.tapButtonScale, limits.minTapScale, limits.maxTapScale)
	end
	if typeof(raw.accentColor) == "Color3" then
		result.accentColor = raw.accentColor
	elseif typeof(raw.accentColor) == "string" then
		local ok, color = pcall(Color3.fromHex, raw.accentColor)
		if ok then
			result.accentColor = color
		end
	end
	if typeof(raw.showPerNanosecond) == "boolean" then
		result.showPerNanosecond = raw.showPerNanosecond
	end
	if typeof(raw.compactHud) == "boolean" then
		result.compactHud = raw.compactHud
	end
	if raw.promptPosition == "Bottom" or raw.promptPosition == "Center" then
		result.promptPosition = raw.promptPosition
	end
	return result
end

local function apply(config: UiConfig, overrides: Experiments.UiOverrides)
	local clean = sanitize(overrides)
	if clean.tapButtonScale then
		config.tapButtonScale = clean.tapButtonScale
	end
	if clean.accentColor then
		config.accentColor = clean.accentColor
	end
	if clean.showPerNanosecond ~= nil then
		config.showPerNanosecond = clean.showPerNanosecond
	end
	if clean.compactHud ~= nil then
		config.compactHud = clean.compactHud
	end
	if clean.promptPosition then
		config.promptPosition = clean.promptPosition
	end
end

function ExperimentService.configFor(player: Player): UiConfig
	local config = table.clone(Experiments.UI_DEFAULTS) :: UiConfig
	local tags: { string } = {}
	local playerAssignments = assignments[player] or {}
	for _, experiment in Experiments.LIST do
		if experiment.enabled and #experiment.variants > 0 then
			local variant = pickVariant(player.UserId, experiment)
			playerAssignments[experiment.key] = variant.id
			apply(config, variant.ui)
			table.insert(tags, experiment.key .. "=" .. variant.id)
		end
	end
	assignments[player] = playerAssignments
	apply(config, liveOverrides)
	config.variant = table.concat(tags, ";")
	return config
end

function ExperimentService.push(player: Player)
	local config = ExperimentService.configFor(player)
	player:SetAttribute("Experiments", config.variant)
	Net.get().UiConfig:FireClient(player, config)
end

function ExperimentService.onPlayerReady(player: Player)
	ExperimentService.push(player)
	pcall(function()
		AnalyticsService:LogCustomEvent(player, "ExperimentExposure", 1, {
			[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = player:GetAttribute("Experiments") :: string,
		})
	end)
end

function ExperimentService.onPlayerRemoving(player: Player)
	assignments[player] = nil
end

-- Server-side API for live tuning (admin command, MessagingService handler, etc.).
function ExperimentService.setLiveOverrides(raw: any)
	liveOverrides = sanitize(raw)
	for _, player in Players:GetPlayers() do
		ExperimentService.push(player)
	end
end

function ExperimentService.init()
	if RunService:IsStudio() then
		return -- Avoid DataStore polling noise in Studio. Call setLiveOverrides manually instead.
	end
	task.spawn(function()
		local ok, liveStore = pcall(function()
			return DataStoreService:GetDataStore(LIVE_STORE)
		end)
		if not ok then
			return
		end
		local lastJson = ""
		while true do
			local fetched, value = pcall(function()
				return liveStore:GetAsync(LIVE_KEY)
			end)
			if fetched and value ~= nil then
				local encoded = game:GetService("HttpService"):JSONEncode(value)
				if encoded ~= lastJson then
					lastJson = encoded
					ExperimentService.setLiveOverrides(value)
				end
			end
			task.wait(POLL_INTERVAL)
		end
	end)
end

return ExperimentService
