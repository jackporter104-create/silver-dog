--!strict
--[[
	Arena layout: the single source of truth for every pad, plot and zone.

	The world is a 3x3 grid of cells (CELL_SIZE apart):
	  * The centre cell is the shared Hub: Evolution Temple (perk pads) and the Heavenly Stairway
	    with the statue platform. Hub pads work for everyone (each player acts on their own data).
	  * The 8 surrounding cells are Player Zones, one per player. Every zone has the same layout,
	    rotated so its local north (-Z) points at the Hub. Zone pads only work for the zone's owner.

	Zone layout (zone-local, -Z = toward the Hub):
	  * Plaza at the centre: the owner's spawn and the 4 global buff pads (shown once unlocked).
	  * 5 stand plots spiral outward clockwise, each a little further away than the last.
	    A plot shows only a "???" Deed pad until the stand is bought, then the structure with its
	    main pad. The Multiplier, Speed and Manager pads appear one by one as the stand grows.
	        [ structure + sign ]       plot centre (Deed pad sits here while locked)
	             [ MAIN ]              run the stand by hand
	    [Multiplier] [Manager] [Speed] upgrade row closest to the plaza

	Zone-scoped StationDef.position is zone-local. Use Stations.worldPosition() for world space.
]]

local Types = require(script.Parent.Parent.Types)
local Economy = require(script.Parent.Economy)
local Evolution = require(script.Parent.Evolution)
local Statues = require(script.Parent.Statues)

export type Scope = "Zone" | "Hub"

export type StationDef = {
	id: string,
	kind: Types.StationKind,
	displayName: string,
	scope: Scope,
	position: Vector3, -- pad centre: zone-local for "Zone", world for "Hub" (Y = walking surface)
	radius: number, -- physical pad radius: standing inside it counts as "on the pad"
	promptRadius: number, -- prompt + [E] range (the server allows PROXIMITY_TOLERANCE more)
	target: string?, -- stand id / buff id / perk id / statue id
	stand: string?, -- owning stand for stand pads
	color: Color3,
}

export type StandPlot = {
	standId: string,
	center: Vector3, -- zone-local structure centre
	forward: Vector3, -- zone-local unit vector toward the plaza
	right: Vector3, -- zone-local unit vector to the right when facing the plaza
	color: Color3,
}

local Stations = {}

-- ===== World grid =====

Stations.CELL_SIZE = 190
Stations.ZONE_COUNT = 8
Stations.ZONE_RADIUS = 80
Stations.ZONE_PLAZA_RADIUS = 18
Stations.HUB_RADIUS = 50
Stations.MAP_HALF = Stations.CELL_SIZE * 1.5 + 20 -- square world: |x|, |z| <= MAP_HALF
Stations.PROXIMITY_TOLERANCE = 6 -- extra studs the server allows for latency
Stations.VERTICAL_TOLERANCE = 14

-- Walking surface heights. Every stacked surface has its own height (no coplanar faces).
Stations.SEA_FLOOR_TOP = 0.01
Stations.ZONE_TOP = 0.3 -- zone and hub ground discs
Stations.PLAZA_TOP = 0.6 -- zone plaza disc

Stations.TEMPLE_CENTER = Vector3.new(0, 0, 14)
Stations.STAIRWAY = {
	baseZ = -16,
	topZ = -56,
	topY = 40,
	width = 22,
	stepCount = 24,
	platformCenter = Vector3.new(0, 40, -76), -- front edge meets the top step at topZ
	platformSize = Vector2.new(88, 40),
}

-- Zone cell offsets: the four axis cells first (closest to the Hub), then the diagonals.
local ZONE_CELLS = {
	Vector2.new(0, 1),
	Vector2.new(1, 0),
	Vector2.new(-1, 0),
	Vector2.new(0, -1),
	Vector2.new(1, 1),
	Vector2.new(-1, 1),
	Vector2.new(1, -1),
	Vector2.new(-1, -1),
}

