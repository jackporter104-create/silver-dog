--!strict
-- Example limited-time event: warmer palette, +25% income, Coral Reefs produce x2.

local Types = require(script.Parent.Parent.Parent.Types)

local season: Types.SeasonDefinition = {
	id = "CoralCarnival",
	displayName = "Coral Carnival",
	currencyName = "Pearls",
	priority = 10,
	startsAt = 1796083200, -- 2026-12-01 00:00 UTC
	endsAt = 1799712000, -- 2027-01-12 00:00 UTC
	economy = {
		incomeMultiplier = 1.25,
		clickMultiplier = 1,
		costMultiplier = 1,
		generatorMultipliers = { Reef = 2 },
	},
	theme = {
		waterTint = Color3.fromRGB(255, 200, 230),
		fogColor = Color3.fromRGB(110, 60, 130),
		ambient = Color3.fromRGB(150, 90, 150),
		floorColor = Color3.fromRGB(240, 200, 170),
		fishPalette = {
			Color3.fromRGB(255, 90, 160),
			Color3.fromRGB(255, 200, 80),
			Color3.fromRGB(120, 255, 220),
			Color3.fromRGB(255, 255, 255),
		},
		coralPalette = {
			Color3.fromRGB(255, 80, 140),
			Color3.fromRGB(255, 160, 60),
			Color3.fromRGB(255, 230, 120),
		},
		bubbleColor = Color3.fromRGB(255, 220, 245),
		lightRayColor = Color3.fromRGB(255, 220, 200),
	},
}

return season
