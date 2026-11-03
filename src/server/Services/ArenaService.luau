--!strict
--[[
	ArenaService: builds the physical arena on the server from Config/Stations.

	Layout: central plaza (spawn + global buff pads), five stand plots around it (stand model,
	main pad, Multiplier / Manager / Speed pads), the Evolution Temple with perk pads to the north,
	and the Heavenly Stairway behind it. All geometry is shared by every player. Per-player state
	(locked, owned, managed, prices) is shown client-side by WorldController.

	Rendering rules (these prevent z-fighting and flicker):
	  * No two visible faces are ever coplanar. Every stacked layer has its own height above the
	    surface it sits on: stones +0.3, plot base +0.3, pad lip +0.25, pad +0.45, inlay +0.55.
	    Surfaces: sea floor 0.01, plaza 0.4, statue platform 56.
	  * Parts that touch share an edge, not a volume (stair steps do not overlap).
	  * No large transparent or neon sheets at camera height.

	Interaction does NOT use server Touched events (exploitable). Clients send an intent when they
	step on a pad (or press E) and the server validates distance against Config/Stations.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Stations = require(Shared.Config.Stations)
local Economy = require(Shared.Config.Economy)

type StationDef = Stations.StationDef
type StandPlot = Stations.StandPlot

local ArenaService = {}

local ARENA_NAME = "OceanArena"

local MARBLE = Color3.fromRGB(236, 232, 222)
local PAD_BASE = Color3.fromRGB(28, 54, 84)
local PLAZA_COLOR = Color3.fromRGB(232, 218, 182)
local STONE_COLOR = Color3.fromRGB(196, 186, 168)
local SURFACE_FOR_KIND = {
	Buff = Stations.PLAZA_TOP,
}

-- The Studio Baseplate template adds a Baseplate (top at y = 0) and a SpawnLocation
-- (top at y = 1). Both are coplanar with arena floors and flicker, so the arena replaces them.
local function removeTemplateParts()
	local baseplate = Workspace:FindFirstChild("Baseplate")
	if baseplate and baseplate:IsA("BasePart") then
		baseplate:Destroy()
	end
	for _, child in Workspace:GetChildren() do
		if child:IsA("SpawnLocation") then
			child:Destroy()
		end
	end
end

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

-- Billboard named "Title". With `infoRow`, the bottom 40% is left for the client's per-player text.
local function titleBillboard(adornee: BasePart, text: string, offsetY: number, infoRow: boolean, width: number?, maxDistance: number?)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Title"
	local w = width or 230
	gui.Size = UDim2.fromOffset(w, if infoRow then math.floor(w * 0.28) else math.floor(w * 0.17))
	gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	gui.MaxDistance = maxDistance or 80
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

-- Walking surface under a pad.
local function surfaceFor(station: StationDef): number
	if station.kind == "Statue" then
		return station.position.Y
	end
	return SURFACE_FOR_KIND[station.kind] or Stations.SEA_FLOOR_TOP
end

local PAD_LABELS: { [string]: string } = {
	Multiplier = "x2 Multiplier",
	Speed = "x2 Speed",
	Manager = "Hire Manager",
}

-- A flat, walk-on pad: neon lip, slate pad and coloured inlay, each at its own height.
local function buildPad(station: StationDef, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = station.id
	local pos = station.position
	local surface = surfaceFor(station)
	local diameter = station.radius * 2
	local pad = disc("Pad", pos, diameter, 0.5, surface + 0.45, PAD_BASE, Enum.Material.Slate, model)
	disc("Ring", pos, diameter + 1, 0.3, surface + 0.25, station.color, Enum.Material.Neon, model, false)
	disc("Inlay", pos, diameter * 0.6, 0.15, surface + 0.55, station.color, Enum.Material.SmoothPlastic, model, false)
	model.PrimaryPart = pad
	local label = PAD_LABELS[station.kind] or station.displayName
	local width = if station.kind == "StandMain" then 190 elseif station.kind == "Statue" then 210 else 160
	titleBillboard(pad, label, if station.kind == "Statue" then 13 else 4.5, true, width, 60)
	model.Parent = parent
	return model
end

-- ===== Stand models (themed props on each plot) =====

local function propPart(model: Model, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
	return part({ name = name, size = size, cframe = cframe, color = color, material = material, shape = shape, parent = model })
end

local function buildClamProp(model: Model, base: CFrame, color: Color3)
	propPart(model, "ShellBottom", Vector3.new(11, 2.5, 9), base * CFrame.new(0, 1.6, 0), color, Enum.Material.Pebble)
	propPart(model, "ShellTop", Vector3.new(11, 1.6, 9), base * CFrame.new(0, 5.6, 3) * CFrame.Angles(math.rad(-35), 0, 0), color, Enum.Material.Pebble)
	local pearl = propPart(model, "Pearl", Vector3.new(4, 4, 4), base * CFrame.new(0, 4.6, 0), Color3.fromRGB(250, 245, 255), Enum.Material.Neon, Enum.PartType.Ball)
	pearl.CanCollide = false
end

local function buildCoralProp(model: Model, base: CFrame, color: Color3)
	local offsets = { Vector3.new(-3, 0, 0), Vector3.new(0, 0, -1.5), Vector3.new(3, 0, 0.5), Vector3.new(-1, 0, 2) }
	for i, offset in offsets do
		local height = 5 + (i % 3) * 2
		local tilt = CFrame.Angles(math.rad((i - 2.5) * 9), 0, math.rad((i % 2) * 14 - 7))
		local stem = base * CFrame.new(offset) * tilt * CFrame.new(0, height / 2 + 0.3, 0)
		propPart(model, "Branch", Vector3.new(height, 1.1, 1.1), stem * CFrame.Angles(0, 0, math.rad(90)), color, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		propPart(model, "Bud", Vector3.new(1.9, 1.9, 1.9), stem * CFrame.new(0, height / 2, 0), color:Lerp(Color3.new(1, 1, 1), 0.35), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	end
end

local function buildKelpProp(model: Model, base: CFrame, color: Color3)
	for _, x in { -3, 3 } do
		local vat = propPart(model, "Vat", Vector3.new(7, 4.5, 4.5), base * CFrame.new(x, 3.8, 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(170, 220, 255), Enum.Material.Glass, Enum.PartType.Cylinder)
		vat.Transparency = 0.5
		propPart(model, "Kelp", Vector3.new(0.6, 5.5, 0.3), base * CFrame.new(x, 3.6, 0), color, Enum.Material.SmoothPlastic)
	end
	propPart(model, "Chimney", Vector3.new(1.6, 9, 1.6), base * CFrame.new(0, 4.8, -2.6), Color3.fromRGB(110, 120, 130), Enum.Material.Metal)
end

local function buildVaultProp(model: Model, base: CFrame, color: Color3)
	propPart(model, "Vault", Vector3.new(9, 7, 6), base * CFrame.new(0, 3.8, -0.5), Color3.fromRGB(120, 125, 135), Enum.Material.DiamondPlate)
	propPart(model, "Door", Vector3.new(0.4, 5, 5), base * CFrame.new(0, 3.8, 2.75) * CFrame.Angles(0, math.rad(90), 0), color, Enum.Material.Foil, Enum.PartType.Cylinder)
	for i = 1, 5 do
		local a = i * 1.3
		propPart(model, "Coin", Vector3.new(1.4, 1.4, 1.4), base * CFrame.new(math.cos(a) * 3.8, 0.9, 3.2 + math.sin(a) * 0.6), color, Enum.Material.Foil, Enum.PartType.Ball)
	end
end

local function buildKrakenProp(model: Model, base: CFrame, color: Color3)
	propPart(model, "Dome", Vector3.new(8, 8, 8), base * CFrame.new(0, 4.3, 0), color, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	for i = 0, 3 do
		local a = math.rad(i * 90 + 45)
		local tentacle = base * CFrame.new(math.cos(a) * 4.6, 1.6, math.sin(a) * 4.6) * CFrame.Angles(0, -a, math.rad(35))
		propPart(model, "Tentacle", Vector3.new(6, 1.2, 1.2), tentacle, color:Lerp(Color3.new(0, 0, 0), 0.15), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	end
	for _, x in { -1.6, 1.6 } do
		propPart(model, "Eye", Vector3.new(1.4, 1.4, 1.4), base * CFrame.new(x, 6, 3.5), Color3.fromRGB(255, 255, 255), Enum.Material.Neon, Enum.PartType.Ball)
	end
end

local PROP_BUILDERS: { [string]: (Model, CFrame, Color3) -> () } = {
	PearlClam = buildClamProp,
	CoralFarm = buildCoralProp,
	KelpFactory = buildKelpProp,
	SunkenVault = buildVaultProp,
	KrakenDen = buildKrakenProp,
}

local function buildStand(plot: StandPlot, parent: Instance)
	local def = Economy.STAND_BY_ID[plot.standId]
	local model = Instance.new("Model")
	model.Name = plot.standId
	local floor = Stations.SEA_FLOOR_TOP
	local center = Vector3.new(plot.center.X, floor, plot.center.Z)
	-- Local frame: -Z of `facing` points at the plaza.
	local facing = CFrame.lookAt(center, center + plot.forward)
	local base = disc("Base", center, 16, 0.4, floor + 0.3, MARBLE, Enum.Material.Marble, model)
	model.PrimaryPart = base

	-- Prop sits behind the counter. Built in a frame rotated so +Z faces the plaza.
	local propFrame = facing * CFrame.new(0, 0.3, 1.5) * CFrame.Angles(0, math.pi, 0)
	local builder = PROP_BUILDERS[plot.standId]
	if builder then
		builder(model, propFrame, plot.color)
	end
	propPart(model, "Counter", Vector3.new(10, 2.6, 2.4), facing * CFrame.new(0, 0.3 + 1.3, -4.5), Color3.fromRGB(150, 105, 70), Enum.Material.Wood)
	propPart(model, "CounterTop", Vector3.new(10.4, 0.3, 2.8), facing * CFrame.new(0, 0.3 + 2.6 + 0.15, -4.5), plot.color, Enum.Material.SmoothPlastic)

	-- Sign post behind the prop, with the stand name and a client-filled info row.
	local post = propPart(model, "SignPost", Vector3.new(1, 10, 1), facing * CFrame.new(0, 0.3 + 5, 6.5), MARBLE, Enum.Material.Marble)
	titleBillboard(post, def.name, 7.5, true, 260, 110)
	model.Parent = parent
end

-- ===== Plaza, paths, temple =====

local function buildPlaza(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Plaza"
	disc("PlazaFloor", Vector3.zero, Stations.PLAZA_RADIUS * 2, 0.4, Stations.PLAZA_TOP, PLAZA_COLOR, Enum.Material.Limestone, folder)
	local count = 36
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

-- Stepping stones: the promenade ring plus the lanes to the temple and the stairway.
-- Stones are spaced apart so none overlap (no coplanar tops).
local function buildPaths(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Paths"
	local function stone(position: Vector3, size: number)
		disc("Stone", position, size, 0.3, Stations.SEA_FLOOR_TOP + 0.3, STONE_COLOR, Enum.Material.Slate, folder, false)
	end
	local promenade = Stations.PROMENADE_RADIUS
	local spacing = 7
	local count = math.floor(2 * math.pi * promenade / spacing)
	for i = 0, count - 1 do
		local a = (i / count) * math.pi * 2
		local position = Vector3.new(math.sin(a) * promenade, 0, -math.cos(a) * promenade)
		if math.abs(position.X) > 4 or position.Z > 0 then -- leave the north lane crossing to the lane stones
			stone(position, 4.2)
		end
	end
	-- Plaza to the perk pads in front of the temple.
	local z = -(Stations.PLAZA_RADIUS + 5)
	local perkEdge = Stations.TEMPLE_CENTER.Z + 18 + 6
	while z > perkEdge do
		stone(Vector3.new(0, 0, z), 5)
		z -= spacing
	end
	-- Behind the altar to the stairway base.
	z = Stations.TEMPLE_CENTER.Z - 12
	while z > Stations.STAIRWAY.baseZ + 6 do
		stone(Vector3.new(0, 0, z), 5)
		z -= spacing
	end
	folder.Parent = parent
end

local function buildTemple(parent: Instance)
	local model = Instance.new("Model")
	model.Name = "EvolutionTemple"
	local center = Stations.TEMPLE_CENTER
	local floor = Stations.SEA_FLOOR_TOP
	local base = disc("TempleBase", center, 14, 0.5, floor + 0.3, MARBLE, Enum.Material.Marble, model)
	model.PrimaryPart = base
	for i = 0, 5 do
		local a = math.rad(i * 60 + 30)
		local foot = center + Vector3.new(math.cos(a) * 5.5, 0, math.sin(a) * 5.5)
		part({ name = "Pillar", size = Vector3.new(1.4, 9, 1.4), cframe = CFrame.new(foot.X, floor + 0.3 + 4.5, foot.Z), color = Color3.fromRGB(170, 130, 230), material = Enum.Material.Marble, parent = model })
	end
	local crystal = part({
		name = "Crystal",
		size = Vector3.new(4, 4, 4),
		cframe = CFrame.new(center.X, floor + 7, center.Z) * CFrame.Angles(math.rad(45), 0, math.rad(45)),
		color = Color3.fromRGB(200, 140, 255),
		material = Enum.Material.Neon,
		collide = false,
		parent = model,
	})
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(200, 140, 255)
	light.Range = 18
	light.Brightness = 1.5
	light.Parent = crystal
	titleBillboard(crystal, "Evolution Temple", 5, true, 260, 110)
	model.Parent = parent
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
	removeTemplateParts()
	local arena = Instance.new("Folder")
	arena.Name = ARENA_NAME

	disc("SeaFloor", Vector3.zero, Stations.FLOOR_RADIUS * 2, 4, Stations.SEA_FLOOR_TOP, Color3.fromRGB(214, 196, 150), Enum.Material.Sand, arena)

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
	buildTemple(arena)

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(8, 0.4, 8)
	-- Sits on the plaza (top 0.4) with its own top at 0.8, facing the first stand.
	local spawnPos = Stations.SPAWN_POSITION + Vector3.new(0, 0.6, 0)
	local firstStand = Stations.PLOT_BY_STAND[Economy.STARTING_STAND]
	local lookTarget = if firstStand then Vector3.new(firstStand.center.X, spawnPos.Y, firstStand.center.Z) else spawnPos + Vector3.new(0, 0, -10)
	spawn.CFrame = CFrame.lookAt(spawnPos, lookTarget)
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

	local standsFolder = Instance.new("Folder")
	standsFolder.Name = "Stands"
	standsFolder.Parent = arena
	for _, plot in Stations.PLOTS do
		buildStand(plot, standsFolder)
	end

	local stationsFolder = Instance.new("Folder")
	stationsFolder.Name = "Stations"
	stationsFolder.Parent = arena
	for _, station in Stations.LIST do
		buildPad(station, stationsFolder)
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
	return horizontal <= station.promptRadius + Stations.PROXIMITY_TOLERANCE
		and math.abs(offset.Y) <= Stations.VERTICAL_TOLERANCE
end

return ArenaService
