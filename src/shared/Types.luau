--!strict
-- Shared type definitions (no runtime logic).

local BigNumber = require(script.Parent.BigNumber)
type BigNumber = BigNumber.BigNumber

export type IncomeSource = "Click" | "Passive" | "Auto" | "Offline" | "Investor" | "All"

export type AutoClickerState = {
	tier: number, -- 0 = not owned
	charge: number, -- remaining automated clicks (ignored when the tier is infinite)
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
	investors: number,
	clickLevel: number,
	generators: { [string]: number },
	autoClicker: AutoClickerState,
	evolution: EvolutionState,
	statues: { [string]: boolean },
	lastOnline: number, -- server os.time()
	totalClicks: number,
	receipts: { [string]: number }, -- processed developer-product purchase ids -> os.time()
}

-- Monetization flags resolved live (never trusted from saved data).
export type Entitlements = {
	infiniteAutoClicker: boolean,
}

-- Season or event economy overrides. 1 = neutral.
export type EconomyModifiers = {
	incomeMultiplier: number,
	clickMultiplier: number,
	costMultiplier: number,
	generatorMultipliers: { [string]: number },
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

export type StationKind =
	"Clam"
	| "Generator"
	| "ClickUpgrade"
	| "Investor"
	| "AutoClicker"
	| "Battery"
	| "Evolution"
	| "Statue"

-- ===== Network payloads (server -> client) =====

export type StationView = {
	level: number,
	cost: BigNumber.Serialized?, -- nil when maxed or free
	cost10: BigNumber.Serialized?, -- bulk price for stations that support x10
	locked: boolean,
	lockReason: string?,
	maxed: boolean,
}

export type PerkView = { id: string, name: string, description: string, stacks: number }

export type Snapshot = {
	currency: BigNumber.Serialized,
	rate: BigNumber.Serialized,
	serverTime: number,
	clickValue: BigNumber.Serialized,
	investors: number,
	investorBonus: number, -- e.g. 0.37 = +37%
	stations: { [string]: StationView },
	evolution: {
		level: number,
		multiplier: BigNumber.Serialized,
		nextMultiplier: BigNumber.Serialized?,
		requirement: BigNumber.Serialized?,
		progress: BigNumber.Serialized,
		canEvolve: boolean,
		perks: { PerkView },
	},
	autoClicker: {
		tier: number,
		charge: number,
		capacity: number,
		infinite: boolean,
		clicksPerSecond: number,
	},
	statues: { [string]: boolean },
	stairwayUnlocked: boolean,
	seasonId: string,
}

export type NotifyKind = "Info" | "Success" | "Error" | "Offline" | "Evolution"
export type Notification = {
	kind: NotifyKind,
	text: string,
	amount: BigNumber.Serialized?,
}

export type UiConfig = {
	variant: string,
	tapButtonScale: number,
	accentColor: Color3,
	showPerNanosecond: boolean,
	compactHud: boolean,
	promptPosition: "Bottom" | "Center",
}

return {}
