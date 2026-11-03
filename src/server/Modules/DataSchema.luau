--!strict
--[[
	DataSchema: converts between live PlayerData and the plain table stored in DataStores.

	* fromSaved() treats input as untrusted. It repairs each field independently, so one bad
	  field never wipes a whole profile, and it reports what it repaired.
	* validateSaved() is the gate before EVERY write. If it fails, the write is refused, so
	  corrupt data is never persisted.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BigNumber = require(Shared.BigNumber)
local Types = require(Shared.Types)
local Economy = require(Shared.Config.Economy)
local Evolution = require(Shared.Config.Evolution)
local Statues = require(Shared.Config.Statues)

type BigNumber = BigNumber.BigNumber
type PlayerData = Types.PlayerData

export type SavedData = {
	version: number,
	currency: { number },
	lifetimeEarned: { number },
	totalEarned: { number },
	bestCurrency: { number },
	investors: number,
	clickLevel: number,
	generators: { [string]: number },
	autoClicker: { tier: number, charge: number },
	evolution: { level: number, perks: { [string]: number } },
	statues: { [string]: boolean },
	lastOnline: number,
	totalClicks: number,
	receipts: { [string]: number },
}

local DataSchema = {}

local LIMITS = Economy.LIMITS
local MAX_INTEGER = 2 ^ 53

function DataSchema.default(): PlayerData
	return {
		version = Economy.DATA_VERSION,
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

local function isInteger(value: unknown, min: number, max: number): boolean
	return typeof(value) == "number" and value == value and value == math.floor(value) and value >= min and value <= max
end

local function readInteger(value: unknown, min: number, max: number, fallback: number, field: string, repairs: { string }): number
	if isInteger(value, min, max) then
		return value :: number
	end
	if value ~= nil then
		table.insert(repairs, field)
	end
	return fallback
end

local function readBig(value: unknown, field: string, repairs: { string }): BigNumber
	if value == nil then
		return BigNumber.ZERO
	end
	local parsed = BigNumber.deserialize(value)
	if parsed and not BigNumber.isNegative(parsed) then
		return parsed
	end
	table.insert(repairs, field)
	return BigNumber.ZERO
end

local function asTable(value: unknown): { [any]: any }?
	return if typeof(value) == "table" then value :: any else nil
end

-- Returns sanitized data and the list of fields that had to be repaired.
function DataSchema.fromSaved(raw: unknown): (PlayerData, { string })
	local data = DataSchema.default()
	local repairs: { string } = {}
	local t = asTable(raw)
	if not t then
		if raw ~= nil then
			table.insert(repairs, "<root>")
		end
		return data, repairs
	end

	-- Future migrations go here: if t.version < N then ... end
	data.currency = readBig(t.currency, "currency", repairs)
	data.lifetimeEarned = readBig(t.lifetimeEarned, "lifetimeEarned", repairs)
	data.totalEarned = readBig(t.totalEarned, "totalEarned", repairs)
	data.bestCurrency = BigNumber.max(readBig(t.bestCurrency, "bestCurrency", repairs), data.currency)
	data.investors = readInteger(t.investors, 0, LIMITS.maxInvestors, 0, "investors", repairs)
	data.clickLevel = readInteger(t.clickLevel, 0, LIMITS.maxLevel, 0, "clickLevel", repairs)
	data.lastOnline = readInteger(t.lastOnline, 0, MAX_INTEGER, 0, "lastOnline", repairs)
	data.totalClicks = readInteger(t.totalClicks, 0, MAX_INTEGER, 0, "totalClicks", repairs)

	local generators = asTable(t.generators)
	for _, def in Economy.GENERATORS do
		local level = if generators then generators[def.id] else nil
		local value = readInteger(level, 0, LIMITS.maxLevel, 0, "generators." .. def.id, repairs)
		if value > 0 then
			data.generators[def.id] = value
		end
	end

	local auto = asTable(t.autoClicker)
	if auto then
		data.autoClicker.tier = readInteger(auto.tier, 0, #Economy.AUTO_CLICKER_TIERS, 0, "autoClicker.tier", repairs)
		data.autoClicker.charge = readInteger(auto.charge, 0, LIMITS.maxCharge, 0, "autoClicker.charge", repairs)
	end

	local evolution = asTable(t.evolution)
	if evolution then
		data.evolution.level = readInteger(evolution.level, 1, Evolution.MAX_LEVEL, 1, "evolution.level", repairs)
		local perks = asTable(evolution.perks)
		if perks then
			for _, perk in Evolution.PERKS do
				local stacks = readInteger(perks[perk.id], 0, Evolution.MAX_LEVEL, 0, "perks." .. perk.id, repairs)
				if stacks > 0 then
					data.evolution.perks[perk.id] = stacks
				end
			end
		end
	end

	local statues = asTable(t.statues)
	if statues then
		for _, statue in Statues.LIST do
			if statues[statue.id] == true then
				data.statues[statue.id] = true
			end
		end
	end

	local receipts = asTable(t.receipts)
	if receipts then
		for id, time in receipts do
			if typeof(id) == "string" and #id <= 64 and isInteger(time, 0, MAX_INTEGER) then
				data.receipts[id] = time
			end
		end
	end

	return data, repairs
end

local function pruneReceipts(receipts: { [string]: number }): { [string]: number }
	local entries: { { id: string, time: number } } = {}
	for id, time in receipts do
		table.insert(entries, { id = id, time = time })
	end
	if #entries <= LIMITS.maxReceipts then
		return table.clone(receipts)
	end
	table.sort(entries, function(a, b)
		return a.time > b.time
	end)
	local kept: { [string]: number } = {}
	for i = 1, LIMITS.maxReceipts do
		kept[entries[i].id] = entries[i].time
	end
	return kept
end

function DataSchema.toSaved(data: PlayerData): SavedData
	return {
		version = Economy.DATA_VERSION,
		currency = BigNumber.serialize(data.currency),
		lifetimeEarned = BigNumber.serialize(data.lifetimeEarned),
		totalEarned = BigNumber.serialize(data.totalEarned),
		bestCurrency = BigNumber.serialize(data.bestCurrency),
		investors = data.investors,
		clickLevel = data.clickLevel,
		generators = table.clone(data.generators),
		autoClicker = { tier = data.autoClicker.tier, charge = math.floor(data.autoClicker.charge) },
		evolution = { level = data.evolution.level, perks = table.clone(data.evolution.perks) },
		statues = table.clone(data.statues),
		lastOnline = data.lastOnline,
		totalClicks = data.totalClicks,
		receipts = pruneReceipts(data.receipts),
	}
end

local function validBig(value: { number }): boolean
	local parsed = BigNumber.deserialize(value)
	return parsed ~= nil and not BigNumber.isNegative(parsed) and #value == 2
end

-- Strict pre-write validation. Any failure aborts the save.
function DataSchema.validateSaved(saved: SavedData): (boolean, string?)
	if saved.version ~= Economy.DATA_VERSION then
		return false, "version"
	end
	for _, field in { "currency", "lifetimeEarned", "totalEarned", "bestCurrency" } do
		if not validBig((saved :: any)[field]) then
			return false, field
		end
	end
	if not isInteger(saved.investors, 0, LIMITS.maxInvestors) then
		return false, "investors"
	end
	if not isInteger(saved.clickLevel, 0, LIMITS.maxLevel) then
		return false, "clickLevel"
	end
	if not isInteger(saved.lastOnline, 0, MAX_INTEGER) or not isInteger(saved.totalClicks, 0, MAX_INTEGER) then
		return false, "counters"
	end
	for id, level in saved.generators do
		if not Economy.GENERATOR_BY_ID[id] or not isInteger(level, 0, LIMITS.maxLevel) then
			return false, "generators." .. tostring(id)
		end
	end
	if not isInteger(saved.autoClicker.tier, 0, #Economy.AUTO_CLICKER_TIERS) or not isInteger(saved.autoClicker.charge, 0, LIMITS.maxCharge) then
		return false, "autoClicker"
	end
	if not isInteger(saved.evolution.level, 1, Evolution.MAX_LEVEL) then
		return false, "evolution.level"
	end
	for id, stacks in saved.evolution.perks do
		if not Evolution.PERK_BY_ID[id] or not isInteger(stacks, 0, Evolution.MAX_LEVEL) then
			return false, "perks." .. tostring(id)
		end
	end
	for id, owned in saved.statues do
		if not Statues.BY_ID[id] or owned ~= true then
			return false, "statues." .. tostring(id)
		end
	end
	local receiptCount = 0
	for id, time in saved.receipts do
		receiptCount += 1
		if typeof(id) ~= "string" or not isInteger(time, 0, MAX_INTEGER) then
			return false, "receipts"
		end
	end
	if receiptCount > LIMITS.maxReceipts then
		return false, "receipts.count"
	end
	return true, nil
end

return DataSchema
