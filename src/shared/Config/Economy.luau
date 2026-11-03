--!strict
--[[
	Core economy tuning ("Business Empire" model). Pure data, so tools/sim.luau can load it.

	Each stand is an income source that produces `baseValue` per cycle of `baseInterval` seconds.
	  * Multiplier pad: level m multiplies value per cycle by 2^m (x2, x4, x8 ...).
	  * Speed pad: level s divides the interval by 2^s (x2, x4, x8 ...), capped at MAX_SPEED_LEVEL.
	  * Manager pad: once hired, the stand cycles forever on its own (and earns offline).
	    Without a manager the player stands on the stand's main pad to run cycles by hand.
	  * Deed: the main pad of a stand the player does not own yet. Paying the deed unlocks it.
	Pacing targets (validated with tools/sim.luau): first 1K in a few minutes, 1M around 20 min,
	1B (first Evolution) as the first big achievement after about 1-2 hours.
]]

export type StandDef = {
	id: string,
	name: string,
	description: string,
	managerName: string,
	npc: "Crab" | "Mermaid",
	deedCost: number, -- 0 = owned from the start
	baseValue: number, -- currency per cycle at multiplier level 0
	baseInterval: number, -- seconds per cycle at speed level 0
	multiplierCost: number,
	multiplierGrowth: number,
	speedCost: number,
	speedGrowth: number,
	managerCost: number,
}

export type BuffDef = {
	id: string,
	name: string,
	multiplier: number, -- applied to ALL stands while active
	duration: number, -- seconds
	cooldown: number, -- seconds after activation before it can be used again
	requiredStands: number, -- unlocks permanently (until Evolution) at this many owned stands
}

local Economy = {}

Economy.DATA_VERSION = 2

Economy.STANDS = {
	{
		id = "PearlClam",
		name = "Pearl Clam",
		description = "A giant clam that grows shiny pearls.",
		managerName = "Captain Crab",
		npc = "Crab",
		deedCost = 0,
		baseValue = 1,
		baseInterval = 1,
		multiplierCost = 25,
		multiplierGrowth = 4.5,
		speedCost = 100,
		speedGrowth = 6,
		managerCost = 300,
	},
	{
		id = "CoralFarm",
		name = "Coral Farm",
		description = "Bright coral that sprouts pearls.",
		managerName = "Coral the Mermaid",
		npc = "Mermaid",
		deedCost = 2_500,
		baseValue = 30,
		baseInterval = 3,
		multiplierCost = 5_000,
		multiplierGrowth = 4.5,
		speedCost = 20_000,
		speedGrowth = 6,
		managerCost = 30_000,
	},
	{
		id = "KelpFactory",
		name = "Kelp Factory",
		description = "Busy machines press kelp into pearls.",
		managerName = "Foreman Crab",
		npc = "Crab",
		deedCost = 150_000,
		baseValue = 1_500,
		baseInterval = 6,
		multiplierCost = 300_000,
		multiplierGrowth = 4.5,
		speedCost = 1_200_000,
		speedGrowth = 6,
		managerCost = 1_500_000,
	},
	{
		id = "SunkenVault",
		name = "Sunken Vault",
		description = "An ancient vault overflowing with treasure.",
		managerName = "Marina the Mermaid",
		npc = "Mermaid",
		deedCost = 2_000_000,
		baseValue = 60_000,
		baseInterval = 12,
		multiplierCost = 6_000_000,
		multiplierGrowth = 4.5,
		speedCost = 25_000_000,
		speedGrowth = 6,
		managerCost = 15_000_000,
	},
	{
		id = "KrakenDen",
		name = "Kraken Den",
		description = "A friendly kraken juggles giant pearls.",
		managerName = "King Crab",
		npc = "Crab",
		deedCost = 60_000_000,
		baseValue = 1_500_000,
		baseInterval = 24,
		multiplierCost = 150_000_000,
		multiplierGrowth = 4.5,
		speedCost = 600_000_000,
		speedGrowth = 6,
		managerCost = 400_000_000,
	},
} :: { StandDef }

Economy.STAND_BY_ID = {} :: { [string]: StandDef }
for _, def in Economy.STANDS do
	Economy.STAND_BY_ID[def.id] = def
end
Economy.STARTING_STAND = "PearlClam"

Economy.MAX_SPEED_LEVEL = 8 -- x256 speed
Economy.MAX_MULTIPLIER_LEVEL = 1000

-- Global buffs: fixed pads in the plaza. Only the strongest active buff applies (they never
-- stack), which keeps the boost noticeable without breaking the economy.
Economy.BUFFS = {
	{ id = "TidalRush", name = "Tidal Rush", multiplier = 2, duration = 30, cooldown = 90, requiredStands = 2 },
	{ id = "CoralBloom", name = "Coral Bloom", multiplier = 3, duration = 30, cooldown = 150, requiredStands = 3 },
	{ id = "PearlStorm", name = "Pearl Storm", multiplier = 4, duration = 30, cooldown = 240, requiredStands = 4 },
	{ id = "LeviathanRoar", name = "Leviathan's Roar", multiplier = 6, duration = 45, cooldown = 420, requiredStands = 5 },
} :: { BuffDef }

Economy.BUFF_BY_ID = {} :: { [string]: BuffDef }
for _, def in Economy.BUFFS do
	Economy.BUFF_BY_ID[def.id] = def
end

-- Manual runs: the shortest cycle a player can run by hand (prevents sub-tick spam payouts).
Economy.MIN_MANUAL_INTERVAL = 0.25

Economy.OFFLINE = {
	baseCapSeconds = 8 * 3600,
	maxCapSeconds = 48 * 3600, -- hard ceiling regardless of perks
	efficiency = 1.0, -- 100% of managed generation
	minSeconds = 60, -- ignore tiny gaps (rejoins)
}

-- Time Warp developer product: instantly grants this many seconds of managed income.
Economy.TIME_WARP_SECONDS = 3600

-- Hard sanity limits used by save validation.
Economy.LIMITS = {
	maxReceipts = 50,
}

return Economy
