--!strict
--[[
	Physical arena layout. It is the single source of truth for every interactive station.
	The server builds the parts from it and validates proximity against it. The client uses it
	for prompts and labels. Angles are degrees clockwise from north (-Z).
]]

local Types = require(script.Parent.Parent.Types)
local Economy = require(script.Parent.Economy)
local Statues = require(script.Parent.Statues)

export type StationDef = {
	id: string,
	kind: Types.StationKind,
	displayName: string,
	position: Vector3, -- centre of the pad at floor level
	radius: number, -- interaction radius (studs, horizontal)
	target: string?, -- generator id / statue id
	color: Color3,
}

local Stations = {}

Stations.FLOOR_RADIUS = 140
Stations.SPAWN_POSITION = Vector3.new(0, 0, 12)
Stations.PROXIMITY_TOLERANCE = 6 -- extra studs the server allows for latency
Stations.VERTICAL_TOLERANCE = 14

Stations.STAIRWAY = {
	baseZ = -104,
	topZ = -176,
	topY = 56,
	width = 26,
	stepCount = 28,
	platformCenter = Vector3.new(0, 56, -212),
	platformSize = Vector2.new(96, 72),
}

local function polar(angleDeg: number, radius: number, y: number?): Vector3
	local a = math.rad(angleDeg)
	return Vector3.new(math.sin(a) * radius, y or 0, -math.cos(a) * radius)
end
Stations.polar = polar

local GENERATOR_COLORS = {
	Color3.fromRGB(255, 140, 120),
	Color3.fromRGB(80, 200, 120),
	Color3.fromRGB(240, 230, 200),
	Color3.fromRGB(255, 110, 170),
	Color3.fromRGB(170, 120, 80),
	Color3.fromRGB(255, 200, 60),
	Color3.fromRGB(160, 90, 220),
	Color3.fromRGB(60, 220, 230),
	Color3.fromRGB(255, 90, 60),
	Color3.fromRGB(120, 140, 255),
}

local list: { StationDef } = {}

for i, angle in { 0, 120, 240 } do
	table.insert(list, {
		id = "Clam" .. i,
		kind = "Clam",
		displayName = "Giant Pearl Clam",
		position = polar(angle + 60, 26),
		radius = 13,
		color = Color3.fromRGB(255, 240, 250),
	})
end

-- Generators ring the arena from 30 to 300 degrees, leaving the north open for the stairway.
for i, def in Economy.GENERATORS do
	table.insert(list, {
		id = "Gen_" .. def.id,
		kind = "Generator",
		displayName = def.name,
		position = polar(30 + (i - 1) * 30, 78),
		radius = 9,
		target = def.id,
		color = GENERATOR_COLORS[i] or Color3.new(1, 1, 1),
	})
end

table.insert(list, { id = "FinForge", kind = "ClickUpgrade", displayName = Economy.CLICK_UPGRADE.name, position = polar(180, 46), radius = 9, color = Color3.fromRGB(255, 170, 60) })
table.insert(list, { id = "InvestorLounge", kind = "Investor", displayName = "Investor Lounge", position = polar(120, 46), radius = 9, color = Color3.fromRGB(90, 230, 140) })
table.insert(list, { id = "AutoClickerShop", kind = "AutoClicker", displayName = "Auto-Clicker Lab", position = polar(240, 46), radius = 9, color = Color3.fromRGB(80, 170, 255) })
table.insert(list, { id = "BatteryDock", kind = "Battery", displayName = "Battery Dock", position = polar(60, 46), radius = 9, color = Color3.fromRGB(255, 240, 90) })
table.insert(list, { id = "EvolutionAltar", kind = "Evolution", displayName = "Evolution Altar", position = polar(180, 112), radius = 14, color = Color3.fromRGB(200, 120, 255) })

-- Statue pedestals in an arc on the Heavenly Stairway platform.
do
	local center = Stations.STAIRWAY.platformCenter
	local count = #Statues.LIST
	for i, statue in Statues.LIST do
		local t = if count > 1 then (i - 1) / (count - 1) else 0.5
		local angle = math.rad(-70 + t * 140)
		table.insert(list, {
			id = "Statue_" .. statue.id,
			kind = "Statue",
			displayName = statue.name,
			position = center + Vector3.new(math.sin(angle) * 34, 0, -math.cos(angle) * 22 + 6),
			radius = 8,
			target = statue.id,
			color = Color3.fromRGB(255, 215, 120),
		})
	end
end

Stations.LIST = list
Stations.BY_ID = {} :: { [string]: StationDef }
for _, station in list do
	assert(Stations.BY_ID[station.id] == nil, "Duplicate station id " .. station.id)
	Stations.BY_ID[station.id] = station
end

return Stations
