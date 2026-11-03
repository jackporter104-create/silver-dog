--!strict
--[[
	A/B experiments for the HUD. Each player is bucketed deterministically per experiment
	(hash of UserId and key), so assignment is stable across servers and sessions.
	Variant overrides are merged over UI_DEFAULTS in list order. Live overrides from
	ExperimentService are applied last.
]]

local Types = require(script.Parent.Parent.Types)

export type UiOverrides = {
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
	accentColor = Color3.fromRGB(0, 220, 255),
	showPerNanosecond = true,
	compactHud = false,
	promptPosition = "Bottom",
}
Experiments.UI_DEFAULTS = table.freeze(defaults)

Experiments.LIST = {
	{
		key = "prompt_position_v1",
		enabled = true,
		variants = {
			{ id = "bottom", weight = 50, ui = {} },
			{ id = "center", weight = 50, ui = { promptPosition = "Center" } },
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

return Experiments
