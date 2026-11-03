--!strict
-- Shared type definitions (no runtime logic).

local BigNumber = require(script.Parent.BigNumber)
type BigNumber = BigNumber.BigNumber

-- Per-stand progress. level: 0 = not owned, 1 = owned. multiplier/speed are upgrade levels.
-- revealed: how many upgrade pads are shown (0 none, 1 Multiplier, 2 + Speed, 3 + Manager).
export type StandState = {
	level: number,
	multiplier: number,
	speed: number,
	managerHired: boolean,
	revealed: number,
}

-- Per-buff state. Times are server os.time() seconds (0 = never).
export type BuffState = {
	unlocked: boolean,
	activeUntil: number,
	readyAt: number,
}

export type EvolutionState = {
	level: number, -- 1..MAX_LEVEL
	perks: { [string]: number }, -- perkId -> stacks chosen across evolutions
}

-- Authoritative per-player state, owned by the server only.
export type PlayerData = {
	version: number,
	currency: BigNumber,
	lifetimeEarned: BigNumber, -- earned during the current evolution run (gates evolving)
	totalEarned: BigNumber, -- all-time
	bestCurrency: BigNumber, -- highest balance ever held (gates the Heavenly Stairway)
	stands: { [string]: StandState },
	buffs: { [string]: BuffState },
	evolution: EvolutionState,
	statues: { [string]: boolean },
	lastOnline: number, -- server os.time()
	totalRuns: number, -- manual stand cycles
	receipts: { [string]: number }, -- processed developer-product purchase ids -> os.time()
}

-- Monetization flags resolved live (never trusted from saved data).
export type Entitlements = {
	doubleIncome: boolean,
}

-- Season or event economy overrides. 1 = neutral.
export type EconomyModifiers = {
	incomeMultiplier: number,
	costMultiplier: number,
	standMultipliers: { [string]: number },
}

export type SeasonTheme = {
	waterTint: Color3,
	fogColor: Color3,
	ambient: Color3,
	floorColor: Color3,
	fishPalette: { Color3 },
	coralPalette: { Color3 },
	bubbleColor: Color3,
	lightRayColor: Color3,
}

export type SeasonDefinition = {
	id: string,
	displayName: string,
	currencyName: string,
	priority: number, -- highest active season wins
	startsAt: number?, -- UTC unix seconds; nil = always
	endsAt: number?,
	economy: EconomyModifiers,
	theme: SeasonTheme,
}

export type StationKind = "Deed" | "StandMain" | "Multiplier" | "Speed" | "Manager" | "Buff" | "Evolve" | "Statue"

-- ===== Network payloads (server -> client) =====

export type StationView = {
	visible: boolean, -- the pad exists in the player's zone (progressive reveal)
	level: number,
	cost: BigNumber.Serialized?, -- nil when maxed or free
	locked: boolean,
	lockReason: string?,
	maxed: boolean,
}

export type StandView = {
	owned: boolean,
	managed: boolean,
	multiplier: number,
	speed: number,
	interval: number, -- seconds per cycle
	cycleValue: BigNumber.Serialized, -- per automated cycle, buff included
	manualValue: BigNumber.Serialized, -- per hand-run cycle, buff included
	rate: BigNumber.Serialized, -- per second while cycling
	cycleEndsAt: number?, -- server time of the running manual cycle
}

export type BuffView = {
	unlocked: boolean,
	activeRemaining: number, -- seconds, relative to Snapshot.serverTime
	cooldownRemaining: number,
}

export type PerkView = { id: string, name: string, description: string, stacks: number }

export type Snapshot = {
	currency: BigNumber.Serialized,
	rate: BigNumber.Serialized, -- managed income per second
	serverTime: number,
	globalMultiplier: number, -- strongest active buff (1 = none)
	stations: { [string]: StationView },
	stands: { [string]: StandView },
	buffs: { [string]: BuffView },
	evolution: {
		level: number,
		multiplier: BigNumber.Serialized,
		nextMultiplier: BigNumber.Serialized?,
		requirement: BigNumber.Serialized?,
		progress: BigNumber.Serialized,
		canEvolve: boolean,
		perks: { PerkView },
	},
	statues: { [string]: boolean },
	stairwayUnlocked: boolean,
	seasonId: string,
}

-- Sent when a hand-run cycle starts, so the client can animate it.
export type CycleEvent = {
	standId: string,
	endsAt: number, -- server time
	value: BigNumber.Serialized,
}

export type NotifyKind = "Info" | "Success" | "Error" | "Offline" | "Evolution"
export type Notification = {
	kind: NotifyKind,
	text: string,
	amount: BigNumber.Serialized?,
}

export type UiConfig = {
	variant: string,
	accentColor: Color3,
	showPerNanosecond: boolean,
	compactHud: boolean,
	promptPosition: "Bottom" | "Center",
}

return {}
