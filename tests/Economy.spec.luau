--!strict
-- CLI tests for EconomyMath rules and the Guard rate limiter.
-- Run: python3 tools/run_luau.py tests/Economy.spec.luau

local BigNumber = require("../shared/BigNumber")
local EconomyMath = require("../shared/EconomyMath")
local Economy = require("../shared/Config/Economy")
local Types = require("../shared/Types")
local Guard = require("../server/Modules/Guard")

local passed, failed = 0, 0
local function check(name: string, condition: boolean, detail: string?)
	if condition then
		passed += 1
	else
		failed += 1
		print("FAIL: " .. name .. (if detail then " (" .. detail .. ")" else ""))
	end
end

local MODS = EconomyMath.NEUTRAL_MODIFIERS
local NO_ENT: Types.Entitlements = { infiniteAutoClicker = false }

local function newData(): Types.PlayerData
	return {
		version = 1,
		currency = BigNumber.ZERO,
		lifetimeEarned = BigNumber.ZERO,
		totalEarned = BigNumber.ZERO,
		bestCurrency = BigNumber.ZERO,
		investors = 0,
		clickLevel = 0,
		generators = {},
		autoClicker = { tier = 0, charge = 0 },
		evolution = { level = 1, perks = {} },
		statues = {},
		lastOnline = 0,
		totalClicks = 0,
		receipts = {},
	}
end

local function approx(a: BigNumber.BigNumber, b: number): boolean
	return math.abs(BigNumber.toNumber(a) - b) <= math.abs(b) * 1e-9
end

-- Early game uses normal numbers
local d = newData()
check("starts at zero", BigNumber.isZero(d.currency))
check("first click = 1", approx(EconomyMath.clickValue(d, MODS), 1))
check("no passive at start", BigNumber.isZero(EconomyMath.passivePerSecond(d, MODS)))
local shrimp = Economy.GENERATOR_BY_ID.Shrimp
check("shrimp costs 15", approx(EconomyMath.generatorCost(shrimp, 0, 1, MODS), 15))

-- Bulk cost equals the sum of single purchases
local sum = BigNumber.ZERO
for owned = 7, 16 do
	sum = BigNumber.add(sum, EconomyMath.generatorCost(shrimp, owned, 1, MODS))
end
local bulk = EconomyMath.generatorCost(shrimp, 7, 10, MODS)
check("x10 = sum of 10 singles", math.abs(BigNumber.toNumber(bulk) / BigNumber.toNumber(sum) - 1) < 1e-9)

-- Exponential growth across the BigNumber boundary stays monotonic
local previous = BigNumber.ZERO
local monotonic = true
for owned = 0, 600, 5 do
	local cost = EconomyMath.generatorCost(shrimp, owned, 1, MODS)
	if BigNumber.lte(cost, previous) then
		monotonic = false
	end
	previous = cost
end
check("costs strictly increase through 1e15+", monotonic and BigNumber.isBig(previous))

-- Investors: flat +1% each
d.generators.Shrimp = 10
local base = EconomyMath.passivePerSecond(d, MODS)
d.investors = 50
check("50 investors = +50%", approx(EconomyMath.passivePerSecond(d, MODS), BigNumber.toNumber(base) * 1.5))
check("investor bonus fraction", math.abs(EconomyMath.investorBonusFraction(d) - 0.5) < 1e-12)

-- Evolution multiplier 42^(L-1)
check("evo 1 = x1", approx(EconomyMath.evolutionMultiplier(1), 1))
check("evo 2 = x42", approx(EconomyMath.evolutionMultiplier(2), 42))
check("evo 8 = x42^7", approx(EconomyMath.evolutionMultiplier(8), 42 ^ 7))
check("evolve gated at 1B", not EconomyMath.canEvolve(d))
d.lifetimeEarned = BigNumber.fromNumber(1e9)
check("can evolve at 1B", EconomyMath.canEvolve(d))
d.evolution.level = 8
check("no evolution past 8", EconomyMath.evolutionRequirement(8) == nil and not EconomyMath.canEvolve(d))
d.evolution.level = 1

