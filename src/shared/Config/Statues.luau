--!strict
--[[
	Statues: permanent end-game multipliers bought on the Heavenly Stairway.
	They are never wiped by Evolution. Costs are powers of ten. The final statue costs
	1 Unquinquagintillion (1e156).
]]

local Types = require(script.Parent.Parent.Types)

export type StatueDef = {
	id: string,
	name: string,
	source: Types.IncomeSource,
	multiplier: number,
	costExponent: number,
}

local Statues = {}

Statues.STAIRWAY = {
	requiredEvolution = 5,
	requiredBestExponent = 30, -- must have held 1 Nonillion at some point
}

-- Order matters for pacing: each statue's boost makes the next one reachable.
Statues.LIST = {
	{ id = "KelpTitan", name = "Kelp Titan", source = "Passive", multiplier = 1e5, costExponent = 32 },
	{ id = "ClamColossus", name = "Clam Colossus", source = "Click", multiplier = 1e5, costExponent = 47 },
	{ id = "GoldenKraken", name = "Golden Kraken", source = "Investor", multiplier = 1e5, costExponent = 48 },
	{ id = "ReefGuardian", name = "Reef Guardian", source = "Auto", multiplier = 1e5, costExponent = 60 },
	{ id = "PearlEmpress", name = "Pearl Empress", source = "All", multiplier = 1e8, costExponent = 61 },
	{ id = "TideKeeper", name = "Tide Keeper", source = "Offline", multiplier = 1e6, costExponent = 75 },
	{ id = "AbyssalLeviathan", name = "Abyssal Leviathan", source = "All", multiplier = 1e15, costExponent = 77 },
	{ id = "TridentOfTides", name = "Trident of Tides", source = "All", multiplier = 1e25, costExponent = 106 },
	{ id = "HeartOfTheOcean", name = "Heart of the Ocean", source = "All", multiplier = 1e30, costExponent = 156 },
} :: { StatueDef }

Statues.BY_ID = {} :: { [string]: StatueDef }
for _, statue in Statues.LIST do
	Statues.BY_ID[statue.id] = statue
end

return Statues
