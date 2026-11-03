--!strict
--[[
	Statues: permanent end-game multipliers bought on the Heavenly Stairway.
	They are never wiped by Evolution. `source` is a stand id (boosts that stand only),
	"Offline" (offline earnings) or "All" (every stand). Costs are powers of ten, calibrated with
	tools/sim.luau. The final statue's x1e30 pushes income into the Unquinquagintillions (1e156+).
]]

export type StatueDef = {
	id: string,
	name: string,
	source: string,
	multiplier: number,
	costExponent: number,
}

local Statues = {}

Statues.STAIRWAY = {
	requiredEvolution = 5,
	requiredBestExponent = 25, -- must have held 10 Septillion at some point
}

-- Order matters for pacing: each statue's boost makes the next one reachable.
Statues.LIST = {
	{ id = "ClamColossus", name = "Clam Colossus", source = "PearlClam", multiplier = 1e5, costExponent = 26 },
	{ id = "CoralQueen", name = "Coral Queen", source = "CoralFarm", multiplier = 1e5, costExponent = 30 },
	{ id = "KelpTitan", name = "Kelp Titan", source = "KelpFactory", multiplier = 1e5, costExponent = 34 },
	{ id = "VaultGuardian", name = "Vault Guardian", source = "SunkenVault", multiplier = 1e5, costExponent = 37 },
	{ id = "GoldenKraken", name = "Golden Kraken", source = "KrakenDen", multiplier = 1e5, costExponent = 39 },
	{ id = "TideKeeper", name = "Tide Keeper", source = "Offline", multiplier = 1e6, costExponent = 42 },
	{ id = "PearlEmpress", name = "Pearl Empress", source = "All", multiplier = 1e6, costExponent = 45 },
	{ id = "TridentOfTides", name = "Trident of Tides", source = "All", multiplier = 1e12, costExponent = 57 },
	{ id = "AbyssalLeviathan", name = "Abyssal Leviathan", source = "All", multiplier = 1e20, costExponent = 80 },
	{ id = "HeartOfTheOcean", name = "Heart of the Ocean", source = "All", multiplier = 1e30, costExponent = 118 },
} :: { StatueDef }

Statues.BY_ID = {} :: { [string]: StatueDef }
for _, statue in Statues.LIST do
	Statues.BY_ID[statue.id] = statue
end

return Statues
