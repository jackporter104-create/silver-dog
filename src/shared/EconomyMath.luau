--!strict
--[[
	EconomyMath: pure, deterministic formulas. No Roblox APIs and no side effects.
	Only the server uses it for authority. tools/sim.luau uses it for pacing.
	The client never calls it; it receives precomputed values in Snapshots.

	Value of one cycle of stand S:
	  baseValue * 2^multiplierLevel * season(S) * statue(S) * global
	  global = 42^(evo-1) * GoldenTouch * season income * x2 gamepass * statue(All) * buff
	Interval: baseInterval / 2^speedLevel / SwiftCurrents. Rate = value / interval.
]]

local BigNumber = require(script.Parent.BigNumber)
local Types = require(script.Parent.Types)
local Economy = require(script.Parent.Config.Economy)
local Evolution = require(script.Parent.Config.Evolution)
local Statues = require(script.Parent.Config.Statues)
local MonetizationConfig = require(script.Parent.Config.MonetizationConfig)

type BigNumber = BigNumber.BigNumber
type PlayerData = Types.PlayerData
type StandState = Types.StandState
type EconomyModifiers = Types.EconomyModifiers
type Entitlements = Types.Entitlements
type StandDef = Economy.StandDef
type BuffDef = Economy.BuffDef

local EconomyMath = {}

local ONE = BigNumber.ONE
local ZERO = BigNumber.ZERO
local TWO = BigNumber.fromNumber(2)
local PERK = Evolution.PERK_VALUES

EconomyMath.NEUTRAL_MODIFIERS = table.freeze({
	incomeMultiplier = 1,
	costMultiplier = 1,
	standMultipliers = table.freeze({}),
}) :: EconomyModifiers

EconomyMath.NO_ENTITLEMENTS = table.freeze({ doubleIncome = false, autoCollect = false }) :: Entitlements

local DEFAULT_STAND: StandState = table.freeze({ level = 0, multiplier = 0, speed = 0, managerHired = false, revealed = 0 })

-- ===== Stand state =====

function EconomyMath.standState(data: PlayerData, standId: string): StandState
	return data.stands[standId] or DEFAULT_STAND
end

function EconomyMath.isOwned(data: PlayerData, standId: string): boolean
	return EconomyMath.standState(data, standId).level > 0
end

function EconomyMath.isManaged(data: PlayerData, standId: string): boolean
	local state = EconomyMath.standState(data, standId)
	return state.level > 0 and state.managerHired
end

function EconomyMath.ownedStandCount(data: PlayerData): number
	local count = 0
	for _, def in Economy.STANDS do
		if EconomyMath.isOwned(data, def.id) then
			count += 1
		end
	end
	return count
end

-- Fresh stands for a new player or a new evolution run: only the starting stand is owned.
function EconomyMath.startingStands(): { [string]: StandState }
	return { [Economy.STARTING_STAND] = { level = 1, multiplier = 0, speed = 0, managerHired = false, revealed = 0 } }
end

-- The only stand whose "???" Deed pad is shown: the first one in list order not yet owned.
function EconomyMath.nextStandId(data: PlayerData): string?
	for _, def in Economy.STANDS do
		if not EconomyMath.isOwned(data, def.id) then
			return def.id
		end
	end
	return nil
end

-- Whether a pad of this kind exists for the player right now (progressive reveal).
-- Hub pads (Evolve, Statue) always exist.
function EconomyMath.isPadVisible(data: PlayerData, kind: string, target: string): boolean
	if kind == "Deed" then
		return EconomyMath.nextStandId(data) == target
	elseif kind == "StandMain" then
		return EconomyMath.isOwned(data, target)
	elseif kind == "Multiplier" or kind == "Speed" or kind == "Manager" then
		local state = EconomyMath.standState(data, target)
		return state.level > 0 and state.revealed >= (Economy.REVEAL :: any)[kind]
	elseif kind == "Buff" then
		local buff = data.buffs[target]
		return buff ~= nil and buff.unlocked
	end
	return true -- Hub pads and the Shop
