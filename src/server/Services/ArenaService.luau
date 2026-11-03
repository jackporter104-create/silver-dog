--!strict
--[[
	ArenaService: builds the physical arena on the server from Config/Stations.

	Rendering rules (these prevent z-fighting and flicker):
	  * No two visible faces are ever coplanar. Stacked parts use distinct heights
	    (sea floor 0, plaza 0.4, stepping stones 0.3, neon lip 0.6, pad 1.0, inlay 1.2).
	  * Parts that touch share an edge, not a volume (stair steps do not overlap).
	  * No large transparent or neon sheets at camera height.

	Geometry is static and anchored. Collisions and queries are off where they are not needed.
	Station models are named by station id. Each station has a single "Title" billboard with a
	free row the client fills with per-player price info. Interaction does NOT use server
	Touched events (exploitable). Clients send an intent and the server validates distance.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Stations = require(Shared.Config.Stations)

type StationDef = Stations.StationDef

local ArenaService = {}

local ARENA_NAME = "OceanArena"

local PAD_BASE = Color3.fromRGB(28, 54, 84)
local MARBLE = Color3.fromRGB(236, 232, 222)
local PLAZA_COLOR = Color3.fromRGB(232, 218, 182)
local STONE_COLOR = Color3.fromRGB(196, 186, 168)

local function part(props: {
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?,
	transparency: number?,
	collide: boolean?,
	parent: Instance,
}): Part
	local p = Instance.new("Part")
	p.Name = props.name
	p.Anchored = true
	p.Size = props.size
	p.CFrame = props.cframe
	p.Color = props.color
	p.Material = props.material or Enum.Material.SmoothPlastic
	p.Shape = props.shape or Enum.PartType.Block
	p.Transparency = props.transparency or 0
	p.CanCollide = if props.collide == nil then true else props.collide
	p.CanTouch = false
	p.CanQuery = p.CanCollide
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = props.parent
	return p
end

-- Flat disc whose top face sits exactly at `topY`.
local function disc(name: string, center: Vector3, diameter: number, thickness: number, topY: number, color: Color3, material: Enum.Material, parent: Instance, collide: boolean?): Part
	return part({
		name = name,
		size = Vector3.new(thickness, diameter, diameter),
		-- Cylinders extend along X. Rotate so the flat face points up.
		cframe = CFrame.new(center.X, topY - thickness / 2, center.Z) * CFrame.Angles(0, 0, math.rad(90)),
		color = color,
		material = material,
		shape = Enum.PartType.Cylinder,
		collide = collide,
		parent = parent,
	})
end

-- One billboard per station. With `infoRow`, the bottom 40% is left for the client's price label.
local function titleBillboard(adornee: BasePart, text: string, offsetY: number, infoRow: boolean)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Title"
	gui.Size = UDim2.fromOffset(230, if infoRow then 64 else 40)
	gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	gui.MaxDistance = 80
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Name = "Name"
	label.Size = UDim2.fromScale(1, if infoRow then 0.6 else 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.Text = text
	label.Parent = gui
	gui.Parent = adornee
end

local function buildPad(station: StationDef, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = station.id
	local pos = station.position
	local diameter = station.radius * 1.3
	local pad = disc("Pad", pos, diameter, 1, pos.Y + 1.0, PAD_BASE, Enum.Material.Slate, model)
	-- Glowing lip: wider than the pad but lower, so its top never meets the pad's top face.
	disc("Ring", pos, diameter + 1.2, 0.6, pos.Y + 0.6, station.color, Enum.Material.Neon, model, false)
	disc("Inlay", pos, diameter * 0.55, 0.2, pos.Y + 1.2, station.color, Enum.Material.SmoothPlastic, model, false)

	-- Pillar stands on the outer edge so its sign faces players arriving from the plaza.
	local back = pos + Stations.outward(pos) * (diameter / 2 - 1.6)
	local pillar = part({
		name = "Pillar",
		size = Vector3.new(2.2, 7, 2.2),
		cframe = CFrame.new(back + Vector3.new(0, 1.0 + 3.5, 0)),
		color = MARBLE,
		material = Enum.Material.Marble,
		parent = model,
	})
	part({
		name = "Orb",
		size = Vector3.new(3, 3, 3),
		cframe = CFrame.new(back + Vector3.new(0, 1.0 + 7 + 1.6, 0)),
		color = station.color,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Ball,
		collide = false,
		parent = model,
	})
	model.PrimaryPart = pad
	titleBillboard(pillar, station.displayName, 9, true)
	model.Parent = parent
	return model
end

local function buildClam(station: StationDef, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = station.id
	local pos = station.position
	local base = disc("Pad", pos, 22, 1, pos.Y + 1.0, Color3.fromRGB(240, 205, 222), Enum.Material.Sand, model)
	disc("Ring", pos, 23.2, 0.6, pos.Y + 0.6, Color3.fromRGB(255, 200, 235), Enum.Material.Neon, model, false)
	local shellColor = Color3.fromRGB(255, 180, 210)
	-- Shells open toward the plaza centre. The centre clam opens south, toward the spawn.
	local facing = CFrame.lookAt(pos, pos - Stations.outward(pos))
	part({ name = "ShellBottom", size = Vector3.new(14, 3, 11), cframe = facing * CFrame.new(0, 2.5, 0), color = shellColor, material = Enum.Material.Pebble, parent = model })
	part({
		name = "ShellTop",
		size = Vector3.new(14, 2, 11),
		cframe = facing * CFrame.new(0, 7.5, 3) * CFrame.Angles(math.rad(-35), 0, 0),
		color = shellColor,
		material = Enum.Material.Pebble,
		parent = model,
	})
	local pearl = part({
		name = "Pearl",
		size = Vector3.new(5, 5, 5),
		cframe = CFrame.new(pos + Vector3.new(0, 6.5, 0)),
		color = Color3.fromRGB(250, 245, 255),
		material = Enum.Material.Neon,
		shape = Enum.PartType.Ball,
		collide = false,
		parent = model,
	})
	local light = Instance.new("PointLight")
	light.Range = 14
	light.Brightness = 1.2
	light.Color = Color3.fromRGB(220, 230, 255)
	light.Parent = pearl
	model.PrimaryPart = base
	titleBillboard(pearl, station.displayName, 6, false)
	model.Parent = parent
	return model
end

local function buildAltar(station: StationDef, parent: Instance): Model
	local model = buildPad(station, parent)
	local pos = station.position
	for i = 0, 5 do
		-- Columns at 0..300 degrees leave an opening on the axis lane in front of the altar.
		local a = math.rad(i * 60)
		local base = pos + Vector3.new(math.cos(a) * 13, 0, math.sin(a) * 13)
		disc("AltarFoot", base, 3.6, 0.5, pos.Y + 0.5, MARBLE, Enum.Material.Marble, model)
		part({
			name = "AltarPillar",
			size = Vector3.new(2, 15.5, 2),
			cframe = CFrame.new(base + Vector3.new(0, 0.5 + 15.5 / 2, 0)),
			color = Color3.fromRGB(150, 110, 220),
			material = Enum.Material.Marble,
			parent = model,
		})
	end
	return model
end

-- Central plaza: a raised disc with a border of pearls and the spawn just south of centre.
local function buildPlaza(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Plaza"
	disc("PlazaFloor", Vector3.zero, Stations.PLAZA_RADIUS * 2, 0.4, 0.4, PLAZA_COLOR, Enum.Material.Limestone, folder)
	local count = 40
	local r = Stations.PLAZA_RADIUS + 1.5
	for i = 1, count do
		local a = (i / count) * math.pi * 2
		part({
			name = "BorderPearl",
			size = Vector3.new(1.6, 1.6, 1.6),
			cframe = CFrame.new(math.cos(a) * r, 0.5, math.sin(a) * r),
			color = Color3.fromRGB(255, 246, 252),
			material = Enum.Material.SmoothPlastic,
			shape = Enum.PartType.Ball,
			collide = false,
			parent = folder,
		})
	end
	folder.Parent = parent
end

-- Stepping-stone walkways: the promenade ring plus the north and south axis lanes.
-- Stones are spaced apart so none overlap (no coplanar tops).
local function buildPaths(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Paths"
	local function stone(position: Vector3, size: number)
		disc("Stone", position, size, 0.3, 0.3, STONE_COLOR, Enum.Material.Slate, folder, false)
	end

	local promenade = Stations.PROMENADE_RADIUS
	local spacing = 7
	local count = math.floor(2 * math.pi * promenade / spacing)
	local corridor = Stations.STAIRWAY.width / 2 + 2
	for i = 0, count - 1 do
		local a = (i / count) * math.pi * 2
		local position = Vector3.new(math.sin(a) * promenade, 0, -math.cos(a) * promenade)
		-- Skip stones under the stairway lane and where the axis lanes cross (no overlapping stones).
		local onLane = math.abs(position.X) < (if position.Z < 0 then corridor else Stations.AXIS_HALF_WIDTH)
		if not onLane then
			stone(position, 4.2)
		end
	end

	local plazaEdge = Stations.PLAZA_RADIUS + 5
	-- North lane: plaza to the stairway base.
	local z = -plazaEdge
	while z > Stations.STAIRWAY.baseZ + 6 do
		stone(Vector3.new(0, 0, z), 5)
		z -= spacing
	end
	-- South lane: plaza to the Evolution Altar.
	local altarStart = Stations.ALTAR_RADIUS - 14
	z = plazaEdge
	while z < altarStart do
		stone(Vector3.new(0, 0, z), 5)
		z += spacing
	end
	folder.Parent = parent
end

local function buildStairway(parent: Instance)
	local cfg = Stations.STAIRWAY
	local folder = Instance.new("Folder")
	folder.Name = "HeavenlyStairway"
	local depth = (cfg.baseZ - cfg.topZ) / cfg.stepCount
	local rise = cfg.topY / cfg.stepCount
	for i = 1, cfg.stepCount do
		local t = i / cfg.stepCount
		-- Exact sizes: neighbouring steps touch at a shared face and never overlap.
		part({
			name = "Step" .. i,
			size = Vector3.new(cfg.width, rise * i, depth),
			cframe = CFrame.new(0, rise * i / 2, cfg.baseZ - depth * (i - 0.5)),
			color = Color3.fromRGB(190, 225, 255):Lerp(Color3.fromRGB(255, 240, 205), t),
			material = Enum.Material.Marble,
			parent = folder,
		})
	end
	-- Glow strips along the stair sides, set slightly outside the steps (no shared faces).
	local stairLength = cfg.baseZ - cfg.topZ
	local slope = math.atan2(cfg.topY, stairLength)
	local slopeLength = math.sqrt(stairLength ^ 2 + cfg.topY ^ 2)
	for _, sign in { -1, 1 } do
		part({
			name = "GlowStrip",
			size = Vector3.new(0.6, 0.6, slopeLength),
			cframe = CFrame.new(sign * (cfg.width / 2 + 0.6), cfg.topY / 2 + 0.6, (cfg.baseZ + cfg.topZ) / 2) * CFrame.Angles(slope, 0, 0),
			color = Color3.fromRGB(255, 230, 170),
			material = Enum.Material.Neon,
			collide = false,
			parent = folder,
		})
	end

	local center = cfg.platformCenter
	part({
		name = "Platform",
		size = Vector3.new(cfg.platformSize.X, 2, cfg.platformSize.Y),
		cframe = CFrame.new(center - Vector3.new(0, 1, 0)),
		color = Color3.fromRGB(255, 245, 225),
		material = Enum.Material.Marble,
		parent = folder,
	})
	-- Guard rails sit just outside the platform footprint, so no faces are shared.
	local half = cfg.platformSize / 2
	local railColor = Color3.fromRGB(255, 220, 140)
	local railY = center.Y + 1.5
	for _, sign in { -1, 1 } do
		part({ name = "Rail", size = Vector3.new(1, 3, cfg.platformSize.Y), cframe = CFrame.new(sign * (half.X + 0.5), railY, center.Z), color = railColor, material = Enum.Material.Marble, parent = folder })
		local frontWidth = half.X - cfg.width / 2
		part({
			name = "Rail",
			size = Vector3.new(frontWidth, 3, 1),
			cframe = CFrame.new(sign * (cfg.width / 2 + frontWidth / 2), railY, center.Z + half.Y + 0.5),
			color = railColor,
			material = Enum.Material.Marble,
			parent = folder,
		})
		-- Invisible side walls along the stairs. They also block the gap in the arena boundary.
		local wallHeight = cfg.topY + 10
		part({
			name = "StairWall",
			size = Vector3.new(1, wallHeight, stairLength),
			cframe = CFrame.new(sign * (cfg.width / 2 + 1.5), wallHeight / 2, (cfg.baseZ + cfg.topZ) / 2),
			color = Color3.new(1, 1, 1),
			transparency = 1,
			parent = folder,
		})
	end
	part({ name = "Rail", size = Vector3.new(cfg.platformSize.X + 2, 3, 1), cframe = CFrame.new(0, railY, center.Z - half.Y - 0.5), color = railColor, material = Enum.Material.Marble, parent = folder })

	-- Locked until the client is told the stairway is open. Each client disables collision
	-- locally (character physics are client-owned). Statue purchases are validated server-side regardless.
	local barrier = part({
		name = "StairwayBarrier",
		size = Vector3.new(cfg.width + 2, 24, 1),
		cframe = CFrame.new(0, 12, cfg.baseZ + 3),
		color = Color3.fromRGB(150, 200, 255),
		material = Enum.Material.ForceField,
		transparency = 0.3,
		parent = folder,
	})
	titleBillboard(barrier, "Heavenly Stairway: reach Evolution 5", 0, false)
	folder.Parent = parent
end

function ArenaService.init()
	local existing = Workspace:FindFirstChild(ARENA_NAME)
	if existing then
		existing:Destroy()
	end
	local arena = Instance.new("Folder")
	arena.Name = ARENA_NAME

	disc("SeaFloor", Vector3.zero, Stations.FLOOR_RADIUS * 2, 4, 0, Color3.fromRGB(214, 196, 150), Enum.Material.Sand, arena)

	-- Invisible boundary ring (24 segments), open to the north where the stairway leaves.
	local segments = 24
	local radius = Stations.FLOOR_RADIUS - 1
	local segmentLength = 2 * math.pi * radius / segments + 1
	local northSegment = segments * 3 // 4 -- angle 270 deg = -Z
	for i = 1, segments do
		if i == northSegment then
			continue
		end
		local a = (i / segments) * math.pi * 2
		part({
			name = "Boundary",
			size = Vector3.new(segmentLength, 60, 2),
			cframe = CFrame.new(math.cos(a) * radius, 30, math.sin(a) * radius) * CFrame.Angles(0, -a + math.pi / 2, 0),
			color = Color3.new(0, 0, 0),
			transparency = 1,
			parent = arena,
		})
	end
	-- Plug the gaps between the stair walls and the neighbouring boundary segments.
	local gapEdge = segmentLength / 2
	local stairEdge = Stations.STAIRWAY.width / 2 + 2
	for _, sign in { -1, 1 } do
		part({
			name = "BoundaryPlug",
			size = Vector3.new(gapEdge - stairEdge + 2, 60, 6),
			cframe = CFrame.new(sign * (stairEdge + gapEdge) / 2, 30, -radius),
			color = Color3.new(0, 0, 0),
			transparency = 1,
			parent = arena,
		})
	end

	buildPlaza(arena)
	buildPaths(arena)

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(8, 0.4, 8)
	-- Sits on the plaza (top 0.4) with its own top at 0.8. Faces north toward the centre clam.
	spawn.CFrame = CFrame.lookAt(Stations.SPAWN_POSITION + Vector3.new(0, 0.6, 0), Vector3.new(0, 0.6, -100))
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Color = Color3.fromRGB(120, 210, 255)
	spawn.CastShadow = false
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = arena
	local decal = spawn:FindFirstChildOfClass("Decal")
	if decal then
		decal:Destroy()
	end

	local stationsFolder = Instance.new("Folder")
	stationsFolder.Name = "Stations"
	stationsFolder.Parent = arena
	for _, station in Stations.LIST do
		if station.kind == "Clam" then
			buildClam(station, stationsFolder)
		elseif station.kind == "Evolution" then
			buildAltar(station, stationsFolder)
		else
			buildPad(station, stationsFolder)
		end
	end

	buildStairway(arena)
	arena.Parent = Workspace
end

-- Server-side proximity check against the authoritative layout (not the parts).
function ArenaService.isNear(player: Player, station: StationDef): boolean
	local character = player.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return false
	end
	local offset = root.Position - station.position
	local horizontal = Vector3.new(offset.X, 0, offset.Z).Magnitude
	return horizontal <= station.radius + Stations.PROXIMITY_TOLERANCE
		and math.abs(offset.Y) <= Stations.VERTICAL_TOLERANCE
end

return ArenaService
