--!strict
--[[
	StationController: detects which station the local character stands at (cheap distance
	checks at 10 Hz) and sends intent-only Action requests. The server re-validates
	everything. Client throttles only keep requests under the server's Guard limits.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Signal = require(Shared.Signal)
local Stations = require(Shared.Config.Stations)
local BigNumber = require(Shared.BigNumber)

local StateController = require(script.Parent.StateController)

type StationDef = Stations.StationDef

local StationController = {}

local SCAN_INTERVAL = 0.1
local CLICK_INTERVAL = 1 / 14 -- under the server's 15/s Guard rate
local ACTION_INTERVAL = 0.15
local INTERACT_ACTION = "OceanInteract"

local player = Players.LocalPlayer
local nearest: StationDef? = nil
local lastSent: { [string]: number } = {}

StationController.nearestChanged = Signal.new() :: Signal.Signal<StationDef?>
StationController.clicked = Signal.new() :: Signal.Signal<BigNumber.BigNumber>
-- Fired when the player interacts with a station that needs a UI choice (Evolution).
StationController.choiceRequested = Signal.new() :: Signal.Signal<StationDef>

local function rootPosition(): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function scan()
	local position = rootPosition()
	local best: StationDef? = nil
	if position then
		local bestDistance = math.huge
		for _, station in Stations.LIST do
			local offset = position - station.position
			if math.abs(offset.Y) <= Stations.VERTICAL_TOLERANCE then
				local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude
				if distance <= station.radius and distance < bestDistance then
					best, bestDistance = station, distance
				end
			end
		end
	end
	if best ~= nearest then
		nearest = best
		StationController.nearestChanged:Fire(best)
	end
end

function StationController.nearest(): StationDef?
	return nearest
end

-- Sends an intent for the current station. option: quantity (1/10) or perk index.
function StationController.send(station: StationDef, option: number)
	local now = os.clock()
	local interval = if station.kind == "Clam" then CLICK_INTERVAL else ACTION_INTERVAL
	if now - (lastSent[station.kind] or 0) < interval then
		return
	end
	lastSent[station.kind] = now
	Net.get().Action:FireServer(station.id, option)
	if station.kind == "Clam" then
		StationController.clicked:Fire(StateController.predictClick())
	end
end

function StationController.interact(option: number)
	local station = nearest
	if not station then
		return
	end
	if station.kind == "Evolution" then
		StationController.choiceRequested:Fire(station)
		return
	end
	StationController.send(station, option)
end

function StationController.init()
	task.spawn(function()
		while true do
			scan()
			task.wait(SCAN_INTERVAL)
		end
	end)
	ContextActionService:BindAction(INTERACT_ACTION, function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
		if state == Enum.UserInputState.Begin then
			StationController.interact(1)
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.E, Enum.KeyCode.ButtonX)
end

return StationController
