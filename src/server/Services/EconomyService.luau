--!strict
--[[
	EconomyService: the single authority over currency.

	* Holds a Session per loaded player with cached rates. Rates are recomputed only when state
	  changes, never per tick.
	* Ticks every Net.TICK_INTERVAL. It applies passive income and auto-clicks, then sends a tiny
	  Tick payload. The client extrapolates between ticks for the "nanosecond" effect.
	* All purchases and evolutions are validated here. The client only says what it touched.
	* Uses BigNumber throughout. Values below 1e15 stay plain doubles internally, so the
	  transition to mantissa/exponent form is invisible to this code.
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
local Monetization = require(Shared.Config.Monetization)

local DataService = require(script.Parent.DataService)
local SeasonService = require(script.Parent.SeasonService)

type BigNumber = BigNumber.BigNumber
type PlayerData = Types.PlayerData
type Entitlements = Types.Entitlements
type StationDef = Stations.StationDef

type Session = {
	player: Player,
	data: PlayerData,
	entitlements: Entitlements,
	lastTick: number,
	autoClickRemainder: number,
	passive: BigNumber,
	clickValue: BigNumber,
	autoClickValue: BigNumber,
	autoCps: number,
	autoInfinite: boolean,
	evolveReadyNotified: boolean,
	stairwayNotified: boolean,
	lastErrorAt: number,
	pearlsStat: StringValue,
	evolutionStat: IntValue,
}

local EconomyService = {}

local sessions: { [Player]: Session } = {}
local ZERO = BigNumber.ZERO
local LIMITS = Economy.LIMITS
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

-- ===== Rates & state =====

local function refreshRates(s: Session)
	local d, m = s.data, mods()
	s.clickValue = EconomyMath.clickValue(d, m)
	s.passive = EconomyMath.passivePerSecond(d, m)
	s.autoClickValue = EconomyMath.autoClickValue(d, m)
	s.autoCps = EconomyMath.autoClicksPerSecond(d, s.entitlements)
	s.autoInfinite = EconomyMath.isAutoClickerInfinite(d, s.entitlements)
end

local function autoRunning(s: Session): boolean
	return s.autoCps > 0 and (s.autoInfinite or s.data.autoClicker.charge > 0)
end

local function currentRate(s: Session): BigNumber
	if autoRunning(s) then
		return BigNumber.add(s.passive, BigNumber.mulNumber(s.autoClickValue, s.autoCps))
	end
	return s.passive
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

-- ===== Snapshot =====

local function view(level: number, cost: BigNumber?, cost10: BigNumber?, locked: boolean, lockReason: string?, maxed: boolean): Types.StationView
	return {
		level = level,
		cost = if cost and not maxed then BigNumber.serialize(cost) else nil,
		cost10 = if cost10 and not maxed then BigNumber.serialize(cost10) else nil,
		locked = locked,
		lockReason = lockReason,
		maxed = maxed,
	}
end

local function stationView(s: Session, station: StationDef): Types.StationView
	local d, m = s.data, mods()
	local kind = station.kind
	if kind == "Generator" then
		local def = Economy.GENERATOR_BY_ID[station.target or ""]
		local owned = d.generators[def.id] or 0
		local locked = d.investors < def.requiredInvestors
		return view(
			owned,
			EconomyMath.generatorCost(def, owned, 1, m),
			EconomyMath.generatorCost(def, owned, 10, m),
			locked,
			if locked then "Needs " .. def.requiredInvestors .. " Investors" else nil,
			owned >= LIMITS.maxLevel
		)
	elseif kind == "ClickUpgrade" then
		return view(
			d.clickLevel,
			EconomyMath.clickUpgradeCost(d.clickLevel, 1, m),
			EconomyMath.clickUpgradeCost(d.clickLevel, 10, m),
			false,
			nil,
			d.clickLevel >= LIMITS.maxLevel
		)
	elseif kind == "Investor" then
		return view(
			d.investors,
			EconomyMath.investorCost(d.investors, 1, m),
			EconomyMath.investorCost(d.investors, 10, m),
			false,
			nil,
			d.investors >= LIMITS.maxInvestors
		)
	elseif kind == "AutoClicker" then
		local nextTier = d.autoClicker.tier + 1
		local def = EconomyMath.autoClickerTier(nextTier)
		if not def then
			return view(d.autoClicker.tier, nil, nil, false, nil, true)
		end
		local locked = d.evolution.level < def.requiredEvolution
		return view(
			d.autoClicker.tier,
			EconomyMath.autoClickerTierCost(nextTier, m),
			nil,
			locked,
			if locked then "Reach Evolution " .. def.requiredEvolution else nil,
			false
		)
	elseif kind == "Battery" then
		local locked = d.autoClicker.tier == 0 and not s.entitlements.infiniteAutoClicker
		return view(d.autoClicker.tier, nil, nil, locked, if locked then "Buy an Auto-Clicker first" else nil, s.autoInfinite)
	elseif kind == "Evolution" then
		local requirement = EconomyMath.evolutionRequirement(d.evolution.level)
		local maxed = requirement == nil
		local locked = not maxed and not EconomyMath.canEvolve(d)
		return view(
			d.evolution.level,
			nil,
			nil,
			locked,
			if locked and requirement then "Earn " .. NumberFormat.format(requirement) .. " this run" else nil,
			maxed
		)
	elseif kind == "Statue" then
		local def = Statues.BY_ID[station.target or ""]
		local owned = d.statues[def.id] == true
		local locked = not EconomyMath.isStairwayUnlocked(d)
		return view(if owned then 1 else 0, EconomyMath.statueCost(def), nil, locked, if locked then "Heavenly Stairway locked" else nil, owned)
	end
	return view(0, nil, nil, false, nil, false)
end

local function buildSnapshot(s: Session): Types.Snapshot
	local d = s.data
	local stationViews: { [string]: Types.StationView } = {}
	for _, station in Stations.LIST do
		stationViews[station.id] = stationView(s, station)
	end
	local level = d.evolution.level
	local requirement = EconomyMath.evolutionRequirement(level)
	local perks: { Types.PerkView } = {}
	for _, perk in Evolution.PERKS do
		table.insert(perks, { id = perk.id, name = perk.name, description = perk.description, stacks = d.evolution.perks[perk.id] or 0 })
	end
	return {
		currency = BigNumber.serialize(d.currency),
		rate = BigNumber.serialize(currentRate(s)),
		serverTime = Workspace:GetServerTimeNow(),
		clickValue = BigNumber.serialize(s.clickValue),
		investors = d.investors,
		investorBonus = EconomyMath.investorBonusFraction(d),
		stations = stationViews,
		evolution = {
			level = level,
			multiplier = BigNumber.serialize(EconomyMath.evolutionMultiplier(level)),
			nextMultiplier = if requirement then BigNumber.serialize(EconomyMath.evolutionMultiplier(level + 1)) else nil,
			requirement = if requirement then BigNumber.serialize(requirement) else nil,
			progress = BigNumber.serialize(d.lifetimeEarned),
			canEvolve = EconomyMath.canEvolve(d),
			perks = perks,
		},
		autoClicker = {
			tier = d.autoClicker.tier,
			charge = d.autoClicker.charge,
			capacity = EconomyMath.autoClickerCapacity(d),
			infinite = s.autoInfinite,
			clicksPerSecond = s.autoCps,
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

-- ===== Action handlers =====

local function quantityFrom(option: number): number
	return if option == 10 then 10 else 1
end

local function onClam(s: Session, _station: StationDef, _option: number)
	earn(s, s.clickValue)
	s.data.totalClicks += 1
end

local function onGenerator(s: Session, station: StationDef, option: number)
	local def = Economy.GENERATOR_BY_ID[station.target or ""]
	if not def then
		return
	end
	local d = s.data
	if d.investors < def.requiredInvestors then
		fail(s, def.name .. " needs " .. def.requiredInvestors .. " Investors!")
		return
	end
	local owned = d.generators[def.id] or 0
	local quantity = math.min(quantityFrom(option), LIMITS.maxLevel - owned)
	if quantity <= 0 then
		return
	end
	if trySpend(s, EconomyMath.generatorCost(def, owned, quantity, mods())) then
		d.generators[def.id] = owned + quantity
		changed(s)
	end
end

local function onClickUpgrade(s: Session, _station: StationDef, option: number)
	local d = s.data
	local quantity = math.min(quantityFrom(option), LIMITS.maxLevel - d.clickLevel)
	if quantity <= 0 then
		return
	end
	if trySpend(s, EconomyMath.clickUpgradeCost(d.clickLevel, quantity, mods())) then
		d.clickLevel += quantity
		changed(s)
	end
end

local function onInvestor(s: Session, _station: StationDef, option: number)
	local d = s.data
	local quantity = math.min(quantityFrom(option), LIMITS.maxInvestors - d.investors)
	if quantity <= 0 then
		return
	end
	if trySpend(s, EconomyMath.investorCost(d.investors, quantity, mods())) then
		d.investors += quantity
		changed(s)
	end
end

local function onAutoClicker(s: Session, _station: StationDef, _option: number)
	local d = s.data
	local nextTier = d.autoClicker.tier + 1
	local def = EconomyMath.autoClickerTier(nextTier)
	local cost = EconomyMath.autoClickerTierCost(nextTier, mods())
	if not def or not cost then
		fail(s, "Your Auto-Clicker is fully upgraded!")
		return
	end
	if d.evolution.level < def.requiredEvolution then
		fail(s, "Reach Evolution " .. def.requiredEvolution .. " to unlock this upgrade!")
		return
	end
	if trySpend(s, cost) then
		d.autoClicker.tier = nextTier
		d.autoClicker.charge = def.capacity
		changed(s)
		local text = if def.infinite
			then "INFINITE Auto-Clicker unlocked! It never runs out!"
			else string.format("Auto-Clicker Mk.%d: %d clicks/s!", nextTier, def.clicksPerSecond)
		notify(s, "Success", text)
		saveSoon(s)
	end
end

local function onBattery(s: Session, _station: StationDef, _option: number)
	local d = s.data
	if s.autoInfinite then
		notify(s, "Info", "Your Auto-Clicker never runs out!")
		return
	end
	if d.autoClicker.tier == 0 then
		fail(s, "Buy an Auto-Clicker at the Auto-Clicker Lab first!")
		return
	end
	local capacity = EconomyMath.autoClickerCapacity(d)
	if d.autoClicker.charge >= capacity then
		return
	end
	d.autoClicker.charge = capacity
	changed(s)
	notify(s, "Success", "Battery recharged!")
end

local function onEvolution(s: Session, _station: StationDef, option: number)
	local d = s.data
	if d.evolution.level >= Evolution.MAX_LEVEL then
		fail(s, "You are fully evolved!")
		return
	end
	if not EconomyMath.canEvolve(d) then
		local requirement = EconomyMath.evolutionRequirement(d.evolution.level)
		fail(s, "Earn " .. (if requirement then NumberFormat.format(requirement) else "?") .. " this run to evolve!")
		return
	end
	local perk = Evolution.PERKS[option]
	if not perk then
		return
	end
	-- Reset: wipe currency, Investors and run upgrades. Keep auto-clicker tier, statues and perks.
	d.currency = ZERO
	d.lifetimeEarned = ZERO
	d.investors = 0
	d.clickLevel = 0
	d.generators = {}
	d.evolution.level += 1
	d.evolution.perks[perk.id] = (d.evolution.perks[perk.id] or 0) + 1
	d.autoClicker.charge = EconomyMath.autoClickerCapacity(d)
	s.evolveReadyNotified = false
	changed(s)
	notify(
		s,
		"Evolution",
		string.format("Evolved to Level %d! All income x%s + %s", d.evolution.level, NumberFormat.format(EconomyMath.evolutionMultiplier(d.evolution.level)), perk.name)
	)
	saveSoon(s)
end

local function onStatue(s: Session, station: StationDef, _option: number)
	local def = Statues.BY_ID[station.target or ""]
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
		notify(s, "Success", string.format("%s raised! %s income x%s forever!", def.name, def.source, NumberFormat.format(BigNumber.fromNumber(def.multiplier))))
		saveSoon(s)
	end
end

local HANDLERS: { [Types.StationKind]: (Session, StationDef, number) -> () } = {
	Clam = onClam,
	Generator = onGenerator,
	ClickUpgrade = onClickUpgrade,
	Investor = onInvestor,
	AutoClicker = onAutoClicker,
	Battery = onBattery,
	Evolution = onEvolution,
	Statue = onStatue,
}

-- ===== Tick =====

local function checkMilestones(s: Session)
	local d = s.data
	if not s.evolveReadyNotified and EconomyMath.canEvolve(d) then
		s.evolveReadyNotified = true
		notify(s, "Evolution", "You can EVOLVE! Visit the Evolution Altar.")
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
	local income = BigNumber.mulNumber(s.passive, dt)

	if s.autoCps > 0 then
		if s.autoInfinite then
			income = BigNumber.add(income, BigNumber.mulNumber(s.autoClickValue, s.autoCps * dt))
		elseif d.autoClicker.charge > 0 then
			s.autoClickRemainder += s.autoCps * dt
			local whole = math.floor(s.autoClickRemainder)
			s.autoClickRemainder -= whole
			local clicks = math.min(whole, d.autoClicker.charge)
			d.autoClicker.charge -= clicks
			d.totalClicks += clicks
			income = BigNumber.add(income, BigNumber.mulNumber(s.autoClickValue, clicks))
			if d.autoClicker.charge <= 0 then
				s.autoClickRemainder = 0
				earn(s, income)
				income = ZERO
				changed(s)
				notify(s, "Info", "Auto-Clicker battery empty! Recharge it at the Battery Dock.")
			end
		end
	end

	earn(s, income)
	checkMilestones(s)
	local currency, rate = d.currency, currentRate(s)
	Net.get().Tick:FireClient(s.player, { currency.m, currency.e, rate.m, rate.e, Workspace:GetServerTimeNow(), d.autoClicker.charge })
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

local function formatDuration(seconds: number): string
	local hours = seconds // 3600
	local minutes = (seconds % 3600) // 60
	if hours > 0 then
		return string.format("%dh %dm", hours, minutes)
	end
	return string.format("%dm", minutes)
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
		autoClickRemainder = 0,
		passive = ZERO,
		clickValue = ZERO,
		autoClickValue = ZERO,
		autoCps = 0,
		autoInfinite = false,
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
			notify(s, "Offline", "Welcome back! Your ocean earned this while you were away (" .. formatDuration(capped) .. ")", earned)
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

function EconomyService.handleAction(player: Player, station: StationDef, option: number)
	local s = sessions[player]
	if not s then
		return
	end
	HANDLERS[station.kind](s, station, option)
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

-- Developer product grant. Always succeeds for a loaded player. Returns false if not loaded.
function EconomyService.grantBatteryOvercharge(player: Player): boolean
	local s = sessions[player]
	if not s then
		return false
	end
	local d = s.data
	if d.autoClicker.tier == 0 then
		d.autoClicker.tier = 1
	end
	local capacity = EconomyMath.autoClickerCapacity(d)
	d.autoClicker.charge = math.min(LIMITS.maxCharge, math.max(d.autoClicker.charge, capacity * Monetization.OVERCHARGE_MULTIPLIER))
	changed(s)
	notify(s, "Success", "Battery OVERCHARGED! Thanks for your support!")
	return true
end

return EconomyService
