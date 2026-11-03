--!strict
-- Shared visual language for the oceanic HUD: palette, fonts and small instance helpers.

local Theme = {}

Theme.FONT = Enum.Font.FredokaOne
Theme.FONT_BODY = Enum.Font.GothamBold

Theme.Colors = {
	deep = Color3.fromRGB(6, 30, 58),
	panel = Color3.fromRGB(10, 52, 92),
	panelLight = Color3.fromRGB(22, 96, 150),
	foam = Color3.fromRGB(235, 250, 255),
	pearl = Color3.fromRGB(255, 246, 252),
	gold = Color3.fromRGB(255, 214, 92),
	success = Color3.fromRGB(90, 230, 140),
	danger = Color3.fromRGB(255, 96, 110),
	muted = Color3.fromRGB(150, 190, 215),
	locked = Color3.fromRGB(90, 110, 130),
}

-- Generic constructor. The caller annotates the concrete type: local l: TextLabel = Theme.make(...)
function Theme.make(className: string, props: { [string]: any }, children: { any }?): any
	local instance = Instance.new(className :: any)
	for key, value in props do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	if children then
		for _, child in children do
			(child :: Instance).Parent = instance
		end
	end
	if props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end

function Theme.corner(radius: number): Instance
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	return c
end

function Theme.stroke(color: Color3, thickness: number, transparency: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	return s
end

function Theme.gradient(top: Color3, bottom: Color3, rotation: number?): Instance
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = rotation or 90
	return g
end

function Theme.padding(px: number): Instance
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, px)
	p.PaddingBottom = UDim.new(0, px)
	p.PaddingLeft = UDim.new(0, px)
	p.PaddingRight = UDim.new(0, px)
	return p
end

function Theme.label(props: { [string]: any }): TextLabel
	local defaults: { [string]: any } = {
		BackgroundTransparency = 1,
		Font = Theme.FONT,
		TextColor3 = Theme.Colors.foam,
		TextScaled = true,
		TextStrokeTransparency = 0.6,
	}
	for key, value in props do
		defaults[key] = value
	end
	local label: TextLabel = Theme.make("TextLabel", defaults)
	return label
end

function Theme.button(props: { [string]: any }, color: Color3): TextButton
	local defaults: { [string]: any } = {
		AutoButtonColor = true,
		BackgroundColor3 = color,
		Font = Theme.FONT,
		TextColor3 = Color3.new(1, 1, 1),
		TextScaled = true,
		TextStrokeTransparency = 0.5,
	}
	for key, value in props do
		defaults[key] = value
	end
	local button: TextButton = Theme.make("TextButton", defaults, {
		Theme.corner(14),
		Theme.gradient(Color3.new(1, 1, 1), Color3.fromRGB(190, 190, 190)),
		Theme.stroke(Color3.new(1, 1, 1), 2, 0.5),
		Theme.padding(6),
	})
	return button
end

return Theme
