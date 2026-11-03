--!strict
--[[
	Physical arena layout. It is the single source of truth for every interactive pad.
	The server builds the parts from it and validates proximity against it. The client uses it
	for step-on detection, prompts, labels and keeping decor out of walkways.
	Angles are degrees clockwise from north (-Z). x = sin(a) * r, z = -cos(a) * r.

	Top view, north up:

	                       Heavenly Stairway (statues on top)
	                                   ||
	                    Evolution Temple + 5 perk pads
	     Kraken Den (300)                                Pearl Clam (60)
	                     \        Plaza: spawn +         /
	                      \       4 global buff pads    /
	     Sunken Vault (240)        ( promenade )        Coral Farm (120)
	                                     |
	                            Kelp Factory (180)

	Every stand plot faces the plaza:
	                [ stand model + sign ]   (r = 92)
	                     [ MAIN pad ]        deed while locked, "run" once owned
	          [Multiplier] [Manager] [Speed] upgrade row closest to the plaza
]]

local Types = require(script.Parent.Parent.Types)
local Economy = require(script.Parent.Economy)
local Evolution = require(script.Parent.Evolution)
local Statues = require(script.Parent.Statues)

export type StationDef = {
	id: string,
	kind: Types.StationKind,
	displayName: string,
	position: Vector3, -- centre of the pad at the walking surface
	radius: number, -- physical pad radius: standing inside it counts as "on the pad"
	promptRadius: number, -- prompt + [E] range (the server allows PROXIMITY_TOLERANCE more)
	target: string?, -- stand id / buff id / perk id / statue id
	stand: string?, -- owning stand for stand pads
	color: Color3,
}

export type StandPlot = {
	standId: string,
	center: Vector3, -- stand model centre
	forward: Vector3, -- unit vector toward the plaza
	right: Vector3, -- unit vector to the right when facing the plaza
	color: Color3,
}

local Stations = {}

Stations.FLOOR_RADIUS = 140
Stations.PLAZA_RADIUS = 40
Stations.PROMENADE_RADIUS = 54
Stations.STAND_RING_RADIUS = 92
Stations.SPAWN_POSITION = Vector3.new(0, 0, 8)
Stations.PROXIMITY_TOLERANCE = 6 -- extra studs the server allows for latency
Stations.VERTICAL_TOLERANCE = 14
Stations.TEMPLE_CENTER = Vector3.new(0, 0, -84)
Stations.TEMPLE_CLEAR_RADIUS = 28

Stations.STAIRWAY = {
	baseZ = -112,
	topZ = -176,
	topY = 56,
	width = 26,
	stepCount = 28,
	platformCenter = Vector3.new(0, 56, -212),
	platformSize = Vector2.new(96, 72),
}

-- Walking surface heights (pads sit on top of these).
Stations.SEA_FLOOR_TOP = 0.01
Stations.PLAZA_TOP = 0.4

local function polar(angleDeg: number, radius: number, y: number?): Vector3
	local a = math.rad(angleDeg)
	return Vector3.new(math.sin(a) * radius, y or 0, -math.cos(a) * radius)
end
Stations.polar = polar

