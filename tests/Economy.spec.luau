--!strict
-- CLI tests for the stand economy (EconomyMath), NumberFormat.parse and the Guard rate limiter.
-- Run: python3 tools/run_luau.py tests/Economy.spec.luau

local BigNumber = require("../shared/BigNumber")
local NumberFormat = require("../shared/NumberFormat")
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
local ENT = EconomyMath.NO_ENTITLEMENTS

local function newData(): Types.PlayerData
	return {
		version = Economy.DATA_VERSION,
		currency = BigNumber.ZERO,
		lifetimeEarned = BigNumber.ZERO,
		totalEarned = BigNumber.ZERO,
		bestCurrency = BigNumber.ZERO,
		stands = EconomyMath.startingStands(),
		buffs = {},
		evolution = { level = 1, perks = {} },
		statues = {},
		lastOnline = 0,
		totalRuns = 0,
		starterPackClaimed = false,
		receipts = {},
	}
end

local function approx(a: BigNumber.BigNumber, b: number): boolean
	return math.abs(BigNumber.toNumber(a) - b) <= math.abs(b) * 1e-9
end

local clam = Economy.STAND_BY_ID.PearlClam
local coral = Economy.STAND_BY_ID.CoralFarm

-- Start: only the Pearl Clam is owned, unmanaged, normal numbers
local d = newData()
check("starts at zero", BigNumber.isZero(d.currency))
check("clam owned at start", EconomyMath.isOwned(d, "PearlClam") and EconomyMath.ownedStandCount(d) == 1)
check("other stands locked", not EconomyMath.isOwned(d, "CoralFarm"))
check("no managed income at start", BigNumber.isZero(EconomyMath.managedRate(d, MODS, ENT, 1)))
check("clam cycle = 1 pearl", approx(EconomyMath.standCycleValue(d, clam, MODS, ENT, 1), 1))
check("clam interval 1s", EconomyMath.standInterval(d, clam) == 1)
check("coral deed cost", approx(EconomyMath.deedCost(coral, MODS), coral.deedCost))

-- Multiplier pad: x2 per level; Speed pad: interval / 2 per level, capped
d.stands.PearlClam.multiplier = 3
check("multiplier x8 at level 3", approx(EconomyMath.standCycleValue(d, clam, MODS, ENT, 1), 8))
d.stands.PearlClam.speed = 2
check("speed x4 at level 2", EconomyMath.standInterval(d, clam) == 0.25)
check("rate = value / interval", approx(EconomyMath.standRate(d, clam, MODS, ENT, 1), 32))
check("speed capped", EconomyMath.speedCost(clam, Economy.MAX_SPEED_LEVEL, MODS) == nil)
check("manual interval floor", EconomyMath.manualInterval(d, clam) >= Economy.MIN_MANUAL_INTERVAL)

-- Costs scale exponentially and stay monotonic across the BigNumber boundary
local previous = BigNumber.ZERO
local monotonic = true
for level = 0, 120, 4 do
	local cost = EconomyMath.multiplierCost(clam, level, MODS)
	if BigNumber.lte(cost, previous) then
		monotonic = false
	end
	previous = cost
end
check("multiplier costs strictly increase through 1e15+", monotonic and BigNumber.isBig(previous))
check("multiplier cost growth > x2 (walls)", clam.multiplierGrowth > 2)

-- Managers: only managed stands count toward passive income
check("unmanaged = no passive", BigNumber.isZero(EconomyMath.managedRate(d, MODS, ENT, 1)))
d.stands.PearlClam.managerHired = true
check("managed = passive", approx(EconomyMath.managedRate(d, MODS, ENT, 1), 32))

