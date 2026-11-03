--!strict
--[[
	StateController: receives server state and extrapolates it locally.

	The server sends a Tick (currency, rate, serverTime) once per second. Every frame:
	  display = currency + rate * (serverNow - serverTime)
	Server time comes from Workspace:GetServerTimeNow() on both sides, so the client clock
	is never trusted. Extrapolation is capped so dropped ticks cannot run away.
	Local click predictions show instant feedback and are discarded on the next authoritative tick.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BigNumber = require(Shared.BigNumber)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Signal = require(Shared.Signal)

type BigNumber = BigNumber.BigNumber

local StateController = {}

local MAX_EXTRAPOLATION = 2.5

local baseCurrency: BigNumber = BigNumber.ZERO
local predicted: BigNumber = BigNumber.ZERO
local rate: BigNumber = BigNumber.ZERO
local baseTime = 0
local charge = 0
local snapshot: Types.Snapshot? = nil

StateController.snapshotChanged = Signal.new() :: Signal.Signal<Types.Snapshot>
StateController.notified = Signal.new() :: Signal.Signal<Types.Notification>
StateController.uiConfigChanged = Signal.new() :: Signal.Signal<Types.UiConfig>

function StateController.big(value: BigNumber.Serialized?): BigNumber
	return BigNumber.deserialize(value) or BigNumber.ZERO
end

local function onTick(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local p = payload :: { any }
	if #p ~= Net.TICK_FIELDS then
		return
	end
	for i = 1, Net.TICK_FIELDS do
		if typeof(p[i]) ~= "number" then
			return
		end
	end
	local currency = BigNumber.deserialize({ p[1], p[2] })
	local newRate = BigNumber.deserialize({ p[3], p[4] })
	if not currency or not newRate then
		return
	end
	-- Unreliable channel: ignore out-of-order ticks.
	if p[5] < baseTime then
		return
	end
	baseCurrency, rate, baseTime, charge = currency, newRate, p[5], p[6]
	predicted = BigNumber.ZERO
end

local function onSnapshot(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local snap = payload :: Types.Snapshot
	if typeof(snap.serverTime) ~= "number" or typeof(snap.stations) ~= "table" then
		return
	end
	snapshot = snap
	baseCurrency = StateController.big(snap.currency)
	rate = StateController.big(snap.rate)
	baseTime = math.max(baseTime, snap.serverTime)
	charge = snap.autoClicker.charge
	predicted = BigNumber.ZERO
	StateController.snapshotChanged:Fire(snap)
end

function StateController.init()
	local remotes = Net.get()
	remotes.Tick.OnClientEvent:Connect(onTick)
	remotes.Snapshot.OnClientEvent:Connect(onSnapshot)
	remotes.Notify.OnClientEvent:Connect(function(payload: unknown)
		if typeof(payload) == "table" and typeof((payload :: any).text) == "string" then
			StateController.notified:Fire(payload :: Types.Notification)
		end
	end)
	remotes.UiConfig.OnClientEvent:Connect(function(payload: unknown)
		if typeof(payload) == "table" then
			StateController.uiConfigChanged:Fire(payload :: Types.UiConfig)
		end
	end)
	-- Ask for a full resync in case the first Snapshot fired before these handlers existed.
	remotes.Action:FireServer("__sync")
end

function StateController.displayCurrency(): BigNumber
	local elapsed = math.clamp(Workspace:GetServerTimeNow() - baseTime, 0, MAX_EXTRAPOLATION)
	local value = BigNumber.add(baseCurrency, predicted)
	if rate.m > 0 and elapsed > 0 then
		value = BigNumber.add(value, BigNumber.mulNumber(rate, elapsed))
	end
	return value
end

function StateController.rate(): BigNumber
	return rate
end

function StateController.charge(): number
	return charge
end

function StateController.snapshot(): Types.Snapshot?
	return snapshot
end

-- Optimistic click feedback. The next tick replaces it with the authoritative balance.
function StateController.predictClick(): BigNumber
	local snap = snapshot
	if not snap then
		return BigNumber.ZERO
	end
	local value = StateController.big(snap.clickValue)
	predicted = BigNumber.add(predicted, value)
	return value
end

return StateController