end

-- ===== Costs =====

-- Cost of buying `quantity` levels starting at `owned`: base * g^owned * (g^q - 1) / (g - 1).
function EconomyMath.geometricCost(baseCost: number, growth: number, owned: number, quantity: number, costMultiplier: number): BigNumber
	local g = BigNumber.fromNumber(growth)
	local first = BigNumber.mulNumber(BigNumber.pow(g, owned), baseCost * costMultiplier)
	if quantity <= 1 then
		return first
	end
	local series = BigNumber.div(BigNumber.sub(BigNumber.pow(g, quantity), ONE), BigNumber.fromNumber(growth - 1))
	return BigNumber.mul(first, series)
end

function EconomyMath.deedCost(def: StandDef, mods: EconomyModifiers): BigNumber
	return BigNumber.fromNumber(def.deedCost * mods.costMultiplier)
end

function EconomyMath.multiplierCost(def: StandDef, level: number, mods: EconomyModifiers): BigNumber
	return EconomyMath.geometricCost(def.multiplierCost, def.multiplierGrowth, level, 1, mods.costMultiplier)
end

function EconomyMath.speedCost(def: StandDef, level: number, mods: EconomyModifiers): BigNumber?
	if level >= Economy.MAX_SPEED_LEVEL then
		return nil
	end
	return EconomyMath.geometricCost(def.speedCost, def.speedGrowth, level, 1, mods.costMultiplier)
end

function EconomyMath.managerCost(def: StandDef, mods: EconomyModifiers): BigNumber
	return BigNumber.fromNumber(def.managerCost * mods.costMultiplier)
end

function EconomyMath.statueCost(def: Statues.StatueDef): BigNumber
	return BigNumber.fromExponent(def.costExponent)
end

-- ===== Multipliers =====

function EconomyMath.perkStacks(data: PlayerData, perkId: string): number
	return data.evolution.perks[perkId] or 0
end

function EconomyMath.evolutionMultiplier(level: number): BigNumber
	return BigNumber.pow(BigNumber.fromNumber(Evolution.MULTIPLIER_BASE), math.max(level - 1, 0))
end

-- Product of owned statues whose source is exactly `source` (a stand id, "Offline" or "All").
function EconomyMath.statueMultiplier(data: PlayerData, source: string): BigNumber
	local result = ONE
	for _, statue in Statues.LIST do
		if data.statues[statue.id] and statue.source == source then
			result = BigNumber.mulNumber(result, statue.multiplier)
		end
	end
	return result
end

-- Every multiplier that applies to all stands equally. `buff` is the active buff multiplier.
function EconomyMath.globalMultiplier(data: PlayerData, mods: EconomyModifiers, ent: Entitlements, buff: number): BigNumber
	local plain = PERK.goldenTouchMultiplier ^ EconomyMath.perkStacks(data, "GoldenTouch")
		* mods.incomeMultiplier
		* (if ent.doubleIncome then 2 else 1)
		* buff
	local result = BigNumber.mulNumber(EconomyMath.evolutionMultiplier(data.evolution.level), plain)
	return BigNumber.mul(result, EconomyMath.statueMultiplier(data, "All"))
end

-- ===== Stands =====

function EconomyMath.standInterval(data: PlayerData, def: StandDef): number
	local state = EconomyMath.standState(data, def.id)
	local speed = math.clamp(state.speed, 0, Economy.MAX_SPEED_LEVEL)
	return def.baseInterval / 2 ^ speed / PERK.swiftCurrentsSpeed ^ EconomyMath.perkStacks(data, "SwiftCurrents")
end

function EconomyMath.standCycleValue(data: PlayerData, def: StandDef, mods: EconomyModifiers, ent: Entitlements, buff: number): BigNumber
	local state = EconomyMath.standState(data, def.id)
	local value = BigNumber.mulNumber(BigNumber.pow(TWO, state.multiplier), def.baseValue * (mods.standMultipliers[def.id] or 1))
	value = BigNumber.mul(value, EconomyMath.statueMultiplier(data, def.id))
	return BigNumber.mul(value, EconomyMath.globalMultiplier(data, mods, ent, buff))
