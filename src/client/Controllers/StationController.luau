--!strict
--[[
	StationController: physical interaction with floor pads (cheap distance checks at 10 Hz).

	  * Step on a pad: buys / activates once per step (step off and on again to repeat).
	  * Press E (or gamepad X) near a pad: same action, repeatable.
	  * Stand main pad of an owned, unmanaged stand: while you stand on it the stand keeps running.
	  * Evolve pads: stand still on the pad for Evolution.CONFIRM_SECONDS to evolve (no accidents).

	Only the player's OWN zone pads (resolved to world space from the "ZoneIndex" attribute) and the
	shared Hub pads are considered, and only pads that are revealed for the player, so prompts never
	show for other players' pads. Requests are intent-only (the station id). The server re-validates
	ownership, visibility, cost and distance against the player's own zone.
	Client throttles only keep requests under the server's Guard limits.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Signal = require(Shared.Signal)
local Stations = require(Shared.Config.Stations)
local Evolution = require(Shared.Config.Evolution)

local StateController = require(script.Parent.StateController)

type StationDef = Stations.StationDef

local StationController = {}

local SCAN_INTERVAL = 0.1
local RUN_INTERVAL = 0.25 -- re-send rate while standing on a stand pad (server Guard: 10/s)
local ACTION_INTERVAL = 0.2
local INTERACT_ACTION = "OceanInteract"

type Candidate = { station: StationDef, position: Vector3 }

local player = Players.LocalPlayer
local candidates: { Candidate } = {}
local nearest: StationDef? = nil
local standingOn: StationDef? = nil
local standingSince = 0
local evolveSent = false
local lastSent: { [string]: number } = {}

StationController.nearestChanged = Signal.new() :: Signal.Signal<StationDef?>
-- Fired whenever the player activates a pad (stepping on it or pressing E), for visual feedback.
StationController.stepped = Signal.new() :: Signal.Signal<StationDef>
-- Fired when the player activates the Shell Shop pad (client-only: opens the shop panel).
StationController.shopRequested = Signal.new() :: Signal.Signal<StationDef>

local function rootPosition(): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function send(station: StationDef, interval: number)
	local now = os.clock()
	if now - (lastSent[station.id] or 0) < interval then
		return
	end
	lastSent[station.id] = now
	Net.get().Action:FireServer(station.id)
end

-- True when standing on this stand pad runs the stand (owned and no manager yet).
local function isRunPad(station: StationDef): boolean
	if station.kind ~= "StandMain" then
		return false
	end
	local snap = StateController.snapshot()
	local stand = snap and snap.stands[station.target or ""]
	return stand ~= nil and stand.owned and not stand.managed and not stand.autoCollected
end

local function trigger(station: StationDef)
	StationController.stepped:Fire(station)
	if station.kind == "Evolve" then
		return -- evolving needs the hold-to-confirm on the pad
	elseif station.kind == "Shop" then
		StationController.shopRequested:Fire(station)
		return -- purchases go through Roblox prompts, never through the Action remote
	end
	send(station, ACTION_INTERVAL)
end

-- World positions of every pad this player can use: the Hub plus their own zone.
local function rebuildCandidates()
	table.clear(candidates)
	local zoneAttribute = player:GetAttribute("ZoneIndex")
	local zoneIndex = if typeof(zoneAttribute) == "number" then zoneAttribute else nil
	for _, station in Stations.LIST do
		local position = Stations.worldPosition(station, zoneIndex)
		if position then
			table.insert(candidates, { station = station, position = position })
		end
	end
end

local function isVisible(station: StationDef): boolean
	local snap = StateController.snapshot()
	local view = snap and snap.stations[station.id]
	return view ~= nil and view.visible
end

local function scan()
	local position = rootPosition()
	local bestPrompt: StationDef? = nil
	local onPad: StationDef? = nil
	if position then
		local bestDistance = math.huge
		for _, candidate in candidates do
			local station = candidate.station
			local offset = position - candidate.position
			if math.abs(offset.Y) <= Stations.VERTICAL_TOLERANCE and isVisible(station) then
				local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude
				if distance <= station.promptRadius and distance < bestDistance then
					bestPrompt, bestDistance = station, distance
				end
				if distance <= station.radius then
					onPad = station
				end
			end
		end
	end

	if bestPrompt ~= nearest then
		nearest = bestPrompt
		StationController.nearestChanged:Fire(bestPrompt)
	end

	local now = os.clock()
	if onPad ~= standingOn then
		standingOn = onPad
		standingSince = now
		evolveSent = false
		if onPad then
			trigger(onPad) -- stepping onto a pad buys once
		end
	elseif onPad then
		if isRunPad(onPad) then
			send(onPad, RUN_INTERVAL)
		elseif onPad.kind == "Evolve" and not evolveSent and now - standingSince >= Evolution.CONFIRM_SECONDS then
			evolveSent = true
			send(onPad, ACTION_INTERVAL)
		end
	end
end

function StationController.nearest(): StationDef?
	return nearest
end

function StationController.standingOn(): StationDef?
	return standingOn
end

-- 0..1 progress of the evolve hold on the current pad (0 when not on an evolve pad).
function StationController.evolveHoldProgress(): number
	local station = standingOn
	if not station or station.kind ~= "Evolve" or evolveSent then
		return 0
	end
	return math.clamp((os.clock() - standingSince) / Evolution.CONFIRM_SECONDS, 0, 1)
end

-- World position of one of this player's pads (nil if it has no zone yet).
function StationController.worldPosition(station: StationDef): Vector3?
	for _, candidate in candidates do
		if candidate.station == station then
			return candidate.position
		end
	end
	return nil
end

function StationController.init()
	rebuildCandidates()
	player:GetAttributeChangedSignal("ZoneIndex"):Connect(rebuildCandidates)
	task.spawn(function()
		while true do
			scan()
			task.wait(SCAN_INTERVAL)
		end
	end)
	ContextActionService:BindAction(INTERACT_ACTION, function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
		local station = nearest
		if state == Enum.UserInputState.Begin and station then
			trigger(station)
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.E, Enum.KeyCode.ButtonX)
end

return StationController