-- "All" statues apply once to Click/Passive, never double through Auto/Investor/Offline
local before = EconomyMath.passivePerSecond(d, MODS)
d.statues.PearlEmpress = true -- All x1e8
local after = EconomyMath.passivePerSecond(d, MODS)
check("All statue applies once to passive", math.abs(BigNumber.log10(after) - BigNumber.log10(before) - 8) < 1e-9)
check("All excluded from Auto multiplier", BigNumber.eq(EconomyMath.statueMultiplier(d, "Auto"), BigNumber.ONE))
check("All excluded from Investor multiplier", BigNumber.eq(EconomyMath.statueMultiplier(d, "Investor"), BigNumber.ONE))
d.statues = {}

-- Auto-clicker: finite battery stops when drained; infinite tier/pass keeps running
d.autoClicker = { tier = 1, charge = 0 }
check("drained battery stops", not EconomyMath.isAutoClickerRunning(d, NO_ENT))
d.autoClicker.charge = 10
check("charged battery runs", EconomyMath.isAutoClickerRunning(d, NO_ENT))
check("gamepass makes it infinite", EconomyMath.isAutoClickerInfinite(d, { infiniteAutoClicker = true }))
d.autoClicker = { tier = #Economy.AUTO_CLICKER_TIERS, charge = 0 }
check("final tier is infinite", EconomyMath.isAutoClickerRunning(d, NO_ENT))
local finalCost = EconomyMath.autoClickerTierCost(#Economy.AUTO_CLICKER_TIERS, MODS)
check("infinite tier costs 1e15", finalCost ~= nil and BigNumber.eq(finalCost, BigNumber.fromExponent(15)))

-- Offline: 100% of passive, capped, ignores tiny gaps
d.autoClicker = { tier = 0, charge = 0 }
local rate = EconomyMath.passivePerSecond(d, MODS)
check("offline 1h = 100% passive", approx(EconomyMath.offlineEarnings(d, MODS, NO_ENT, 3600), BigNumber.toNumber(rate) * 3600))
check("offline capped at 8h", approx(EconomyMath.offlineEarnings(d, MODS, NO_ENT, 10 * 86400), BigNumber.toNumber(rate) * 8 * 3600))
check("offline ignores < 60s", BigNumber.isZero(EconomyMath.offlineEarnings(d, MODS, NO_ENT, 30)))
check("offline negative time = 0", BigNumber.isZero(EconomyMath.offlineEarnings(d, MODS, NO_ENT, -5000)))
d.evolution.perks.DeepCurrents = 1
check("Deep Currents: +4h cap", EconomyMath.offlineCapSeconds(d) == 12 * 3600)

-- Stairway gating
check("stairway locked early", not EconomyMath.isStairwayUnlocked(d))
d.evolution.level = 5
d.bestCurrency = BigNumber.fromExponent(30)
check("stairway opens at evo 5 + 1e30 held", EconomyMath.isStairwayUnlocked(d))

-- Guard: token bucket and strikes
local now = 0
local fakePlayer = ({} :: any) :: Player
local abused = 0
local guard = Guard.new({ Click = { rate = 10, burst = 5 } }, 20, function()
	abused += 1
end, function()
	return now
end)
local allowed = 0
for _ = 1, 100 do
	if guard:allow(fakePlayer, "Click") then
		allowed += 1
	end
end
check("burst limits instant spam", allowed == 5, tostring(allowed))
check("abuse callback fires after strikes", abused >= 1)
now = 1
local refill = 0
for _ = 1, 100 do
	if guard:allow(fakePlayer, "Click") then
		refill += 1
	end
end
check("refills at rate", refill == 5, tostring(refill)) -- capped by burst
check("unknown key denied", not guard:allow(fakePlayer, "Nope"))

print(string.format("Economy/Guard: %d passed, %d failed", passed, failed))
if failed > 0 then
	error("tests failed")
end
