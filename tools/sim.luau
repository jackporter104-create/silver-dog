--!strict
--[[
	Pacing simulator for the stand economy. It drives EconomyMath with a greedy "good player":
	  * hand-runs the best unmanaged stand (MANUAL_EFFICIENCY covers walking and gaps)
	  * uses the strongest unlocked global buff whenever it is off cooldown (time-averaged)
	  * always buys the purchase with the best payback time. Stands unlock in order, and a deed is
	    valued together with the first Multiplier, Speed and the Manager (the pads that must be bought
	    to automate it), because an unmanaged second stand adds nothing while you hand-run another.
	  * progressive pads: Multiplier after the first run, Speed after a Multiplier, Manager after a Speed.
	  * evolves as soon as allowed and buys statues as soon as affordable.
	Reports active play time to each milestone. Run: python3 tools/run_luau.py tools/sim.luau
]]

local BigNumber = require("../shared/BigNumber")
local NumberFormat = require("../shared/NumberFormat")
local EconomyMath = require("../shared/EconomyMath")
local Economy = require("../shared/Config/Economy")
local Statues = require("../shared/Config/Statues")
local Types = require("../shared/Types")

type BigNumber = BigNumber.BigNumber

local MODS = EconomyMath.NEUTRAL_MODIFIERS
local ENT = EconomyMath.NO_ENTITLEMENTS
local MANUAL_EFFICIENCY = 0.8
local MANUAL_GAP = 0.15 -- seconds lost between hand-run cycles
local MAX_HOURS = 24 * 120
local PERK_ROTATION = { "GoldenTouch", "SwiftCurrents", "GoldenTouch", "LongTides", "GoldenTouch", "BusyFins", "GoldenTouch" }

