--!strict
--[[
	Evolution (prestige). Level L multiplies ALL income by 42^(L-1):
	  L1 x1, L2 x42, L3 x1,764, L4 x74,088 ... L8 x42^7 (about 2.3e11).
	Evolving resets currency, stands, upgrades, managers and global buff unlocks. It keeps
	statues and chosen perks. Evolution happens on physical perk pads around the altar:
	the pad you stand on is the perk you pick (they stack).
]]

export type PerkDef = {
	id: string,
	name: string,
	description: string,
}

local Evolution = {}

Evolution.MAX_LEVEL = 8
Evolution.MULTIPLIER_BASE = 42
-- Seconds the player must stay on a perk pad before evolving (prevents accidental resets).
Evolution.CONFIRM_SECONDS = 2

-- Lifetime currency earned *during the current run* needed to evolve from level L to L+1,
-- expressed as a power of ten. Index = current level.
Evolution.REQUIREMENT_EXPONENTS = {
	[1] = 9, -- 1 Billion: the first real achievement
	[2] = 17,
	[3] = 21,
	[4] = 25,
	[5] = 34,
	[6] = 40,
	[7] = 45,
} :: { [number]: number }

Evolution.PERKS = {
	{ id = "GoldenTouch", name = "Golden Touch", description = "x2 all income" },
	{ id = "BusyFins", name = "Busy Fins", description = "x3 pearls from stands you run by hand" },
	{ id = "SwiftCurrents", name = "Swift Currents", description = "All stands work x1.5 faster" },
	{ id = "LongTides", name = "Long Tides", description = "Global buffs last 50% longer" },
	{ id = "DeepCurrents", name = "Deep Currents", description = "x2 offline earnings, +4h offline cap" },
} :: { PerkDef }

Evolution.PERK_BY_ID = {} :: { [string]: PerkDef }
for _, perk in Evolution.PERKS do
	Evolution.PERK_BY_ID[perk.id] = perk
end

Evolution.PERK_VALUES = {
	goldenTouchMultiplier = 2,
	busyFinsMultiplier = 3,
	swiftCurrentsSpeed = 1.5,
	longTidesDuration = 0.5,
	deepCurrentsMultiplier = 2,
	deepCurrentsCapSeconds = 4 * 3600,
}

return Evolution