local STAND_ANGLES = { 60, 120, 180, 240, 300 }
assert(#STAND_ANGLES >= #Economy.STANDS, "Add stand angles for new stands")

local STAND_COLORS: { [string]: Color3 } = {
	PearlClam = Color3.fromRGB(255, 190, 225),
	CoralFarm = Color3.fromRGB(255, 120, 110),
	KelpFactory = Color3.fromRGB(90, 210, 120),
	SunkenVault = Color3.fromRGB(255, 205, 70),
	KrakenDen = Color3.fromRGB(170, 110, 255),
}

local BUFF_COLORS: { [string]: Color3 } = {
	TidalRush = Color3.fromRGB(90, 200, 255),
	CoralBloom = Color3.fromRGB(255, 130, 170),
	PearlStorm = Color3.fromRGB(240, 240, 255),
	LeviathanRoar = Color3.fromRGB(255, 170, 60),
}

local MAIN_OFFSET = 14 -- forward from the plot centre
local ROW_OFFSET = 25
local ROW_SPACING = 9
local MAIN_RADIUS = 4.5
local UPGRADE_RADIUS = 3
local PROMPT_MARGIN = 2.5

local list: { StationDef } = {}
local plots: { StandPlot } = {}

local function add(def: StationDef)
	table.insert(list, def)
end

for i, stand in Economy.STANDS do
	local center = polar(STAND_ANGLES[i], Stations.STAND_RING_RADIUS)
	local forward = -Vector3.new(center.X, 0, center.Z).Unit
	local right = forward:Cross(Vector3.new(0, 1, 0)).Unit
	local color = STAND_COLORS[stand.id] or Color3.new(1, 1, 1)
	table.insert(plots, { standId = stand.id, center = center, forward = forward, right = right, color = color })

	local row = center + forward * ROW_OFFSET
	local floorY = Vector3.new(0, Stations.SEA_FLOOR_TOP, 0)
	add({ id = stand.id .. "_Main", kind = "StandMain", displayName = stand.name, position = center + forward * MAIN_OFFSET + floorY, radius = MAIN_RADIUS, promptRadius = MAIN_RADIUS + PROMPT_MARGIN, target = stand.id, stand = stand.id, color = color })
	add({ id = stand.id .. "_Multiplier", kind = "Multiplier", displayName = "Multiplier", position = row - right * ROW_SPACING + floorY, radius = UPGRADE_RADIUS, promptRadius = UPGRADE_RADIUS + PROMPT_MARGIN, target = stand.id, stand = stand.id, color = Color3.fromRGB(255, 200, 60) })
	add({ id = stand.id .. "_Manager", kind = "Manager", displayName = "Manager", position = row + floorY, radius = UPGRADE_RADIUS, promptRadius = UPGRADE_RADIUS + PROMPT_MARGIN, target = stand.id, stand = stand.id, color = Color3.fromRGB(110, 230, 150) })
	add({ id = stand.id .. "_Speed", kind = "Speed", displayName = "Speed", position = row + right * ROW_SPACING + floorY, radius = UPGRADE_RADIUS, promptRadius = UPGRADE_RADIUS + PROMPT_MARGIN, target = stand.id, stand = stand.id, color = Color3.fromRGB(90, 190, 255) })
end

-- Global buff pads: fixed spots on the plaza diagonals, in unlock order clockwise from north-east.
local BUFF_ANGLES = { 45, 135, 225, 315 }
assert(#BUFF_ANGLES >= #Economy.BUFFS, "Add buff pad angles for new buffs")
for i, buff in Economy.BUFFS do
	add({
		id = "Buff_" .. buff.id,
		kind = "Buff",
		displayName = buff.name,
		position = polar(BUFF_ANGLES[i], 25, Stations.PLAZA_TOP),
		radius = 3.5,
		promptRadius = 3.5 + PROMPT_MARGIN,
		target = buff.id,
		color = BUFF_COLORS[buff.id] or Color3.new(1, 1, 1),
	})
end

-- Evolution perk pads: an arc on the plaza side of the temple altar.
do
	local count = #Evolution.PERKS
	for i, perk in Evolution.PERKS do
		local t = if count > 1 then (i - 1) / (count - 1) else 0.5
		local angle = math.rad(120 + t * 120) -- 120..240 deg around the altar (south side)
		local offset = Vector3.new(math.sin(angle) * 18, Stations.SEA_FLOOR_TOP, -math.cos(angle) * 18)
		add({
			id = "Evolve_" .. perk.id,
			kind = "Evolve",
			displayName = perk.name,
			position = Stations.TEMPLE_CENTER + offset,
			radius = 3,
			promptRadius = 3 + PROMPT_MARGIN,
			target = perk.id,
			color = Color3.fromRGB(200, 130, 255),
		})
	end
end

-- Statue pads on the Heavenly Stairway platform in two staggered rows, spaced so pads never
-- overlap: 5 near the stairs, 5 behind. The final statue takes the back-row centre.
local STATUE_SLOTS = {
	Vector3.new(-32, 0, 6),
	Vector3.new(-16, 0, 6),
	Vector3.new(16, 0, 6),
	Vector3.new(32, 0, 6),
	Vector3.new(-32, 0, -18),
	Vector3.new(32, 0, -18),
	Vector3.new(-16, 0, -18),
	Vector3.new(16, 0, -18),
	Vector3.new(0, 0, 6),
	Vector3.new(0, 0, -18),
}
assert(#STATUE_SLOTS >= #Statues.LIST, "Add statue slots for new statues")
for i, statue in Statues.LIST do
	-- The last statue always takes the back-row centre slot.
	local slot = if i == #Statues.LIST then STATUE_SLOTS[#STATUE_SLOTS] else STATUE_SLOTS[i]
	add({
		id = "Statue_" .. statue.id,
		kind = "Statue",
		displayName = statue.name,
		position = Stations.STAIRWAY.platformCenter + slot,
		radius = 4,
		promptRadius = 4 + PROMPT_MARGIN,
		target = statue.id,
		color = Color3.fromRGB(255, 215, 120),
	})
end

Stations.LIST = list
Stations.PLOTS = plots
Stations.BY_ID = {} :: { [string]: StationDef }
Stations.PLOT_BY_STAND = {} :: { [string]: StandPlot }
for _, station in list do
	assert(Stations.BY_ID[station.id] == nil, "Duplicate station id " .. station.id)
	Stations.BY_ID[station.id] = station
end
for _, plot in plots do
	Stations.PLOT_BY_STAND[plot.standId] = plot
end

Stations.PLOT_CLEAR_RADIUS = 16 -- stand model footprint around the plot centre

-- Decor bed centres in priority order: between stand plots first, then the outer rim.
Stations.DECOR_BEDS = {} :: { Vector3 }
for _, angle in { 90, 150, 210, 270, 30, 330 } do
	table.insert(Stations.DECOR_BEDS, polar(angle, Stations.STAND_RING_RADIUS))
end
for _, angle in { 90, 150, 210, 270 } do
	table.insert(Stations.DECOR_BEDS, polar(angle, 66))
end
for angle = 10, 350, 20 do
	table.insert(Stations.DECOR_BEDS, polar(angle, 124))
end

-- Horizontal direction from the arena centre to a point (north for the centre itself).
function Stations.outward(position: Vector3): Vector3
	local flat = Vector3.new(position.X, 0, position.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
end

-- True when a floor point keeps walkways, pads, stand plots, the temple and the stairway clear.
-- `margin` is the decor's own footprint radius.
function Stations.isClearForDecor(point: Vector3, margin: number): boolean
	local flat = Vector3.new(point.X, 0, point.Z)
	local r = flat.Magnitude
	if r > Stations.FLOOR_RADIUS - 3 - margin or r < Stations.PLAZA_RADIUS + 4 + margin then
		return false
	end
	if math.abs(r - Stations.PROMENADE_RADIUS) < 5 + margin then
		return false
	end
	if math.abs(point.X) < Stations.STAIRWAY.width / 2 + 6 + margin and point.Z < Stations.TEMPLE_CENTER.Z then
		return false
	end
	if (flat - Stations.TEMPLE_CENTER).Magnitude < Stations.TEMPLE_CLEAR_RADIUS + margin then
		return false
	end
	for _, plot in plots do
		if (flat - Vector3.new(plot.center.X, 0, plot.center.Z)).Magnitude < Stations.PLOT_CLEAR_RADIUS + margin then
			return false
		end
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