local function newData(): Types.PlayerData
	local stands = EconomyMath.startingStands()
	stands[Economy.STARTING_STAND].revealed = Economy.REVEAL.Multiplier -- first run happens at once
	return {
		version = Economy.DATA_VERSION,
		currency = BigNumber.ZERO,
		lifetimeEarned = BigNumber.ZERO,
		totalEarned = BigNumber.ZERO,
		bestCurrency = BigNumber.ZERO,
		stands = stands,
		buffs = {},
		evolution = { level = 1, perks = {} },
		statues = {},
		lastOnline = 0,
		totalRuns = 0,
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
		table.insert(milestones, string.format("%-40s %s", name, fmtTime(t)))
	end
end

-- Time-averaged multiplier from using the strongest unlocked buff whenever it is ready.
local function buffAverage(d: Types.PlayerData): number
	local best = 1
	for _, def in Economy.BUFFS do
		if EconomyMath.isBuffMilestoneReached(d, def) then
			local duration = EconomyMath.buffDuration(d, def)
			best = math.max(best, 1 + (def.multiplier - 1) * duration / (duration + def.cooldown))
		end
	end
	return best
end

local function manualRate(d: Types.PlayerData, buff: number): (BigNumber, string?)
	local best, bestId = BigNumber.ZERO, nil
	for _, def in Economy.STANDS do
		if EconomyMath.isOwned(d, def.id) and not EconomyMath.isManaged(d, def.id) then
			local value = EconomyMath.manualCycleValue(d, def, MODS, ENT, buff)
			local rate = BigNumber.mulNumber(value, MANUAL_EFFICIENCY / (EconomyMath.manualInterval(d, def) + MANUAL_GAP))
			if BigNumber.gt(rate, best) then
				best, bestId = rate, def.id
			end
		end
	end
	return best, bestId
end

local function totalRate(d: Types.PlayerData): BigNumber
	local buff = buffAverage(d)
	local manual = manualRate(d, buff)
	return BigNumber.add(EconomyMath.managedRate(d, MODS, ENT, buff), manual)
end

local function earn(amount: BigNumber)
	data.currency = BigNumber.add(data.currency, amount)
	data.lifetimeEarned = BigNumber.add(data.lifetimeEarned, amount)
	data.totalEarned = BigNumber.add(data.totalEarned, amount)
	data.bestCurrency = BigNumber.max(data.bestCurrency, data.currency)
end

type Candidate = { name: string, cost: BigNumber, apply: () -> (), simulate: (() -> ())?, valueCost: BigNumber? }

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" or table.isfrozen(value :: any) then
		return value
	end
	local out = {}
	for k, v in value :: any do
		out[k] = deepCopy(v)
	end
	return out :: any
end

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

local function stand(id: string): Types.StandState
	local state = data.stands[id]
	if not state then
		state = { level = 0, multiplier = 0, speed = 0, managerHired = false, revealed = 0 }
		data.stands[id] = state
	end
	return state
end

local function candidates(): { Candidate }
	local list: { Candidate } = {}
	local nextId = EconomyMath.nextStandId(data)
	for _, def in Economy.STANDS do
		local state = EconomyMath.standState(data, def.id)
		if state.level == 0 then
			if def.id == nextId then
				local deed = EconomyMath.deedCost(def, MODS)
				local automation = BigNumber.add(EconomyMath.multiplierCost(def, 0, MODS), BigNumber.add(EconomyMath.speedCost(def, 0, MODS) or BigNumber.ZERO, EconomyMath.managerCost(def, MODS)))
				table.insert(list, {
					name = def.id .. " deed",
					cost = deed,
					valueCost = BigNumber.add(deed, automation),
					apply = function()
						local s = stand(def.id)
						s.level = 1
						s.revealed = Economy.REVEAL.Multiplier -- the player runs it right away
					end,
					simulate = function()
						local s = stand(def.id)
						s.level, s.multiplier, s.speed, s.managerHired, s.revealed = 1, 1, 1, true, 3
					end,
				})
			end
		else
			if state.revealed >= Economy.REVEAL.Multiplier then
				table.insert(list, {
					name = def.id .. " multiplier",
					cost = EconomyMath.multiplierCost(def, state.multiplier, MODS),
					apply = function()
						local s = stand(def.id)
						s.multiplier += 1
						s.revealed = math.max(s.revealed, Economy.REVEAL.Speed)
					end,
				})
			end
			local speedCost = EconomyMath.speedCost(def, state.speed, MODS)
			if speedCost and state.revealed >= Economy.REVEAL.Speed then
				table.insert(list, {
					name = def.id .. " speed",
					cost = speedCost,
					apply = function()
						local s = stand(def.id)
						s.speed += 1
						s.revealed = math.max(s.revealed, Economy.REVEAL.Manager)
					end,
				})
			end
			-- Automation package: whatever Multiplier/Speed is still needed to reveal the Manager, plus the Manager.
			if not state.managerHired and state.revealed < Economy.REVEAL.Manager then
				local packageCost = EconomyMath.managerCost(def, MODS)
				if state.revealed < Economy.REVEAL.Speed then
					packageCost = BigNumber.add(packageCost, EconomyMath.multiplierCost(def, state.multiplier, MODS))
				end
				packageCost = BigNumber.add(packageCost, EconomyMath.speedCost(def, state.speed, MODS) or BigNumber.ZERO)
				table.insert(list, {
					name = def.id .. " automate",
					cost = packageCost,
					apply = function()
						local s = stand(def.id)
						if s.revealed < Economy.REVEAL.Speed then
							s.multiplier += 1
						end
						s.speed += 1
						s.managerHired = true
						s.revealed = Economy.REVEAL.Manager
					end,
				})
			end
			if not state.managerHired and state.revealed >= Economy.REVEAL.Manager then
				table.insert(list, {
					name = def.id .. " manager",
					cost = EconomyMath.managerCost(def, MODS),
					apply = function()
						stand(def.id).managerHired = true
					end,
				})
			end
		end
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

local purchases: { [string]: number } = {}
local TRACE = false
while t < MAX_HOURS * 3600 do
	for _, entry in thresholds do
		if BigNumber.gte(data.totalEarned, entry[2]) then
			mark("Total earned " .. entry[1])
		end
	end
	for _, def in Economy.STANDS do
		if data.evolution.level == 1 and EconomyMath.isOwned(data, def.id) then
			mark("Run 1: own " .. def.name)
		end
		if data.evolution.level == 1 and EconomyMath.isManaged(data, def.id) then
			mark("Run 1: manager for " .. def.name)
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
		purchases[best.name] = (purchases[best.name] or 0) + 1
		if TRACE and t < 3600 then
			print(string.format("t=%7.1f %-24s cost=%-8s rate=%s", t, best.name, NumberFormat.format(best.cost), NumberFormat.formatRate(totalRate(data))))
		end
		continue
	end

	local wait = 60
	if best and baseRate.m > 0 then
		local missing = BigNumber.subClamped(best.cost, data.currency)
		wait = math.clamp(BigNumber.toNumber(BigNumber.div(missing, baseRate)), 1, 600)
	end
	earn(BigNumber.mulNumber(baseRate, wait))
	t += wait
end

print("=== Pacing simulation (active play, greedy buyer) ===")
for _, line in milestones do
	print(line)
end
local parts: { string } = {}
for _, def in Economy.STANDS do
	local s = EconomyMath.standState(data, def.id)
	table.insert(parts, string.format("%s m%d s%d%s", def.id, s.multiplier, s.speed, if s.managerHired then " M" else ""))
end
print("Final run: evolution " .. data.evolution.level .. " | " .. table.concat(parts, ", "))
print("Rate: " .. NumberFormat.formatRate(totalRate(data)) .. "  sim time " .. fmtTime(t))