end

-- Payout of one hand-run cycle (Busy Fins perk applies only here).
function EconomyMath.manualCycleValue(data: PlayerData, def: StandDef, mods: EconomyModifiers, ent: Entitlements, buff: number): BigNumber
	local perk = PERK.busyFinsMultiplier ^ EconomyMath.perkStacks(data, "BusyFins")
	return BigNumber.mulNumber(EconomyMath.standCycleValue(data, def, mods, ent, buff), perk)
end

-- Hand-run cycles can never be shorter than MIN_MANUAL_INTERVAL.
function EconomyMath.manualInterval(data: PlayerData, def: StandDef): number
	return math.max(EconomyMath.standInterval(data, def), Economy.MIN_MANUAL_INTERVAL)
end

function EconomyMath.standRate(data: PlayerData, def: StandDef, mods: EconomyModifiers, ent: Entitlements, buff: number): BigNumber
	return BigNumber.mulNumber(EconomyMath.standCycleValue(data, def, mods, ent, buff), 1 / EconomyMath.standInterval(data, def))
end

-- Income per second from every stand that has a manager.
function EconomyMath.managedRate(data: PlayerData, mods: EconomyModifiers, ent: Entitlements, buff: number): BigNumber
	local total = ZERO
	for _, def in Economy.STANDS do
		if EconomyMath.isManaged(data, def.id) then
			total = BigNumber.add(total, EconomyMath.standRate(data, def, mods, ent, buff))
		end
	end
	return total
end

-- Whether the Auto-Collect gamepass runs this stand (owned, no manager).
function EconomyMath.isAutoCollected(data: PlayerData, standId: string, ent: Entitlements): boolean
	return ent.autoCollect and EconomyMath.isOwned(data, standId) and not EconomyMath.isManaged(data, standId)
end

-- Auto-Collect: every owned, unmanaged stand produces continuously at hand-run speed
-- (manual value per manual interval), exactly as if the player stood on its pad.
function EconomyMath.autoCollectRate(data: PlayerData, mods: EconomyModifiers, ent: Entitlements, buff: number): BigNumber
	if not ent.autoCollect then
		return ZERO
	end
	local total = ZERO
	for _, def in Economy.STANDS do
		if EconomyMath.isAutoCollected(data, def.id, ent) then
			local value = EconomyMath.manualCycleValue(data, def, mods, ent, buff)
			total = BigNumber.add(total, BigNumber.mulNumber(value, 1 / EconomyMath.manualInterval(data, def)))
		end
	end
	return total
end

-- Everything that earns without the player standing on a pad: managers plus Auto-Collect.
function EconomyMath.passiveRate(data: PlayerData, mods: EconomyModifiers, ent: Entitlements, buff: number): BigNumber
	return BigNumber.add(EconomyMath.managedRate(data, mods, ent, buff), EconomyMath.autoCollectRate(data, mods, ent, buff))
end

-- ===== Global buffs =====

function EconomyMath.isBuffMilestoneReached(data: PlayerData, def: BuffDef): boolean
	return EconomyMath.ownedStandCount(data) >= def.requiredStands
end

function EconomyMath.buffDuration(data: PlayerData, def: BuffDef): number
	return def.duration * (1 + PERK.longTidesDuration * EconomyMath.perkStacks(data, "LongTides"))
end

-- Strongest active buff at server time `now` (os.time). Buffs never stack.
function EconomyMath.activeBuffMultiplier(data: PlayerData, now: number): number
	local best = 1
	for _, def in Economy.BUFFS do
		local state = data.buffs[def.id]
		if state and state.activeUntil > now then
			best = math.max(best, def.multiplier)
		end
	end
	return best
end

-- ===== Offline =====