-- Global buffs: milestone unlock, strongest only, applies to all stands
local tidal = Economy.BUFF_BY_ID.TidalRush
check("buff locked with 1 stand", not EconomyMath.isBuffMilestoneReached(d, tidal))
d.stands.CoralFarm = { level = 1, multiplier = 0, speed = 0, managerHired = true, revealed = 3 }
check("buff unlocks with 2 stands", EconomyMath.isBuffMilestoneReached(d, tidal))
d.buffs.TidalRush = { unlocked = true, activeUntil = 130, readyAt = 220 }
d.buffs.CoralBloom = { unlocked = true, activeUntil = 110, readyAt = 260 }
check("strongest active buff wins", EconomyMath.activeBuffMultiplier(d, 100) == 3)
check("expired buff ignored", EconomyMath.activeBuffMultiplier(d, 120) == 2)
check("no buff after expiry", EconomyMath.activeBuffMultiplier(d, 200) == 1)
local base = EconomyMath.managedRate(d, MODS, ENT, 1)
check("buff multiplies all stands", approx(EconomyMath.managedRate(d, MODS, ENT, 4), BigNumber.toNumber(base) * 4))
check("Busy Fins only affects manual", (function()
	d.evolution.perks.BusyFins = 1
	local ok = approx(EconomyMath.manualCycleValue(d, clam, MODS, ENT, 1), BigNumber.toNumber(EconomyMath.standCycleValue(d, clam, MODS, ENT, 1)) * 3)
	d.evolution.perks.BusyFins = nil
	return ok
end)())

-- Evolution multiplier 42^(L-1) and gate
check("evo 1 = x1", approx(EconomyMath.evolutionMultiplier(1), 1))
check("evo 2 = x42", approx(EconomyMath.evolutionMultiplier(2), 42))
check("evo 8 = x42^7", approx(EconomyMath.evolutionMultiplier(8), 42 ^ 7))
check("evolve gated at 1B", not EconomyMath.canEvolve(d))
d.lifetimeEarned = BigNumber.fromNumber(1e9)
check("can evolve at 1B", EconomyMath.canEvolve(d))

-- Statues target exact sources (no double counting)
local before = EconomyMath.standCycleValue(d, clam, MODS, ENT, 1)
d.statues.ClamColossus = true
check("stand statue boosts its stand", approx(EconomyMath.standCycleValue(d, clam, MODS, ENT, 1), BigNumber.toNumber(before) * 1e5))
check("stand statue leaves others", approx(EconomyMath.standCycleValue(d, coral, MODS, ENT, 1), coral.baseValue))
d.statues = {}

-- Offline: managed stands only, 100%, capped, no buffs
local rate = EconomyMath.managedRate(d, MODS, ENT, 1)
check("offline 1h = 100% managed", approx(EconomyMath.offlineEarnings(d, MODS, ENT, 3600), BigNumber.toNumber(rate) * 3600))
check("offline capped at 8h", approx(EconomyMath.offlineEarnings(d, MODS, ENT, 10 * 86400), BigNumber.toNumber(rate) * 8 * 3600))
check("offline ignores < 60s", BigNumber.isZero(EconomyMath.offlineEarnings(d, MODS, ENT, 30)))
check("offline negative time = 0", BigNumber.isZero(EconomyMath.offlineEarnings(d, MODS, ENT, -5000)))

-- Progressive reveal: one mystery deed at a time, upgrade pads one by one
local r = newData()
check("only next deed visible", EconomyMath.isPadVisible(r, "Deed", "CoralFarm") and not EconomyMath.isPadVisible(r, "Deed", "KelpFactory"))
check("owned stand has no deed", not EconomyMath.isPadVisible(r, "Deed", "PearlClam"))
check("main pad only when owned", EconomyMath.isPadVisible(r, "StandMain", "PearlClam") and not EconomyMath.isPadVisible(r, "StandMain", "CoralFarm"))
check("no upgrade pads on a new stand", not EconomyMath.isPadVisible(r, "Multiplier", "PearlClam") and not EconomyMath.isPadVisible(r, "Speed", "PearlClam") and not EconomyMath.isPadVisible(r, "Manager", "PearlClam"))
r.stands.PearlClam.revealed = 1
check("Multiplier after first run", EconomyMath.isPadVisible(r, "Multiplier", "PearlClam") and not EconomyMath.isPadVisible(r, "Speed", "PearlClam"))
r.stands.PearlClam.revealed = 2
check("Speed after Multiplier", EconomyMath.isPadVisible(r, "Speed", "PearlClam") and not EconomyMath.isPadVisible(r, "Manager", "PearlClam"))
r.stands.PearlClam.revealed = 3
check("Manager after Speed", EconomyMath.isPadVisible(r, "Manager", "PearlClam"))
r.stands.CoralFarm = { level = 1, multiplier = 0, speed = 0, managerHired = false, revealed = 0 }
check("next deed moves on", EconomyMath.nextStandId(r) == "KelpFactory" and EconomyMath.isPadVisible(r, "Deed", "KelpFactory"))
check("buff pad hidden until unlocked", not EconomyMath.isPadVisible(r, "Buff", "TidalRush"))
r.buffs.TidalRush = { unlocked = true, activeUntil = 0, readyAt = 0 }
check("buff pad shown once unlocked", EconomyMath.isPadVisible(r, "Buff", "TidalRush"))
check("hub pads always visible", EconomyMath.isPadVisible(r, "Evolve", "GoldenTouch") and EconomyMath.isPadVisible(r, "Statue", "ClamColossus"))

