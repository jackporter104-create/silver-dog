--!strict
--[[
	MonetizationConfig: paste your real Roblox asset ids here. 0 = not set up yet: the item is
	hidden in the shop and the server ignores it.

	Gamepasses (permanent, checked with UserOwnsGamePassAsync on join and on purchase):
	  DoubleIncome   x2 on all income from every stand (applied in EconomyMath.globalMultiplier)
	  AutoCollect    unmanaged stands run by themselves while you're online, at hand-run speed

	Developer products (consumable, granted in MonetizationService.ProcessReceipt):
	  TimeWarp       instantly grants TIME_WARP_HOURS of offline-style income
	  StarterPack    one-time boost of currency (a repeat purchase is converted to a Time Warp)

	Everything is granted by the server. The client only opens Roblox purchase prompts from the
	Shell Shop pad in each reef plaza.
]]

export type Gamepass = {
	id: number,
	name: string,
	description: string,
}

export type Product = {
	id: number,
	name: string,
	description: string,
}

local MonetizationConfig = {}

MonetizationConfig.Gamepasses = {
	DoubleIncome = {
		id = 0, -- paste your gamepass id
		name = "x2 Income",
		description = "Double ALL income from every stand, forever!",
	} :: Gamepass,
	AutoCollect = {
		id = 0, -- paste your gamepass id
		name = "Auto-Collect",
		description = "Your stands run by themselves, no need to stand on the pads!",
	} :: Gamepass,
}

MonetizationConfig.Products = {
	TimeWarp = {
		id = 0, -- paste your developer product id
		name = "Time Warp",
		description = "Instantly get 4 hours of income!",
	} :: Product,
	StarterPack = {
		id = 0, -- paste your developer product id
		name = "Starter Pack",
		description = "A huge treasure chest of Pearls! One time only.",
	} :: Product,
}

-- Time Warp: hours of income granted (same formula as offline earnings, see EconomyMath.timeWarpEarnings).
MonetizationConfig.TIME_WARP_HOURS = 4

-- Starter Pack: base Pearls at Evolution 1, scaled by the current Evolution multiplier so it stays
-- worth buying later. 250K is enough for the third business plus upgrades in the first run.
MonetizationConfig.STARTER_PACK_BASE = 250_000
-- ...and never less than this many minutes of the player's current income.
MonetizationConfig.STARTER_PACK_MIN_MINUTES = 30

return MonetizationConfig
