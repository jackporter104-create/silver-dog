--!strict
--[[
	EconomyMath: pure, deterministic formulas. No Roblox APIs and no side effects.
	Only the server uses it for authority. tools/sim.luau uses it for pacing.
	The client never calls it; it receives precomputed values in Snapshots.
]]

local BigNumber = require(script.Parent.BigNumber)
local Types = require(script.Parent.Types)
local Economy = require(script.Parent.Config.Economy)
local Evolution = require(script.Parent.Config.Evolution)
local Statues = require(script.Parent.Config.Statues)

type BigNumber = BigNumber.BigNumber
type PlayerData = Types.PlayerData
type EconomyModifiers = Types.EconomyModifiers
type Entitlements = Types.Entitlements

local EconomyMath = {}

local ONE = BigNumber.ONE
local ZERO = BigNumber.ZERO
local PERK = Evolution.PERK_VALUES

EconomyMath.NEUTRAL_MODIFIERS = table.freeze({
	incomeMultiplier = 1,
	clickMultiplier = 1,
	costMultiplier = 1,
	generatorMultipliers = table.freeze({}),
}) :: EconomyModifiers

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

function EconomyMath.generatorCost(def: Economy.GeneratorDef, owned: number, quantity: number, mods: EconomyModifiers): BigNumber
	return EconomyMath.geometricCost(def.baseCost, def.growth, owned, quantity, mods.costMultiplier)
end

function EconomyMath.clickUpgradeCost(level: number, quantity: number, mods: EconomyModifiers): BigNumber
	local cfg = Economy.CLICK_UPGRADE
	return EconomyMath.geometricCost(cfg.baseCost, cfg.growth, level, quantity, mods.costMultiplier)
end

function EconomyMath.investorCost(owned: number, quantity: number, mods: EconomyModifiers): BigNumber
	local cfg = Economy.INVESTOR
	return EconomyMath.geometricCost(cfg.baseCost, cfg.growth, owned, quantity, mods.costMultiplier)
end

function EconomyMath.autoClickerTier(tier: number): Economy.AutoClickerTier?
	return Economy.AUTO_CLICKER_TIERS[tier]
end

function EconomyMath.autoClickerTierCost(tier: number, mods: EconomyModifiers): BigNumber?
	local def = Economy.AUTO_CLICKER_TIERS[tier]
	if not def then
		return nil
	end
	local base = if def.costExponent then BigNumber.fromExponent(def.costExponent) else BigNumber.fromNumber(def.cost)
	return BigNumber.mulNumber(base, mods.costMultiplier)
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

-- Product of owned statue multipliers that target `source`. "All" statues apply only to the
-- primary sources (Click and Passive). Auto, Offline and Investor already derive from those,
-- so applying "All" there too would double-count it.
function EconomyMath.statueMultiplier(data: PlayerData, source: Types.IncomeSource): BigNumber
	local includeAll = source == "Click" or source == "Passive"
	local result = ONE
	for _, statue in Statues.LIST do
		if data.statues[statue.id] and (statue.source == source or (includeAll and statue.source == "All")) then
			result = BigNumber.mulNumber(result, statue.multiplier)
		end
	end
	return result
end

-- Fractional bonus from Investors, for example 0.37 means +37%. Plain number for display.
function EconomyMath.investorBonusFraction(data: PlayerData): number
	local perInvestor = Economy.INVESTOR.bonusPerInvestor
		+ EconomyMath.perkStacks(data, "GoldenInvestors") * PERK.goldenInvestorBonus
	return data.investors * perInvestor
end

function EconomyMath.investorMultiplier(data: PlayerData): BigNumber
	local bonus = BigNumber.fromNumber(EconomyMath.investorBonusFraction(data))
	return BigNumber.add(ONE, BigNumber.mul(bonus, EconomyMath.statueMultiplier(data, "Investor")))
end

-- ===== Income =====