-- Monetization: x2 Income, Auto-Collect, Time Warp, Starter Pack
local m = newData()
local x2: Types.Entitlements = { doubleIncome = true, autoCollect = false }
local auto: Types.Entitlements = { doubleIncome = false, autoCollect = true }
check("x2 Income doubles cycle value", approx(EconomyMath.standCycleValue(m, clam, MODS, x2, 1), 2))
check("no auto-collect without pass", BigNumber.isZero(EconomyMath.autoCollectRate(m, MODS, ENT, 1)))
check("auto-collect runs unmanaged stand at hand rate", approx(EconomyMath.autoCollectRate(m, MODS, auto, 1), 1))
check("auto-collect is passive income", approx(EconomyMath.passiveRate(m, MODS, auto, 1), 1))
m.stands.PearlClam.managerHired = true
check("managed stand not double counted", BigNumber.isZero(EconomyMath.autoCollectRate(m, MODS, auto, 1)) and approx(EconomyMath.passiveRate(m, MODS, auto, 1), 1))
check("auto-collect flag", not EconomyMath.isAutoCollected(m, "PearlClam", auto))
m.stands.PearlClam.managerHired = false
check("time warp = 4h", EconomyMath.timeWarpSeconds() == 4 * 3600)
check("time warp falls back to hand rate", approx(EconomyMath.timeWarpEarnings(m, MODS, ENT, 3600), 3600))
m.stands.PearlClam.managerHired = true
m.stands.PearlClam.multiplier = 2
check("time warp uses passive rate, no offline cap", approx(EconomyMath.timeWarpEarnings(m, MODS, ENT, 20 * 3600), 4 * 20 * 3600))
check("starter pack base at evo 1", approx(EconomyMath.starterPackAmount(newData(), MODS, ENT), 250_000))
local late = newData()
late.evolution.level = 3
check("starter pack scales with evolution", approx(EconomyMath.starterPackAmount(late, MODS, ENT), 250_000 * 42 ^ 2))

-- Dev command amount parsing
local function parses(text: string, expected: BigNumber.BigNumber)
	local value = NumberFormat.parse(text)
	check("parse " .. text, value ~= nil and BigNumber.eq(value, expected), if value then BigNumber.toString(value) else "nil")
end
parses("10B", BigNumber.fromNumber(1e10))
parses("1500", BigNumber.fromNumber(1500))
parses("2.5t", BigNumber.fromNumber(2.5e12))
parses("1e30", BigNumber.fromExponent(30))
parses("1.5UQq", BigNumber.fromExponent(156, 1.5))
parses("1 000", BigNumber.fromNumber(1000))
check("parse rejects junk", NumberFormat.parse("abc") == nil and NumberFormat.parse("-5") == nil and NumberFormat.parse("5Zz") == nil)
for group = 1, 101 do
	local suffix = NumberFormat.shortSuffix(group) or ""
	local value = NumberFormat.parse("1" .. suffix)
	if not value or not BigNumber.eq(value, BigNumber.fromExponent(group * 3)) then
		check("suffix round-trip " .. suffix, false)
	end
end

-- Guard: token bucket and strikes
local now = 0
local fakePlayer = ({} :: any) :: Player
local abused = 0
local guard = Guard.new({ Run = { rate = 10, burst = 5 } }, 20, function()
	abused += 1
end, function()
	return now
end)
local allowed = 0
for _ = 1, 100 do
	if guard:allow(fakePlayer, "Run") then
		allowed += 1
	end
end
check("burst limits instant spam", allowed == 5, tostring(allowed))
check("abuse callback fires after strikes", abused >= 1)
now = 1
local refill = 0
for _ = 1, 100 do
	if guard:allow(fakePlayer, "Run") then
		refill += 1
	end
end
check("refills at rate (capped by burst)", refill == 5, tostring(refill))
check("unknown key denied", not guard:allow(fakePlayer, "Nope"))

print(string.format("Economy/Guard: %d passed, %d failed", passed, failed))
if failed > 0 then
	error("tests failed")
end