function EconomyMath.offlineCapSeconds(data: PlayerData): number
	local cfg = Economy.OFFLINE
	local cap = cfg.baseCapSeconds + EconomyMath.perkStacks(data, "DeepCurrents") * PERK.deepCurrentsCapSeconds
	return math.min(cap, cfg.maxCapSeconds)
end

-- Only managed stands work while the player is away. Buffs do not apply offline.
-- `seconds` must already come from server time.
function EconomyMath.offlineEarnings(data: PlayerData, mods: EconomyModifiers, ent: Entitlements, seconds: number): BigNumber
	if seconds < Economy.OFFLINE.minSeconds then
		return ZERO
	end
	local clamped = math.min(seconds, EconomyMath.offlineCapSeconds(data))
	local perk = PERK.deepCurrentsMultiplier ^ EconomyMath.perkStacks(data, "DeepCurrents")
	local earned = BigNumber.mulNumber(EconomyMath.managedRate(data, mods, ent, 1), clamped * Economy.OFFLINE.efficiency * perk)
	return BigNumber.mul(earned, EconomyMath.statueMultiplier(data, "Offline"))
end

-- ===== Developer products =====

-- Time Warp: `seconds` of income at the current passive rate (no buff), with the same offline
-- bonuses (Deep Currents, Tide Keeper) but no offline cap. Players without any automation get the
-- hand-run rate of their best stand, so the purchase is never worth zero.
function EconomyMath.timeWarpEarnings(data: PlayerData, mods: EconomyModifiers, ent: Entitlements, seconds: number): BigNumber
	local rate = EconomyMath.passiveRate(data, mods, ent, 1)
	if rate.m <= 0 then
		for _, def in Economy.STANDS do
			if EconomyMath.isOwned(data, def.id) then
				local manual = BigNumber.mulNumber(EconomyMath.manualCycleValue(data, def, mods, ent, 1), 1 / EconomyMath.manualInterval(data, def))
				rate = BigNumber.max(rate, manual)
			end
		end
	end
	local perk = PERK.deepCurrentsMultiplier ^ EconomyMath.perkStacks(data, "DeepCurrents")
	local earned = BigNumber.mulNumber(rate, math.max(seconds, 0) * perk)
	return BigNumber.mul(earned, EconomyMath.statueMultiplier(data, "Offline"))
end

function EconomyMath.timeWarpSeconds(): number
	return MonetizationConfig.TIME_WARP_HOURS * 3600
end

-- Starter Pack: base x Evolution multiplier, and at least STARTER_PACK_MIN_MINUTES of current income.
function EconomyMath.starterPackAmount(data: PlayerData, mods: EconomyModifiers, ent: Entitlements): BigNumber
	local scaled = BigNumber.mulNumber(EconomyMath.evolutionMultiplier(data.evolution.level), MonetizationConfig.STARTER_PACK_BASE)
	local income = EconomyMath.timeWarpEarnings(data, mods, ent, MonetizationConfig.STARTER_PACK_MIN_MINUTES * 60)
	return BigNumber.max(scaled, income)
end

-- ===== Evolution & Statues =====

function EconomyMath.evolutionRequirement(level: number): BigNumber?
	local exponent = Evolution.REQUIREMENT_EXPONENTS[level]
	if level >= Evolution.MAX_LEVEL or not exponent then
		return nil
	end
	return BigNumber.fromExponent(exponent)
end

function EconomyMath.canEvolve(data: PlayerData): boolean
	local requirement = EconomyMath.evolutionRequirement(data.evolution.level)
	return requirement ~= nil and BigNumber.gte(data.lifetimeEarned, requirement)
end

function EconomyMath.isStairwayUnlocked(data: PlayerData): boolean
	local cfg = Statues.STAIRWAY
	return data.evolution.level >= cfg.requiredEvolution
		and BigNumber.gte(data.bestCurrency, BigNumber.fromExponent(cfg.requiredBestExponent))
end

return EconomyMath