local zoneCenters: { Vector3 } = {}
local zoneYaws: { number } = {}
for i, cell in ZONE_CELLS do
	local center = Vector3.new(cell.X * Stations.CELL_SIZE, 0, cell.Y * Stations.CELL_SIZE)
	zoneCenters[i] = center
	-- Yaw that turns local -Z toward the Hub: rotating (0,0,-1) by yaw gives (-sin, 0, -cos).
	zoneYaws[i] = math.atan2(center.X, center.Z)
end

function Stations.zoneCenter(zoneIndex: number): Vector3
	return zoneCenters[zoneIndex]
end

function Stations.zoneYaw(zoneIndex: number): number
	return zoneYaws[zoneIndex]
end

-- Same convention as CFrame.Angles(0, yaw, 0) * v.
local function rotate(v: Vector3, yaw: number): Vector3
	local c, s = math.cos(yaw), math.sin(yaw)
	return Vector3.new(v.X * c + v.Z * s, v.Y, -v.X * s + v.Z * c)
end

function Stations.zoneDirection(zoneIndex: number, localDirection: Vector3): Vector3
	return rotate(localDirection, zoneYaws[zoneIndex])
end

function Stations.toWorld(zoneIndex: number, localPosition: Vector3): Vector3
	return zoneCenters[zoneIndex] + rotate(localPosition, zoneYaws[zoneIndex])
end

-- Zone-local polar helper: degrees clockwise from local north (-Z, toward the Hub).
local function polar(angleDeg: number, radius: number, y: number?): Vector3
	local a = math.rad(angleDeg)
	return Vector3.new(math.sin(a) * radius, y or 0, -math.cos(a) * radius)
end
Stations.polar = polar

-- ===== Zone stations =====

