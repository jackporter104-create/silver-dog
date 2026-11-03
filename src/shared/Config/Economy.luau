--!strict
--[[
	Core economy tuning. Pure data. Shared by server (authority) and tools/sim.luau.

	Pacing targets (validated with `luau tools/sim.luau` via tools/run_luau.py):
	  * First 1K in about 2-3 minutes, first 1M in about 20 minutes. Numbers start at 0.
	  * 1B (first Evolution) is the first big achievement, about 1.5-2 hours of play.
	  * Generators are gated behind Investor counts. Those are the upgrade walls.
]]

export type GeneratorDef = {
	id: string,
	name: string,
	description: string,
	baseCost: number,
	growth: number,
	baseOutput: number, -- currency/s per level before multipliers
	requiredInvestors: number,
}

export type AutoClickerTier = {
	cost: number,
	costExponent: number?, -- when set, cost = 10^costExponent (late-game tiers)
	clicksPerSecond: number,
	capacity: number, -- automated clicks per full battery
	infinite: boolean,
	requiredEvolution: number,
}

local Economy = {}

Economy.DATA_VERSION = 1
Economy.BASE_CLICK = 1

Economy.CLICK_UPGRADE = {
	name = "Fin Forge",
	baseCost = 10,
	growth = 1.17,
	milestones = { { every = 25, multiplier = 3 }, { every = 100, multiplier = 10 } } :: { Milestone },
}

-- Owning N levels of a generator multiplies its output at every milestone. Milestones compound,
-- so late-game income outruns the 1.15x cost growth slowly and numbers get absurd.
export type Milestone = { every: number, multiplier: number }
Economy.GENERATOR_MILESTONES = {
	{ every = 25, multiplier = 3 },
	{ every = 100, multiplier = 10 },
} :: { Milestone }

Economy.INVESTOR = {
	baseCost = 1000,
	growth = 1.14,
	bonusPerInvestor = 0.01, -- flat +1% passive income each
}

Economy.GENERATORS = {
	{ id = "Shrimp", name = "Shrimp Buddy", description = "A tiny helper that finds pearls.", baseCost = 15, growth = 1.15, baseOutput = 0.5, requiredInvestors = 0 },
	{ id = "Kelp", name = "Kelp Farm", description = "Swaying kelp traps drifting pearls.", baseCost = 150, growth = 1.15, baseOutput = 4, requiredInvestors = 0 },
	{ id = "ClamBed", name = "Pearl Clam Bed", description = "Clams that grow pearls all day.", baseCost = 1_600, growth = 1.15, baseOutput = 30, requiredInvestors = 0 },
	{ id = "Reef", name = "Coral Reef", description = "A bustling reef full of workers.", baseCost = 20_000, growth = 1.15, baseOutput = 220, requiredInvestors = 1 },
	{ id = "Ship", name = "Sunken Ship", description = "Salvage crews dig up treasure.", baseCost = 300_000, growth = 1.15, baseOutput = 1_700, requiredInvestors = 3 },
	{ id = "Vault", name = "Treasure Vault", description = "Ancient vaults overflowing with pearls.", baseCost = 5e6, growth = 1.15, baseOutput = 13_000, requiredInvestors = 8 },
	{ id = "Kraken", name = "Kraken Den", description = "A friendly kraken juggles pearls.", baseCost = 8e7, growth = 1.15, baseOutput = 100_000, requiredInvestors = 15 },
	{ id = "Atlantis", name = "Atlantis Engine", description = "Lost technology prints pearls.", baseCost = 1.4e9, growth = 1.15, baseOutput = 800_000, requiredInvestors = 30 },
	{ id = "Abyss", name = "Abyssal Reactor", description = "Deep-sea vents forge pearls.", baseCost = 2.5e10, growth = 1.15, baseOutput = 6.5e6, requiredInvestors = 55 },
	{ id = "Leviathan", name = "Leviathan Forge", description = "Legendary beasts power the forge.", baseCost = 5e11, growth = 1.15, baseOutput = 5.5e7, requiredInvestors = 90 },
} :: { GeneratorDef }

Economy.GENERATOR_BY_ID = {} :: { [string]: GeneratorDef }
for _, def in Economy.GENERATORS do
	Economy.GENERATOR_BY_ID[def.id] = def
end

-- Auto-clicker: a battery of automated clicks. You recharge it at the Battery Dock in the arena.
-- The final tier never drains. It is gated behind Evolution 3 and costs 1 Quadrillion.
Economy.AUTO_CLICKER_TIERS = {
	{ cost = 2_500, clicksPerSecond = 2, capacity = 600, infinite = false, requiredEvolution = 1 },
	{ cost = 150_000, clicksPerSecond = 4, capacity = 2_400, infinite = false, requiredEvolution = 1 },
	{ cost = 2e7, clicksPerSecond = 6, capacity = 7_200, infinite = false, requiredEvolution = 1 },
	{ cost = 5e9, clicksPerSecond = 10, capacity = 36_000, infinite = false, requiredEvolution = 2 },
	{ cost = 2e12, clicksPerSecond = 15, capacity = 216_000, infinite = false, requiredEvolution = 2 },
	{ cost = 0, costExponent = 15, clicksPerSecond = 20, capacity = 0, infinite = true, requiredEvolution = 3 },
} :: { AutoClickerTier }

-- Clicks/s granted by the Infinite Auto-Clicker gamepass when the player's tier is lower.
Economy.GAMEPASS_AUTO_CPS = 4

Economy.OFFLINE = {
	baseCapSeconds = 8 * 3600,
	maxCapSeconds = 48 * 3600, -- hard ceiling regardless of perks
	efficiency = 1.0, -- 100% of online generation
	minSeconds = 60, -- ignore tiny gaps (rejoins)
}

-- Hard sanity limits used by save validation and purchase loops.
Economy.LIMITS = {
	maxLevel = 10_000,
	maxInvestors = 100_000,
	maxCharge = 10_000_000,
	maxReceipts = 50,
}

Economy.BUY_QUANTITIES = { 1, 10 }

return Economy
