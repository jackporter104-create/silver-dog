--!strict
--[[
	EconomyService: the single authority over currency ("Business Empire" stand economy).

	State per player (PlayerData):
	  stands[standId] = { level (0 locked / 1 owned), multiplier, speed, managerHired }
	  buffs[buffId]   = { unlocked, activeUntil, readyAt }  (server os.time())

	* Managed stands produce continuously: rate = cycle value / interval.
	* Unmanaged stands produce only while the player stands on the stand's main pad.
	  Each request starts one cycle (if none is running) and the payout lands when it ends.
	* Rates are cached per session and recomputed only when state changes or a buff starts/ends.
	* A 1 Hz tick applies income, completes hand-run cycles and sends a tiny Tick payload.
	  The client extrapolates between ticks.
	* All purchases are validated here. The client only says which pad it used.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BigNumber = require(Shared.BigNumber)
local NumberFormat = require(Shared.NumberFormat)
local EconomyMath = require(Shared.EconomyMath)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Economy = require(Shared.Config.Economy)
local Evolution = require(Shared.Config.Evolution)
local Statues = require(Shared.Config.Statues)
local Stations = require(Shared.Config.Stations)

local DataService = require(script.Parent.DataService)
local SeasonService = require(script.Parent.SeasonService)

type BigNumber = BigNumber.BigNumber
type PlayerData = Types.PlayerData
type StandState = Types.StandState
type Entitlements = Types.Entitlements
type StationDef = Stations.StationDef
type StandDef = Economy.StandDef

type ManualCycle = {
	endsAt: number, -- os.clock()
}

type Session = {
	player: Player,
	data: PlayerData,
	entitlements: Entitlements,
	lastTick: number,
	buff: number, -- active global buff multiplier the cached rate was computed with
	rate: BigNumber, -- managed income per second
	cycles: { [string]: ManualCycle },
	evolveReadyNotified: boolean,
	stairwayNotified: boolean,
	lastErrorAt: number,
	pearlsStat: StringValue,
	evolutionStat: IntValue,
}

local EconomyService = {}

local sessions: { [Player]: Session } = {}
local ZERO = BigNumber.ZERO
local ERROR_COOLDOWN = 0.4

local function mods(): Types.EconomyModifiers
	return SeasonService.modifiers()
end

local function currencyName(): string
	return SeasonService.current().currencyName
end

-- ===== Messaging =====

local function notify(s: Session, kind: Types.NotifyKind, text: string, amount: BigNumber?)
	local payload: Types.Notification = {
		kind = kind,
		text = text,
		amount = if amount then BigNumber.serialize(amount) else nil,
	}
	Net.get().Notify:FireClient(s.player, payload)
end

local function fail(s: Session, text: string)
	local now = os.clock()
	if now - s.lastErrorAt < ERROR_COOLDOWN then
		return
	end
	s.lastErrorAt = now
	notify(s, "Error", text)
end

local function formatDuration(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	local hours = seconds // 3600
	local minutes = (seconds % 3600) // 60
	if hours > 0 then
		return string.format("%dh %dm", hours, minutes)
	elseif minutes > 0 then
		return string.format("%dm %ds", minutes, seconds % 60)
	end
	return string.format("%ds", seconds)
end

-- ===== State helpers =====

local function standOf(data: PlayerData, standId: string): StandState
	local state = data.stands[standId]
	if not state then
		state = { level = 0, multiplier = 0, speed = 0, managerHired = false }
		data.stands[standId] = state
	end
	return state
end

local function refreshRates(s: Session)
	s.buff = EconomyMath.activeBuffMultiplier(s.data, os.time())
	s.rate = EconomyMath.managedRate(s.data, mods(), s.entitlements, s.buff)
end

local function earn(s: Session, amount: BigNumber)
	if amount.m <= 0 then
		return
	end
	local d = s.data
	d.currency = BigNumber.add(d.currency, amount)
	d.lifetimeEarned = BigNumber.add(d.lifetimeEarned, amount)
	d.totalEarned = BigNumber.add(d.totalEarned, amount)
	d.bestCurrency = BigNumber.max(d.bestCurrency, d.currency)
end

local function trySpend(s: Session, cost: BigNumber): boolean
	if BigNumber.lt(s.data.currency, cost) then
		fail(s, "Not enough " .. currencyName() .. "! Need " .. NumberFormat.format(cost))
		return false
	end
	s.data.currency = BigNumber.subClamped(s.data.currency, cost)
	return true
end

-- Unlocks buff pads whose milestone (owned stand count) is now reached. Unlocks persist until Evolution.
local function unlockBuffs(s: Session)
	for _, def in Economy.BUFFS do
		local state = s.data.buffs[def.id]
		if (not state or not state.unlocked) and EconomyMath.isBuffMilestoneReached(s.data, def) then
			s.data.buffs[def.id] = { unlocked = true, activeUntil = 0, readyAt = 0 }
			notify(s, "Success", string.format("New global buff pad unlocked in the plaza: %s (x%d)!", def.name, def.multiplier))
		end
	end
end

-- ===== Snapshot =====

local function view(level: number, cost: BigNumber?, locked: boolean, lockReason: string?, maxed: boolean): Types.StationView
	return {
		level = level,
		cost = if cost and not maxed then BigNumber.serialize(cost) else nil,
		locked = locked,
		lockReason = lockReason,
		maxed = maxed,
	}
end

local function stationView(s: Session, station: StationDef): Types.StationView
	local d, m = s.data, mods()
	local kind = station.kind
	local target = station.target or ""
	if kind == "StandMain" or kind == "Multiplier" or kind == "Speed" or kind == "Manager" then
		local def = Economy.STAND_BY_ID[target]
		local state = EconomyMath.standState(d, def.id)
		local owned = state.level > 0
		if kind == "StandMain" then
			return view(state.level, if owned then nil else EconomyMath.deedCost(def, m), false, nil, false)
		end
		local lockReason = if owned then nil else "Unlock " .. def.name .. " first"
		if kind == "Multiplier" then
			return view(state.multiplier, EconomyMath.multiplierCost(def, state.multiplier, m), not owned, lockReason, state.multiplier >= Economy.MAX_MULTIPLIER_LEVEL)
		elseif kind == "Speed" then
			local cost = EconomyMath.speedCost(def, state.speed, m)
			return view(state.speed, cost, not owned, lockReason, cost == nil)
		end
		return view(if state.managerHired then 1 else 0, EconomyMath.managerCost(def, m), not owned, lockReason, state.managerHired)
	elseif kind == "Buff" then
		local def = Economy.BUFF_BY_ID[target]
		local state = d.buffs[def.id]
		local unlocked = state ~= nil and state.unlocked
		return view(0, nil, not unlocked, if unlocked then nil else "Own " .. def.requiredStands .. " stands", false)
	elseif kind == "Evolve" then
		local requirement = EconomyMath.evolutionRequirement(d.evolution.level)
		local maxed = requirement == nil
		local locked = not maxed and not EconomyMath.canEvolve(d)
		return view(d.evolution.perks[target] or 0, nil, locked, if locked and requirement then "Earn " .. NumberFormat.format(requirement) .. " this run" else nil, maxed)
	elseif kind == "Statue" then
		local def = Statues.BY_ID[target]
		local owned = d.statues[def.id] == true
		local locked = not EconomyMath.isStairwayUnlocked(d)
		return view(if owned then 1 else 0, EconomyMath.statueCost(def), locked, if locked then "Heavenly Stairway locked" else nil, owned)
	end
	return view(0, nil, false, nil, false)
end

local function standView(s: Session, def: StandDef, serverNow: number, clockNow: number): Types.StandView
	local d, m, ent = s.data, mods(), s.entitlements
	local state = EconomyMath.standState(d, def.id)
	local cycle = s.cycles[def.id]
	return {
		owned = state.level > 0,
		managed = state.level > 0 and state.managerHired,
		multiplier = state.multiplier,
		speed = state.speed,
		interval = EconomyMath.standInterval(d, def),
		cycleValue = BigNumber.serialize(EconomyMath.standCycleValue(d, def, m, ent, s.buff)),
		manualValue = BigNumber.serialize(EconomyMath.manualCycleValue(d, def, m, ent, s.buff)),
		rate = BigNumber.serialize(EconomyMath.standRate(d, def, m, ent, s.buff)),
		cycleEndsAt = if cycle then serverNow + (cycle.endsAt - clockNow) else nil,
	}
end

local function buildSnapshot(s: Session): Types.Snapshot
	local d = s.data
	local serverNow = Workspace:GetServerTimeNow()
	local clockNow = os.clock()
	local osNow = os.time()

	local stationViews: { [string]: Types.StationView } = {}
	for _, station in Stations.LIST do
		stationViews[station.id] = stationView(s, station)
	end
	local stands: { [string]: Types.StandView } = {}
	for _, def in Economy.STANDS do
		stands[def.id] = standView(s, def, serverNow, clockNow)
	end
	local buffs: { [string]: Types.BuffView } = {}
	for _, def in Economy.BUFFS do
		local state = d.buffs[def.id]
		buffs[def.id] = {
			unlocked = state ~= nil and state.unlocked,
			activeRemaining = if state then math.max(0, state.activeUntil - osNow) else 0,
			cooldownRemaining = if state then math.max(0, state.readyAt - osNow) else 0,
		}
	end

	local level = d.evolution.level
	local requirement = EconomyMath.evolutionRequirement(level)
	local perks: { Types.PerkView } = {}
	for _, perk in Evolution.PERKS do
		table.insert(perks, { id = perk.id, name = perk.name, description = perk.description, stacks = d.evolution.perks[perk.id] or 0 })
	end
	return {
		currency = BigNumber.serialize(d.currency),
		rate = BigNumber.serialize(s.rate),
		serverTime = serverNow,
		globalMultiplier = s.buff,
		stations = stationViews,
		stands = stands,
		buffs = buffs,
		evolution = {
			level = level,
			multiplier = BigNumber.serialize(EconomyMath.evolutionMultiplier(level)),
			nextMultiplier = if requirement then BigNumber.serialize(EconomyMath.evolutionMultiplier(level + 1)) else nil,
			requirement = if requirement then BigNumber.serialize(requirement) else nil,
			progress = BigNumber.serialize(d.lifetimeEarned),
			canEvolve = EconomyMath.canEvolve(d),
			perks = perks,
		},
		statues = table.clone(d.statues),
		stairwayUnlocked = EconomyMath.isStairwayUnlocked(d),
		seasonId = SeasonService.current().id,
	}
end

local function sendSnapshot(s: Session)
	Net.get().Snapshot:FireClient(s.player, buildSnapshot(s))
end

local function updateLeaderstats(s: Session)
	s.pearlsStat.Value = NumberFormat.format(s.data.currency)
	s.evolutionStat.Value = s.data.evolution.level
end

-- Call after any state mutation that can change rates, costs or locks.
local function changed(s: Session)
	refreshRates(s)
	sendSnapshot(s)
	updateLeaderstats(s)
end

local function saveSoon(s: Session)
	task.spawn(DataService.saveAsync, s.player, false)
end

-- ===== Manual cycles =====

-- Pays out a finished hand-run cycle. The buff active at completion applies.
local function completeCycle(s: Session, def: StandDef, clockNow: number): boolean
	local cycle = s.cycles[def.id]
	if not cycle or clockNow < cycle.endsAt then
		return false
	end
	s.cycles[def.id] = nil
	earn(s, EconomyMath.manualCycleValue(s.data, def, mods(), s.entitlements, s.buff))
	s.data.totalRuns += 1
	return true
end

local function startCycle(s: Session, def: StandDef)
	local clockNow = os.clock()
	completeCycle(s, def, clockNow)
	if s.cycles[def.id] then
		return -- still running
	end
	local interval = EconomyMath.manualInterval(s.data, def)
	s.cycles[def.id] = { endsAt = clockNow + interval }
	local event: Types.CycleEvent = {
		standId = def.id,
		endsAt = Workspace:GetServerTimeNow() + interval,
		value = BigNumber.serialize(EconomyMath.manualCycleValue(s.data, def, mods(), s.entitlements, s.buff)),
	}
	Net.get().Cycle:FireClient(s.player, event)
end

-- ===== Action handlers =====

local function onStandMain(s: Session, def: StandDef)
	local state = standOf(s.data, def.id)
	if state.level == 0 then
		if trySpend(s, EconomyMath.deedCost(def, mods())) then
			state.level = 1
			unlockBuffs(s)
			changed(s)
			notify(s, "Success", def.name .. " unlocked! Stand on its pad to run it, or hire a manager.")
			saveSoon(s)
		end
		return
	end
	if state.managerHired then
		return -- the manager runs it; nothing to do by hand
	end
	startCycle(s, def)
end

local function onMultiplier(s: Session, def: StandDef)
	local state = standOf(s.data, def.id)
	if state.level == 0 then
		fail(s, "Unlock " .. def.name .. " first!")
		return
	end
	if state.multiplier >= Economy.MAX_MULTIPLIER_LEVEL then
		return
	end
	if trySpend(s, EconomyMath.multiplierCost(def, state.multiplier, mods())) then
		state.multiplier += 1
		changed(s)
	end
end

local function onSpeed(s: Session, def: StandDef)
	local state = standOf(s.data, def.id)
	if state.level == 0 then
		fail(s, "Unlock " .. def.name .. " first!")
		return
	end
	local cost = EconomyMath.speedCost(def, state.speed, mods())
	if not cost then
		fail(s, def.name .. " is already at max speed!")
		return
	end
	if trySpend(s, cost) then
		state.speed += 1
		changed(s)
	end
end

local function onManager(s: Session, def: StandDef)
	local state = standOf(s.data, def.id)
	if state.level == 0 then
		fail(s, "Unlock " .. def.name .. " first!")
		return
	end
	if state.managerHired then
		return
	end
	if trySpend(s, EconomyMath.managerCost(def, mods())) then
		state.managerHired = true
		completeCycle(s, def, math.huge) -- pay out any hand-run cycle in progress
		changed(s)
		notify(s, "Success", def.managerName .. " now runs " .. def.name .. ", even while you're offline!")
		saveSoon(s)
	end
end

local function onBuff(s: Session, buffId: string)
	local def = Economy.BUFF_BY_ID[buffId]
	local state = s.data.buffs[buffId]
	if not def then
		return
	end
	if not state or not state.unlocked then
		fail(s, def.name .. " unlocks when you own " .. def.requiredStands .. " stands!")
		return
	end
	local now = os.time()
	if state.activeUntil > now then
		return -- already active
	end
	if state.readyAt > now then
		fail(s, def.name .. " is recharging: " .. formatDuration(state.readyAt - now))
		return
	end
	local duration = math.ceil(EconomyMath.buffDuration(s.data, def))
	state.activeUntil = now + duration
	-- The cooldown starts when the buff ends.
	state.readyAt = state.activeUntil + def.cooldown
	changed(s)
	notify(s, "Success", string.format("%s! x%d on ALL stands for %ds", def.name, def.multiplier, duration))
end

local function onEvolve(s: Session, perkId: string)
	local d = s.data
	local perk = Evolution.PERK_BY_ID[perkId]
	if not perk then
		return
	end
	if d.evolution.level >= Evolution.MAX_LEVEL then
		fail(s, "You are fully evolved!")
		return
	end
	if not EconomyMath.canEvolve(d) then
		local requirement = EconomyMath.evolutionRequirement(d.evolution.level)
		fail(s, "Earn " .. (if requirement then NumberFormat.format(requirement) else "?") .. " this run to evolve!")
		return
	end
	-- Reset: currency, stands, upgrades, managers and buff unlocks. Keep statues and perks.
	d.currency = ZERO
	d.lifetimeEarned = ZERO
	d.stands = EconomyMath.startingStands()
	d.buffs = {}
	table.clear(s.cycles)
	d.evolution.level += 1
	d.evolution.perks[perk.id] = (d.evolution.perks[perk.id] or 0) + 1
	s.evolveReadyNotified = false
	changed(s)
	notify(s, "Evolution", string.format("Evolved to Level %d! All income x%s + %s", d.evolution.level, NumberFormat.format(EconomyMath.evolutionMultiplier(d.evolution.level)), perk.name))
	saveSoon(s)
end

local function onStatue(s: Session, statueId: string)
	local def = Statues.BY_ID[statueId]
	local d = s.data
	if not def or d.statues[def.id] then
		return
	end
	if not EconomyMath.isStairwayUnlocked(d) then
		fail(s, "The Heavenly Stairway is still locked!")
		return
	end
	if trySpend(s, EconomyMath.statueCost(def)) then
		d.statues[def.id] = true
		changed(s)
		local source = if def.source == "All" then "ALL" elseif Economy.STAND_BY_ID[def.source] then Economy.STAND_BY_ID[def.source].name else def.source
		notify(s, "Success", string.format("%s raised! %s income x%s forever!", def.name, source, NumberFormat.format(BigNumber.fromNumber(def.multiplier))))
		saveSoon(s)
	end
end

local function handle(s: Session, station: StationDef)
	local kind = station.kind
	local target = station.target or ""
	if kind == "Buff" then
		onBuff(s, target)
	elseif kind == "Evolve" then
		onEvolve(s, target)
	elseif kind == "Statue" then
		onStatue(s, target)
	else
		local def = Economy.STAND_BY_ID[target]
		if not def then
			return
		end
		if kind == "StandMain" then
			onStandMain(s, def)
		elseif kind == "Multiplier" then
			onMultiplier(s, def)
		elseif kind == "Speed" then
			onSpeed(s, def)
		elseif kind == "Manager" then
			onManager(s, def)
		end
	end
end

-- ===== Tick =====

local function checkMilestones(s: Session)
	local d = s.data
	if not s.evolveReadyNotified and EconomyMath.canEvolve(d) then
		s.evolveReadyNotified = true
		notify(s, "Evolution", "You can EVOLVE! Stand on a perk pad at the Evolution Temple.")
		sendSnapshot(s)
	end
	if not s.stairwayNotified and EconomyMath.isStairwayUnlocked(d) then
		s.stairwayNotified = true
		notify(s, "Success", "The Heavenly Stairway has opened!")
		sendSnapshot(s)
	end
end

local function tickSession(s: Session, now: number)
	local dt = math.clamp(now - s.lastTick, 0, 5)
	s.lastTick = now
	local d = s.data

	-- A buff started or ended since the last refresh: rates change.
	if EconomyMath.activeBuffMultiplier(d, os.time()) ~= s.buff then
		changed(s)
	end

	earn(s, BigNumber.mulNumber(s.rate, dt))
	for _, def in Economy.STANDS do
		completeCycle(s, def, now)
	end

	checkMilestones(s)
	local currency, rate = d.currency, s.rate
	Net.get().Tick:FireClient(s.player, { currency.m, currency.e, rate.m, rate.e, Workspace:GetServerTimeNow(), s.buff })
	updateLeaderstats(s)
end

-- ===== Public API =====

function EconomyService.init()
	SeasonService.onChanged(function()
		for _, s in sessions do
			changed(s)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(Net.TICK_INTERVAL)
			local now = os.clock()
			for _, s in sessions do
				local ok, err = pcall(function()
					tickSession(s, now)
				end)
				if not ok then
					warn("[EconomyService] tick failed for " .. s.player.Name .. ": " .. tostring(err))
				end
			end
		end
	end)
end

function EconomyService.startSession(player: Player, data: PlayerData, entitlements: Entitlements)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local pearls = Instance.new("StringValue")
	pearls.Name = "Pearls"
	pearls.Parent = leaderstats
	local evolution = Instance.new("IntValue")
	evolution.Name = "Evolution"
	evolution.Parent = leaderstats
	leaderstats.Parent = player

	local s: Session = {
		player = player,
		data = data,
		entitlements = entitlements,
		lastTick = os.clock(),
		buff = 1,
		rate = ZERO,
		cycles = {},
		evolveReadyNotified = EconomyMath.canEvolve(data),
		stairwayNotified = EconomyMath.isStairwayUnlocked(data),
		lastErrorAt = 0,
		pearlsStat = pearls,
		evolutionStat = evolution,
	}
	refreshRates(s)

	-- Offline earnings come from server clocks only. lastOnline was stamped by the last save.
	if data.lastOnline > 0 then
		local away = os.time() - data.lastOnline
		local earned = EconomyMath.offlineEarnings(data, mods(), entitlements, away)
		if earned.m > 0 then
			earn(s, earned)
			local capped = math.min(away, EconomyMath.offlineCapSeconds(data))
			notify(s, "Offline", "Welcome back! Your managers earned this while you were away (" .. formatDuration(capped) .. ")", earned)
		end
	end

	sessions[player] = s
	changed(s)
end

function EconomyService.endSession(player: Player)
	local s = sessions[player]
	if not s then
		return
	end
	tickSession(s, os.clock()) -- settle income up to the moment of leaving
	sessions[player] = nil
end

function EconomyService.isActive(player: Player): boolean
	return sessions[player] ~= nil
end

function EconomyService.handleAction(player: Player, station: StationDef)
	local s = sessions[player]
	if s then
		handle(s, station)
	end
end

function EconomyService.resync(player: Player)
	local s = sessions[player]
	if s then
		sendSnapshot(s)
	end
end

function EconomyService.setEntitlements(player: Player, entitlements: Entitlements)
	local s = sessions[player]
	if s then
		s.entitlements = entitlements
		changed(s)
	end
end

-- Developer/testing grant (DevService) and developer-product grants. Counts as earned income.
function EconomyService.grantCurrency(player: Player, amount: BigNumber): boolean
	local s = sessions[player]
	if not s or amount.m <= 0 then
		return false
	end
	earn(s, amount)
	checkMilestones(s)
	changed(s)
	return true
end

-- Time Warp product: TIME_WARP_SECONDS of managed income, or of the best owned stand if none is managed.
function EconomyService.grantTimeWarp(player: Player): boolean
	local s = sessions[player]
	if not s then
		return false
	end
	local rate = EconomyMath.managedRate(s.data, mods(), s.entitlements, 1)
	if rate.m <= 0 then
		for _, def in Economy.STANDS do
			if EconomyMath.isOwned(s.data, def.id) then
				rate = BigNumber.max(rate, EconomyMath.standRate(s.data, def, mods(), s.entitlements, 1))
			end
		end
	end
	local amount = BigNumber.mulNumber(rate, Economy.TIME_WARP_SECONDS)
	earn(s, amount)
	changed(s)
	notify(s, "Success", "Time Warp! Thanks for your support!", amount)
	return true
end

return EconomyService
