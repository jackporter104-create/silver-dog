--!strict
--[[
	Pacing simulator. It drives EconomyMath with a greedy "good player":
	  * clicks ~2 times/s on average (active play), recharges the auto-clicker whenever it runs dry
	  * always buys the purchase with the best payback time
	  * evolves as soon as allowed, buys statues as soon as affordable
	Reports active-play time to each milestone. Run: python3 tools/run_luau.py tools/sim.luau
]]

local BigNumber = require("../shared/BigNumber")
local NumberFormat = require("../shared/NumberFormat")
local EconomyMath = require("../shared/EconomyMath")
local Economy = require("../shared/Config/Economy")
local Evolution = require("../shared/Config/Evolution")
local Statues = require("../shared/Config/Statues")
local Types = require("../shared/Types")

type BigNumber = BigNumber.BigNumber

local MODS = EconomyMath.NEUTRAL_MODIFIERS
local ENT: Types.Entitlements = { infiniteAutoClicker = false }
local MANUAL_CPS = 2
local MAX_HOURS = 24 * 120
local PERK_ROTATION = { "RichReefs", "TidalClicks", "RichReefs", "FishFrenzy", "RichReefs", "GoldenInvestors", "RichReefs" }

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

local data = newData()
local t = 0
local milestones: { string } = {}
local reached: { [string]: boolean } = {}

local function fmtTime(seconds: number): string
	if seconds < 3600 then
		return string.format("%.1f min", seconds / 60)
	elseif seconds < 86400 * 2 then
		return string.format("%.2f h", seconds / 3600)
	end
	return string.format("%.1f days (%.0f h)", seconds / 86400, seconds / 3600)
end

local function mark(name: string)
	if not reached[name] then
		reached[name] = true
		table.insert(milestones, string.format("%-34s %s", name, fmtTime(t)))
	end
end

local function totalRate(d: Types.PlayerData): BigNumber
	local manual = BigNumber.mulNumber(EconomyMath.clickValue(d, MODS), MANUAL_CPS)
	return BigNumber.add(EconomyMath.incomePerSecond(d, MODS, ENT), manual)
end

local function earn(amount: BigNumber)
	data.currency = BigNumber.add(data.currency, amount)
	data.lifetimeEarned = BigNumber.add(data.lifetimeEarned, amount)
	data.totalEarned = BigNumber.add(data.totalEarned, amount)
	data.bestCurrency = BigNumber.max(data.bestCurrency, data.currency)
end

