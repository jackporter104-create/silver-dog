--!strict
--[[
	A/B experiments for the HUD. Each player is bucketed deterministically per experiment
	(hash of UserId and key), so assignment is stable across servers and sessions.
	Variant overrides are merged over UI_DEFAULTS in list order. Live overrides from
	ExperimentService are applied last.
]]

local Types = require(script.Parent.Parent.Types)

export type UiOverrides = {
	tapButtonScale: number?,
	accentColor: Color3?,
	showPerNanosecond: boolean?,
	compactHud: boolean?,
	promptPosition: ("Bottom" | "Center")?,
}

export type Variant = { id: string, weight: number, ui: UiOverrides }
export type Experiment = { key: string, enabled: boolean, variants: { Variant } }

local Experiments = {}

local defaults: Types.UiConfig = {
	variant = "default",
	tapButtonScale = 1,
	accentColor = Color3.fromRGB(0, 220, 255),
	showPerNanosecond = true,
	compactHud = false,
	promptPosition = "Bottom",
}
Experiments.UI_DEFAULTS = table.freeze(defaults)

Experiments.LIST = {
	{
		key = "tap_button_size_v1",
		enabled = true,
		variants = {
			{ id = "control", weight = 50, ui = {} },
			{ id = "large", weight = 50, ui = { tapButtonScale = 1.3 } },
		},
	},
	{
		key = "accent_color_v1",
		enabled = true,
		variants = {
			{ id = "aqua", weight = 50, ui = {} },
			{ id = "coral", weight = 50, ui = { accentColor = Color3.fromRGB(255, 120, 150) } },
		},
	},
} :: { Experiment }

-- Bounds the server enforces on any override, including live ones.
Experiments.LIMITS = {
	minTapScale = 0.75,
	maxTapScale = 1.6,
}

return Experiments
