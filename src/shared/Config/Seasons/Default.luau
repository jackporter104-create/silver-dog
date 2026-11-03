--!strict
-- Baseline ocean season: neutral economy, cool blue palette.

local Types = require(script.Parent.Parent.Parent.Types)

local season: Types.SeasonDefinition = {
	id = "Default",
	displayName = "Deep Blue",
	currencyName = "Pearls",
	priority = 0,
	startsAt = nil,
	endsAt = nil,
	economy = {
		incomeMultiplier = 1,
		clickMultiplier = 1,
		costMultiplier = 1,
		generatorMultipliers = {},
	},
	theme = {
		waterTint = Color3.fromRGB(150, 210, 255),
		fogColor = Color3.fromRGB(20, 80, 130),
		ambient = Color3.fromRGB(60, 110, 160),
		floorColor = Color3.fromRGB(214, 196, 150),
		fishPalette = {
			Color3.fromRGB(255, 150, 60),
			Color3.fromRGB(80, 180, 255),
			Color3.fromRGB(255, 230, 90),
			Color3.fromRGB(120, 230, 170),
			Color3.fromRGB(255, 120, 160),
		},
		coralPalette = {
			Color3.fromRGB(255, 110, 130),
			Color3.fromRGB(255, 170, 90),
			Color3.fromRGB(190, 120, 255),
			Color3.fromRGB(90, 220, 200),
		},
		bubbleColor = Color3.fromRGB(210, 240, 255),
		lightRayColor = Color3.fromRGB(190, 235, 255),
	},
}

return season