-- `simulate` and `valueCost` let a purchase be valued differently than it is applied
-- (an Investor that unlocks a generator is valued together with that generator's first level).
type Candidate = { name: string, cost: BigNumber, apply: () -> (), simulate: (() -> ())?, valueCost: BigNumber? }

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	if table.isfrozen(value :: any) then
		return value
	end
	local out = {}
	for k, v in value :: any do
		out[k] = deepCopy(v)
	end
	return out :: any
end

-- Payback seconds = cost / (rate gain). Locked or useless options return nil.
local function payback(candidate: Candidate, baseRate: BigNumber): number?
	local saved = data
	data = deepCopy(saved)
	local mutate = candidate.simulate or candidate.apply
	mutate()
	local newRate = totalRate(data)
	data = saved
	local gain = BigNumber.sub(newRate, baseRate)
	if gain.m <= 0 then
		return nil
	end
	return BigNumber.toNumber(BigNumber.div(candidate.valueCost or candidate.cost, gain))
end

local function candidates(): { Candidate }
	local list: { Candidate } = {}
	for _, def in Economy.GENERATORS do
		if data.investors >= def.requiredInvestors then
			local owned = data.generators[def.id] or 0
			table.insert(list, {
				name = def.id,
				cost = EconomyMath.generatorCost(def, owned, 1, MODS),
				apply = function()
					data.generators[def.id] = (data.generators[def.id] or 0) + 1
				end,
			})
		end
	end
	table.insert(list, {
		name = "Click",
		cost = EconomyMath.clickUpgradeCost(data.clickLevel, 1, MODS),
		apply = function()
			data.clickLevel += 1
		end,
	})
	local unlocks: Economy.GeneratorDef? = nil
	for _, def in Economy.GENERATORS do
		if def.requiredInvestors == data.investors + 1 then
			unlocks = def
		end
	end
	local investorCost = EconomyMath.investorCost(data.investors, 1, MODS)
	table.insert(list, {
		name = "Investor",
		cost = investorCost,
		valueCost = if unlocks then BigNumber.add(investorCost, EconomyMath.generatorCost(unlocks, 0, 1, MODS)) else nil,
		apply = function()
			data.investors += 1
		end,
		simulate = function()
			data.investors += 1
			if unlocks then
				data.generators[unlocks.id] = math.max(data.generators[unlocks.id] or 0, 1)
			end
		end,
	})
	local nextTier = data.autoClicker.tier + 1
	local tierDef = EconomyMath.autoClickerTier(nextTier)
	local tierCost = EconomyMath.autoClickerTierCost(nextTier, MODS)
	if tierDef and tierCost and data.evolution.level >= tierDef.requiredEvolution then
		table.insert(list, {
			name = "AutoClicker" .. nextTier,
			cost = tierCost,
			apply = function()
				data.autoClicker.tier = nextTier
				data.autoClicker.charge = tierDef.capacity
			end,
		})
	end
	return list
end

local function tryStatues(): boolean
	if not EconomyMath.isStairwayUnlocked(data) then
		return false
	end
	mark("Heavenly Stairway unlocked")
	for _, statue in Statues.LIST do
		if not data.statues[statue.id] then
			local cost = EconomyMath.statueCost(statue)
			if BigNumber.gte(data.currency, cost) then
				data.currency = BigNumber.subClamped(data.currency, cost)
				data.statues[statue.id] = true
				mark("Statue " .. statue.name .. " (1e" .. statue.costExponent .. ")")
				return true
			end
			return false -- buy strictly in order
		end
	end
	return false
end

local function evolve()
	local perk = PERK_ROTATION[((data.evolution.level - 1) % #PERK_ROTATION) + 1]
	local level = data.evolution.level + 1
	local fresh = newData()
	fresh.evolution = { level = level, perks = data.evolution.perks }
	fresh.evolution.perks[perk] = (fresh.evolution.perks[perk] or 0) + 1
	fresh.autoClicker = { tier = data.autoClicker.tier, charge = EconomyMath.autoClickerCapacity(data) }
	fresh.statues = data.statues
	fresh.totalEarned = data.totalEarned
	fresh.bestCurrency = data.bestCurrency
	data = fresh
	mark(string.format("Evolution %d (x%s)", level, NumberFormat.format(EconomyMath.evolutionMultiplier(level))))
end

local thresholds = {
	{ "1K", BigNumber.fromNumber(1e3) },
	{ "1M", BigNumber.fromNumber(1e6) },
	{ "1B", BigNumber.fromNumber(1e9) },
	{ "1T", BigNumber.fromNumber(1e12) },
	{ "1Qa (BigNumber big form)", BigNumber.fromExponent(15) },
	{ "1e30", BigNumber.fromExponent(30) },
	{ "1e60", BigNumber.fromExponent(60) },
	{ "1e100", BigNumber.fromExponent(100) },
	{ "1 Unquinquagintillion (1e156)", BigNumber.fromExponent(156) },
}

local rechargeCooldown = 0
while t < MAX_HOURS * 3600 do
	for _, entry in thresholds do
		if BigNumber.gte(data.totalEarned, entry[2]) then
			mark("Total earned " .. entry[1])
		end
	end
	if data.statues.HeartOfTheOcean then
		break
	end
	if EconomyMath.canEvolve(data) then
		evolve()
		continue
	end
	if tryStatues() then
		continue
	end

	-- Greedy purchase
	local baseRate = totalRate(data)
	local best: Candidate? = nil
	local bestPayback = math.huge
	for _, candidate in candidates() do
		local p = payback(candidate, baseRate)
		if p and p < bestPayback then
			best, bestPayback = candidate, p
		end
	end
	if best and BigNumber.gte(data.currency, best.cost) then
		data.currency = BigNumber.subClamped(data.currency, best.cost)
		best.apply()
		continue
	end

	-- Advance time until the best option is affordable (bounded so events stay accurate).
	local wait = 60
	if best and baseRate.m > 0 then
		local missing = BigNumber.subClamped(best.cost, data.currency)
		wait = math.clamp(BigNumber.toNumber(BigNumber.div(missing, baseRate)), 1, 600)
	end
	-- Finite battery drains; the player walks back to recharge after a short delay.
	local cps = EconomyMath.autoClicksPerSecond(data, ENT)
	if cps > 0 and not EconomyMath.isAutoClickerInfinite(data, ENT) then
		if data.autoClicker.charge <= 0 then
			rechargeCooldown -= wait
			if rechargeCooldown <= 0 then
				data.autoClicker.charge = EconomyMath.autoClickerCapacity(data)
				rechargeCooldown = 120
			end
		else
			wait = math.min(wait, math.max(1, data.autoClicker.charge / cps))
		end
	end
	local rate = totalRate(data)
	if cps > 0 and not EconomyMath.isAutoClickerInfinite(data, ENT) then
		data.autoClicker.charge = math.max(0, data.autoClicker.charge - cps * wait)
	end
	earn(BigNumber.mulNumber(rate, wait))
	t += wait
end

print("=== Pacing simulation (active play, greedy buyer) ===")
for _, line in milestones do
	print(line)
end
print(string.format("Final: evolution %d, investors %d, statues owned %d, clickLevel %d", data.evolution.level, data.investors, (function()
	local n = 0
	for _ in data.statues do
		n += 1
	end
	return n
end)(), data.clickLevel))
local gens: { string } = {}
for _, def in Economy.GENERATORS do
	table.insert(gens, def.id .. "=" .. (data.generators[def.id] or 0))
end
print("Generators: " .. table.concat(gens, " "))
print("Rate: " .. NumberFormat.formatRate(totalRate(data)) .. "  sim time " .. fmtTime(t))
local _ = Evolution
