--!strict
--[[
	Evolution (prestige). Level L multiplies ALL income by 42^(L-1):
	  L1 x1, L2 x42, L3 x1,764, L4 x74,088 ... L8 x42^7 (about 2.3e11).
	Evolving wipes currency, Investors, generators and click upgrades. It keeps auto-clicker
	tiers, Statues and chosen perks. Each evolution lets the player pick ONE perk (they stack).
]]

export type PerkDef = {
	id: string,
	name: string,
	description: string,
}

local Evolution = {}

Evolution.MAX_LEVEL = 8
Evolution.MULTIPLIER_BASE = 42

-- Lifetime currency earned *during the current run* needed to evolve from level L to L+1,
-- expressed as a power of ten. Index = current level.
Evolution.REQUIREMENT_EXPONENTS = {
	[1] = 9, -- 1 Billion: the first real achievement
	[2] = 15,
	[3] = 20,
	[4] = 25,
	[5] = 30,
	[6] = 44,
	[7] = 57,
} :: { [number]: number }

Evolution.PERKS = {
	{ id = "TidalClicks", name = "Tidal Clicks", description = "x3 click power" },
	{ id = "RichReefs", name = "Rich Reefs", description = "x2 passive income" },
	{ id = "FishFrenzy", name = "Fish Frenzy", description = "x1.5 auto-clicker speed" },
	{ id = "DeepCurrents", name = "Deep Currents", description = "x2 offline earnings, +4h offline cap" },
	{ id = "GoldenInvestors", name = "Golden Investors", description = "Investors give +1% more each" },
} :: { PerkDef }

Evolution.PERK_BY_ID = {} :: { [string]: PerkDef }
for _, perk in Evolution.PERKS do
	Evolution.PERK_BY_ID[perk.id] = perk
end

Evolution.PERK_VALUES = {
	tidalClickMultiplier = 3,
	richReefsMultiplier = 2,
	fishFrenzyMultiplier = 1.5,
	deepCurrentsMultiplier = 2,
	deepCurrentsCapSeconds = 4 * 3600,
	goldenInvestorBonus = 0.01,
}

return Evolution
