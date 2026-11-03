--!strict
--[[
	StandTracker: client-side timing of the player's own stands, for feedback only (no economy math).
	  * Hand-run stands: progress of the cycle the server just started (Cycle remote).
	  * Managed / Auto-Collected stands: a visual loop of the stand's interval.
	Fires `payout(standId, value)` when a cycle visually completes. The real currency always comes
	from server ticks; this only drives the HUD bar, "+value" pops and coin bursts.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BigNumber = require(Shared.BigNumber)
local Signal = require(Shared.Signal)
local Types = require(Shared.Types)
local Economy = require(Shared.Config.Economy)

local StateController = require(script.Parent.StateController)

type BigNumber = BigNumber.BigNumber

export type Payout = { standId: string, value: BigNumber }

local StandTracker = {}

-- Loops faster than this would spam pops; they show a full bar and pop at this rate instead.
local MIN_POP_INTERVAL = 0.8

type Track = {
	cycleStart: number?,
	cycleEnd: number?,
	cycleValue: BigNumber?,
	loopOrigin: number,
	lastLoopProgress: number,
	lastPopAt: number,
}

local tracks: { [string]: Track } = {}

StandTracker.payout = Signal.new() :: Signal.Signal<Payout>

local function track(standId: string): Track
	local t = tracks[standId]
	if not t then
		t = { loopOrigin = Workspace:GetServerTimeNow(), lastLoopProgress = 0, lastPopAt = 0 }
		tracks[standId] = t
	end
	return t
end

local function isAutomatic(stand: Types.StandView): boolean
	return stand.owned and (stand.managed or stand.autoCollected)
end

-- 0..1 progress of the stand's current (visual) cycle, or nil when it is idle.
function StandTracker.progress(standId: string): number?
	local snap = StateController.snapshot()
	local stand = snap and snap.stands[standId]
	local t = tracks[standId]
	if not stand or not stand.owned or not t then
		return nil
	end
	local now = Workspace:GetServerTimeNow()
	if isAutomatic(stand) then
		local interval = if stand.managed then stand.interval else math.max(stand.interval, Economy.MIN_MANUAL_INTERVAL)
		if interval < MIN_POP_INTERVAL then
			return 1
		end
		return ((now - t.loopOrigin) % interval) / interval
	end
	if t.cycleStart and t.cycleEnd then
		local start, finish = t.cycleStart :: number, t.cycleEnd :: number
		return math.clamp((now - start) / math.max(finish - start, 1e-3), 0, 1)
	end
	return nil
end

local function step()
	local snap = StateController.snapshot()
	if not snap then
		return
	end
	local now = Workspace:GetServerTimeNow()
	for _, def in Economy.STANDS do
		local stand = snap.stands[def.id]
		if not stand or not stand.owned then
			continue
		end
		local t = track(def.id)
		if isAutomatic(stand) then
			local interval = if stand.managed then stand.interval else math.max(stand.interval, Economy.MIN_MANUAL_INTERVAL)
			local value = StateController.big(if stand.managed then stand.cycleValue else stand.manualValue)
			if interval < MIN_POP_INTERVAL then
				-- Very fast stands: pop the income of one MIN_POP_INTERVAL window instead.
				if now - t.lastPopAt >= MIN_POP_INTERVAL then
					t.lastPopAt = now
					StandTracker.payout:Fire({ standId = def.id, value = BigNumber.mulNumber(value, MIN_POP_INTERVAL / interval) })
				end
			else
				local progress = ((now - t.loopOrigin) % interval) / interval
				if progress < t.lastLoopProgress then
					StandTracker.payout:Fire({ standId = def.id, value = value })
				end
				t.lastLoopProgress = progress
			end
		elseif t.cycleEnd and now >= (t.cycleEnd :: number) then
			local value = t.cycleValue
			t.cycleStart, t.cycleEnd, t.cycleValue = nil, nil, nil
			if value then
				StandTracker.payout:Fire({ standId = def.id, value = value })
			end
		end
	end
end

function StandTracker.init()
	StateController.cycleStarted:Connect(function(event: Types.CycleEvent)
		local snap = StateController.snapshot()
		local stand = snap and snap.stands[event.standId]
		if not stand then
			return
		end
		local t = track(event.standId)
		t.cycleStart = event.endsAt - math.max(stand.interval, Economy.MIN_MANUAL_INTERVAL)
		t.cycleEnd = event.endsAt
		t.cycleValue = StateController.big(event.value)
	end)
	StateController.snapshotChanged:Connect(function(snap: Types.Snapshot)
		-- Reset loops for stands that just became automatic (or were reset by Evolution).
		for standId, t in tracks do
			local stand = snap.stands[standId]
			if not stand or not stand.owned then
				tracks[standId] = nil
			elseif isAutomatic(stand) and t.cycleEnd then
				t.cycleStart, t.cycleEnd, t.cycleValue = nil, nil, nil
				t.loopOrigin = Workspace:GetServerTimeNow()
			end
		end
	end)
	RunService.Heartbeat:Connect(step)
end

return StandTracker