-- Plots spiral outward: each stand sits 72 degrees further clockwise and 4 studs further out.
-- Local 0 degrees (toward the Hub) stays free for the path out of the zone.
local PLOT_FIRST_ANGLE = 36
local PLOT_ANGLE_STEP = 72
local PLOT_FIRST_RADIUS = 52
local PLOT_RADIUS_STEP = 4
assert(#Economy.STANDS <= 5, "The zone layout has room for 5 stands")

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
local DEED_RADIUS = 5
local UPGRADE_RADIUS = 3
local PROMPT_MARGIN = 2.5
local MYSTERY_COLOR = Color3.fromRGB(170, 120, 255)

local list: { StationDef } = {}
local plots: { StandPlot } = {}

local function add(def: StationDef)
	table.insert(list, def)
end

for i, stand in Economy.STANDS do
	local center = polar(PLOT_FIRST_ANGLE + (i - 1) * PLOT_ANGLE_STEP, PLOT_FIRST_RADIUS + (i - 1) * PLOT_RADIUS_STEP)
	local forward = -Vector3.new(center.X, 0, center.Z).Unit
	local right = forward:Cross(Vector3.new(0, 1, 0)).Unit
	local color = STAND_COLORS[stand.id] or Color3.new(1, 1, 1)
	table.insert(plots, { standId = stand.id, center = center, forward = forward, right = right, color = color })

	local surface = Vector3.new(0, Stations.ZONE_TOP, 0)
	local row = center + forward * ROW_OFFSET + surface
	local function standPad(suffix: string, kind: Types.StationKind, name: string, position: Vector3, radius: number, padColor: Color3)
		add({ id = stand.id .. "_" .. suffix, kind = kind, displayName = name, scope = "Zone", position = position, radius = radius, promptRadius = radius + PROMPT_MARGIN, target = stand.id, stand = stand.id, color = padColor })
	end
	standPad("Deed", "Deed", "???", center + surface, DEED_RADIUS, MYSTERY_COLOR)
	standPad("Main", "StandMain", stand.name, center + forward * MAIN_OFFSET + surface, MAIN_RADIUS, color)
	standPad("Multiplier", "Multiplier", "Multiplier", row - right * ROW_SPACING, UPGRADE_RADIUS, Color3.fromRGB(255, 200, 60))
	standPad("Manager", "Manager", "Manager", row, UPGRADE_RADIUS, Color3.fromRGB(110, 230, 150))
	standPad("Speed", "Speed", "Speed", row + right * ROW_SPACING, UPGRADE_RADIUS, Color3.fromRGB(90, 190, 255))
end

-- Global buff pads on the plaza diagonals, in unlock order clockwise from local north-east.
local BUFF_ANGLES = { 45, 135, 225, 315 }
assert(#BUFF_ANGLES >= #Economy.BUFFS, "Add buff pad angles for new buffs")
for i, buff in Economy.BUFFS do
	add({
		id = "Buff_" .. buff.id,
		kind = "Buff",
		displayName = buff.name,
		scope = "Zone",
		position = polar(BUFF_ANGLES[i], 12, Stations.PLAZA_TOP),
		radius = 3.5,
		promptRadius = 3.5 + PROMPT_MARGIN,
		target = buff.id,
		color = BUFF_COLORS[buff.id] or Color3.new(1, 1, 1),
	})
end

-- Spawn: plaza centre, facing the first stand.
Stations.SPAWN_LOCAL = Vector3.new(0, Stations.PLAZA_TOP, 0)
Stations.SPAWN_FACING_LOCAL = plots[1].center

-- ===== Hub stations =====

-- Evolution perk pads: an arc on the south side of the temple.
do
	local count = #Evolution.PERKS
	for i, perk in Evolution.PERKS do
		local t = if count > 1 then (i - 1) / (count - 1) else 0.5
		local offset = polar(120 + t * 120, 18, Stations.ZONE_TOP)
		add({
			id = "Evolve_" .. perk.id,
			kind = "Evolve",
			displayName = perk.name,
			scope = "Hub",
			position = Stations.TEMPLE_CENTER + offset,
			radius = 3,
			promptRadius = 3 + PROMPT_MARGIN,
			target = perk.id,
			color = Color3.fromRGB(200, 130, 255),
		})
	end
end

-- Statue pads on the platform in two rows of five. The final statue takes the back-row centre.
local STATUE_SLOTS = {
	Vector3.new(-32, 0, 9),
	Vector3.new(-16, 0, 9),
	Vector3.new(16, 0, 9),
	Vector3.new(32, 0, 9),
	Vector3.new(-32, 0, -9),
	Vector3.new(32, 0, -9),
	Vector3.new(-16, 0, -9),
	Vector3.new(16, 0, -9),
	Vector3.new(0, 0, 9),
	Vector3.new(0, 0, -9),
}
assert(#STATUE_SLOTS >= #Statues.LIST, "Add statue slots for new statues")
for i, statue in Statues.LIST do
	local slot = if i == #Statues.LIST then STATUE_SLOTS[#STATUE_SLOTS] else STATUE_SLOTS[i]
	add({
		id = "Statue_" .. statue.id,
		kind = "Statue",
		displayName = statue.name,
		scope = "Hub",
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
Stations.ZONE_LIST = {} :: { StationDef }
Stations.HUB_LIST = {} :: { StationDef }
for _, station in list do
	assert(Stations.BY_ID[station.id] == nil, "Duplicate station id " .. station.id)
	Stations.BY_ID[station.id] = station
	table.insert(if station.scope == "Zone" then Stations.ZONE_LIST else Stations.HUB_LIST, station)
end
for _, plot in plots do
	Stations.PLOT_BY_STAND[plot.standId] = plot
end

-- World position of a station. Zone stations need the zone index; nil when there is none.
function Stations.worldPosition(station: StationDef, zoneIndex: number?): Vector3?
	if station.scope == "Hub" then
		return station.position
	end
	if not zoneIndex or not zoneCenters[zoneIndex] then
		return nil
	end
	return Stations.toWorld(zoneIndex, station.position)
end

-- Zone index containing a world point (within the zone disc), or nil.
function Stations.zoneAt(point: Vector3): number?
	for i, center in zoneCenters do
		local offset = point - center
		if Vector3.new(offset.X, 0, offset.Z).Magnitude <= Stations.ZONE_RADIUS then
			return i
		end
	end
	return nil
end

-- ===== Decor =====

local function distanceToSegment(p: Vector3, a: Vector3, b: Vector3): number
	local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local ap = Vector3.new(p.X - a.X, 0, p.Z - a.Z)
	local lengthSq = ab.X * ab.X + ab.Z * ab.Z
	local t = if lengthSq > 0 then math.clamp((ap.X * ab.X + ap.Z * ab.Z) / lengthSq, 0, 1) else 0
	return Vector3.new(ap.X - ab.X * t, 0, ap.Z - ab.Z * t).Magnitude
end

local PLOT_BACK = 9
local PLOT_FRONT = ROW_OFFSET + 4
local PLOT_HALF_WIDTH = ROW_SPACING + UPGRADE_RADIUS + 1.5

-- True when decor at a world point keeps every walkway, pad, plot, plaza and the Hub clear.
-- `margin` is the decor's own footprint radius.
function Stations.isClearForDecor(point: Vector3, margin: number): boolean
	local flat = Vector3.new(point.X, 0, point.Z)
	local edge = Stations.MAP_HALF - 4 - margin
	if math.abs(flat.X) > edge or math.abs(flat.Z) > edge then
		return false
	end
	if flat.Magnitude < Stations.HUB_RADIUS + 6 + margin then
		return false
	end
	-- Stairway and statue platform footprint.
	local cfg = Stations.STAIRWAY
	if math.abs(flat.X) < cfg.platformSize.X / 2 + 6 + margin and flat.Z < 0 and flat.Z > cfg.platformCenter.Z - cfg.platformSize.Y / 2 - 6 - margin then
		return false
	end
	for i, center in zoneCenters do
		local yaw = zoneYaws[i]
		-- Path from the zone plaza to the Hub.
		if distanceToSegment(flat, center, Vector3.zero) < 8 + margin then
			return false
		end
		local offset = flat - center
		local distance = offset.Magnitude
		if distance < Stations.ZONE_RADIUS + 3 + margin then
			if distance < Stations.ZONE_PLAZA_RADIUS + 6 + margin or distance > Stations.ZONE_RADIUS - 3 - margin then
				return false
			end
			for _, plot in plots do
				local c = center + rotate(plot.center, yaw)
				local f = rotate(plot.forward, yaw)
				if distanceToSegment(flat, c - f * PLOT_BACK, c + f * PLOT_FRONT) < PLOT_HALF_WIDTH + margin then
					return false
				end
			end
		end
	end
	return true
end

-- Decor bed centres in priority order: the gaps between plots inside every zone first, then the
-- open sea floor between zones on a grid. Progression fills them front to back.
Stations.DECOR_BEDS = {} :: { Vector3 }
for i = 1, Stations.ZONE_COUNT do
	for k = 1, #Economy.STANDS - 1 do
		local angle = PLOT_FIRST_ANGLE + (k - 0.5) * PLOT_ANGLE_STEP
		local candidate = Stations.toWorld(i, polar(angle, PLOT_FIRST_RADIUS + (k - 0.5) * PLOT_RADIUS_STEP))
		if Stations.isClearForDecor(candidate, 3) then
			table.insert(Stations.DECOR_BEDS, candidate)
		end
	end
end
do
	local step = 38
	local limit = Stations.MAP_HALF - 12
	local x = -limit
	while x <= limit do
		local z = -limit
		while z <= limit do
			local candidate = Vector3.new(x, 0, z)
			if Stations.isClearForDecor(candidate, 4) then
				table.insert(Stations.DECOR_BEDS, candidate)
			end
			z += step
		end
		x += step
	end
end

return Stations