local function milestoneFactor(level: number, milestones: { Economy.Milestone }): BigNumber
	local factor = ONE
	for _, milestone in milestones do
		factor = BigNumber.mul(factor, BigNumber.pow(BigNumber.fromNumber(milestone.multiplier), level // milestone.every))
	end
	return factor
end
EconomyMath.milestoneFactor = milestoneFactor

function EconomyMath.generatorOutput(def: Economy.GeneratorDef, owned: number, mods: EconomyModifiers): BigNumber
	if owned <= 0 then
		return ZERO
	end
	local seasonal = mods.generatorMultipliers[def.id] or 1
	return BigNumber.mul(BigNumber.fromNumber(def.baseOutput * owned * seasonal), milestoneFactor(owned, Economy.GENERATOR_MILESTONES))
end

function EconomyMath.clickValue(data: PlayerData, mods: EconomyModifiers): BigNumber
	local level = data.clickLevel
	local perk = PERK.tidalClickMultiplier ^ EconomyMath.perkStacks(data, "TidalClicks")
	local value = BigNumber.fromNumber((Economy.BASE_CLICK + level) * perk * mods.clickMultiplier * mods.incomeMultiplier)
	value = BigNumber.mul(value, milestoneFactor(level, Economy.CLICK_UPGRADE.milestones))
	value = BigNumber.mul(value, EconomyMath.evolutionMultiplier(data.evolution.level))
	return BigNumber.mul(value, EconomyMath.statueMultiplier(data, "Click"))
end

function EconomyMath.passivePerSecond(data: PlayerData, mods: EconomyModifiers): BigNumber
	local total = ZERO
	for _, def in Economy.GENERATORS do
		total = BigNumber.add(total, EconomyMath.generatorOutput(def, data.generators[def.id] or 0, mods))
	end
	if BigNumber.isZero(total) then
		return ZERO
	end
	local perk = PERK.richReefsMultiplier ^ EconomyMath.perkStacks(data, "RichReefs")
	total = BigNumber.mulNumber(total, perk * mods.incomeMultiplier)
	total = BigNumber.mul(total, EconomyMath.investorMultiplier(data))
	total = BigNumber.mul(total, EconomyMath.evolutionMultiplier(data.evolution.level))
	return BigNumber.mul(total, EconomyMath.statueMultiplier(data, "Passive"))
end

function EconomyMath.isAutoClickerInfinite(data: PlayerData, ent: Entitlements): boolean
	local def = Economy.AUTO_CLICKER_TIERS[data.autoClicker.tier]
	return ent.infiniteAutoClicker or (def ~= nil and def.infinite)
end

function EconomyMath.autoClickerCapacity(data: PlayerData): number
	local def = Economy.AUTO_CLICKER_TIERS[data.autoClicker.tier]
	return if def then def.capacity else 0
end

function EconomyMath.autoClicksPerSecond(data: PlayerData, ent: Entitlements): number
	local def = Economy.AUTO_CLICKER_TIERS[data.autoClicker.tier]
	local cps = if def then def.clicksPerSecond else 0
	if ent.infiniteAutoClicker then
		cps = math.max(cps, Economy.GAMEPASS_AUTO_CPS)
	end
	return cps * PERK.fishFrenzyMultiplier ^ EconomyMath.perkStacks(data, "FishFrenzy")
end

function EconomyMath.isAutoClickerRunning(data: PlayerData, ent: Entitlements): boolean
	if EconomyMath.autoClicksPerSecond(data, ent) <= 0 then
		return false
	end
	return EconomyMath.isAutoClickerInfinite(data, ent) or data.autoClicker.charge > 0
end

-- Income from one automated click (click value times the Auto statue multiplier).
function EconomyMath.autoClickValue(data: PlayerData, mods: EconomyModifiers): BigNumber
	return BigNumber.mul(EconomyMath.clickValue(data, mods), EconomyMath.statueMultiplier(data, "Auto"))
end

function EconomyMath.autoIncomePerSecond(data: PlayerData, mods: EconomyModifiers, ent: Entitlements): BigNumber
	if not EconomyMath.isAutoClickerRunning(data, ent) then
		return ZERO
	end
	return BigNumber.mulNumber(EconomyMath.autoClickValue(data, mods), EconomyMath.autoClicksPerSecond(data, ent))
end

-- What the HUD shows as currency/s: passive plus the running auto-clicker.
function EconomyMath.incomePerSecond(data: PlayerData, mods: EconomyModifiers, ent: Entitlements): BigNumber
	return BigNumber.add(EconomyMath.passivePerSecond(data, mods), EconomyMath.autoIncomePerSecond(data, mods, ent))
end

-- ===== Offline =====

function EconomyMath.offlineCapSeconds(data: PlayerData): number
	local cfg = Economy.OFFLINE
	local cap = cfg.baseCapSeconds + EconomyMath.perkStacks(data, "DeepCurrents") * PERK.deepCurrentsCapSeconds
	return math.min(cap, cfg.maxCapSeconds)
end

-- Offline generation: passive income, plus the auto-clicker only when it never drains.
-- Finite batteries do not run offline. `seconds` must already come from server time.
function EconomyMath.offlineEarnings(data: PlayerData, mods: EconomyModifiers, ent: Entitlements, seconds: number): BigNumber
	if seconds < Economy.OFFLINE.minSeconds then
		return ZERO
	end
	local clamped = math.min(seconds, EconomyMath.offlineCapSeconds(data))
	local rate = EconomyMath.passivePerSecond(data, mods)
	if EconomyMath.isAutoClickerInfinite(data, ent) then
		rate = BigNumber.add(rate, EconomyMath.autoIncomePerSecond(data, mods, ent))
	end
	local perk = PERK.deepCurrentsMultiplier ^ EconomyMath.perkStacks(data, "DeepCurrents")
	local earned = BigNumber.mulNumber(rate, clamped * Economy.OFFLINE.efficiency * perk)
	return BigNumber.mul(earned, EconomyMath.statueMultiplier(data, "Offline"))
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
