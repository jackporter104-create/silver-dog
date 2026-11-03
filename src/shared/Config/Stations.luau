--!strict
--[[
	Physical arena layout. It is the single source of truth for every interactive station.
	The server builds the parts from it and validates proximity against it. The client uses it
	for prompts, labels and keeping decor out of walkways. Angles are degrees clockwise from
	north (-Z). x = sin(a) * r, z = -cos(a) * r.

	Zoned, symmetric layout (top view, north up):

	                    Heavenly Stairway (N, statues on top)
	                              ||
	         Gen10 Gen9           ||           Gen1  Gen2
	     Gen8      Fin Forge  ----++----  Auto-Clicker Lab   Gen3
	                       \  Central Plaza  /
	     Gen7      W Clam  —  Center Clam  —  E Clam      Gen4  (Gen4 at 140 deg)
	                       /     Spawn      \
	     Gen6      Investor Lounge   ||   Battery Dock        Gen5
	                                 ||
	                          Evolution Altar (S)

	  * Central Plaza (r <= 48): three Giant Pearl Clams. You spawn just south, facing north.
	  * Inner ring (r = 66): east = automation (Auto-Clicker Lab, Battery Dock), west =
	    growth (Fin Forge, Investor Lounge). Related systems sit side by side.
	  * Promenade (r = 83): a circular stepping-stone walkway between the two rings.
	  * Outer ring (r = 102): the 10 generators in progression order, clockwise from north-east
	    down the east arc, then up the west arc. The run ends next to the stairway.
	  * The north/south axis stays clear: stairway to the north, Evolution Altar to the south.
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
Stations.PLAZA_RADIUS = 48
Stations.INNER_RING_RADIUS = 66
Stations.PROMENADE_RADIUS = 83
Stations.OUTER_RING_RADIUS = 102
Stations.ALTAR_RADIUS = 108
Stations.AXIS_HALF_WIDTH = 7 -- clear lanes along the north/south axis
Stations.SPAWN_POSITION = Vector3.new(0, 0, 24)
Stations.PROXIMITY_TOLERANCE = 6 -- extra studs the server allows for latency
Stations.VERTICAL_TOLERANCE = 14

Stations.STAIRWAY = {
	baseZ = -112,
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

-- Generator angles: east arc 40..140, then west arc 220..320 (25 degree spacing).
local GENERATOR_ANGLES = { 40, 65, 90, 115, 140, 220, 245, 270, 295, 320 }
assert(#GENERATOR_ANGLES >= #Economy.GENERATORS, "Add generator angles for new generators")

local list: { StationDef } = {}

local CLAM_COLOR = Color3.fromRGB(255, 240, 250)
table.insert(list, { id = "Clam1", kind = "Clam", displayName = "Giant Pearl Clam", position = Vector3.zero, radius = 13, color = CLAM_COLOR })
table.insert(list, { id = "Clam2", kind = "Clam", displayName = "Giant Pearl Clam", position = polar(90, 36), radius = 13, color = CLAM_COLOR })
table.insert(list, { id = "Clam3", kind = "Clam", displayName = "Giant Pearl Clam", position = polar(270, 36), radius = 13, color = CLAM_COLOR })

local INNER = Stations.INNER_RING_RADIUS
table.insert(list, { id = "AutoClickerShop", kind = "AutoClicker", displayName = "Auto-Clicker Lab", position = polar(60, INNER), radius = 9, color = Color3.fromRGB(80, 170, 255) })
table.insert(list, { id = "BatteryDock", kind = "Battery", displayName = "Battery Dock", position = polar(120, INNER), radius = 9, color = Color3.fromRGB(255, 240, 90) })
table.insert(list, { id = "InvestorLounge", kind = "Investor", displayName = "Investor Lounge", position = polar(240, INNER), radius = 9, color = Color3.fromRGB(90, 230, 140) })
table.insert(list, { id = "FinForge", kind = "ClickUpgrade", displayName = Economy.CLICK_UPGRADE.name, position = polar(300, INNER), radius = 9, color = Color3.fromRGB(255, 170, 60) })

for i, def in Economy.GENERATORS do
	table.insert(list, {
		id = "Gen_" .. def.id,
		kind = "Generator",
		displayName = def.name,
		position = polar(GENERATOR_ANGLES[i], Stations.OUTER_RING_RADIUS),
		radius = 9,
		target = def.id,
		color = GENERATOR_COLORS[i] or Color3.new(1, 1, 1),
	})
end

table.insert(list, { id = "EvolutionAltar", kind = "Evolution", displayName = "Evolution Altar", position = polar(180, Stations.ALTAR_RADIUS), radius = 14, color = Color3.fromRGB(200, 120, 255) })

-- Statue pedestals on the Heavenly Stairway platform in two staggered rows, spaced so pads never
-- overlap: 4 near the stairs, then 5 behind. The final statue takes the back-row centre.
local STATUE_SLOTS = {
	Vector3.new(-24, 0, 4),
	Vector3.new(-8, 0, 4),
	Vector3.new(8, 0, 4),
	Vector3.new(24, 0, 4),
	Vector3.new(-32, 0, -20),
	Vector3.new(32, 0, -20),
	Vector3.new(-16, 0, -20),
	Vector3.new(16, 0, -20),
	Vector3.new(0, 0, -20),
}
assert(#STATUE_SLOTS >= #Statues.LIST, "Add statue slots for new statues")
for i, statue in Statues.LIST do
	table.insert(list, {
		id = "Statue_" .. statue.id,
		kind = "Statue",
		displayName = statue.name,
		position = Stations.STAIRWAY.platformCenter + STATUE_SLOTS[i],
		radius = 7,
		target = statue.id,
		color = Color3.fromRGB(255, 215, 120),
	})
end

Stations.LIST = list
Stations.BY_ID = {} :: { [string]: StationDef }
for _, station in list do
	assert(Stations.BY_ID[station.id] == nil, "Duplicate station id " .. station.id)
	Stations.BY_ID[station.id] = station
end

-- Horizontal direction from the arena centre to a point (north for the centre itself).
function Stations.outward(position: Vector3): Vector3
	local flat = Vector3.new(position.X, 0, position.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
end

-- True when a floor point keeps walkways, stations, spawn and the stairway clear.
-- `margin` is the decor's own footprint radius.
function Stations.isClearForDecor(point: Vector3, margin: number): boolean
	local flat = Vector3.new(point.X, 0, point.Z)
	local r = flat.Magnitude
	if r > Stations.FLOOR_RADIUS - 3 - margin then
		return false
	end
	if r < Stations.PLAZA_RADIUS + 4 + margin then
		return false
	end
	if math.abs(r - Stations.PROMENADE_RADIUS) < 5 + margin then
		return false
	end
	if math.abs(point.X) < Stations.AXIS_HALF_WIDTH + margin then
		return false
	end
	if math.abs(point.X) < Stations.STAIRWAY.width / 2 + 6 + margin and point.Z < 0 then
		return false
	end
	for _, station in list do
		if station.kind ~= "Statue" then
			local offset = flat - Vector3.new(station.position.X, 0, station.position.Z)
			if offset.Magnitude < station.radius + 5 + margin then
				return false
			end
		end
	end
	return true
end

return Stations
