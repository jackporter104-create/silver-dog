--!strict
--[[
	ArenaService: builds the world and every player's zone on the server.

	World (Config/Stations): a 3x3 grid. The centre cell is the shared Hub (Evolution Temple with
	perk pads, Heavenly Stairway with statue pads). The 8 surrounding cells are Player Zones.

	Zones:
	  * assignZone() gives a joining player the first free zone, enables its spawn and moves the
	    character there on every spawn. releaseZone() clears it when they leave.
	  * syncZone() rebuilds the zone from the player's data with a diff: only the next stand's "???"
	    Deed pad, owned stand structures with their main pads, upgrade pads as they are revealed,
	    managers, and unlocked buff pads. Everything is server-built, so every player can see
	    everyone's businesses. Per-player prices are added client-side for the owner only.
	  * isNear() resolves zone pads in the requesting player's OWN zone, so standing on someone
	    else's pad never validates a purchase.

	Rendering rules (prevent z-fighting): no two visible faces are coplanar. Surfaces: sea floor 0.01,
	zone/hub ground 0.3, zone plaza 0.6, statue platform 40. Layers on a surface: stones +0.3,
	plot base +0.3, pad lip +0.25, pad +0.45, inlay +0.55.
	Interaction never uses server Touched events (exploitable): clients send intents.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local EconomyMath = require(Shared.EconomyMath)
local Stations = require(Shared.Config.Stations)
local Economy = require(Shared.Config.Economy)

type StationDef = Stations.StationDef
type PlayerData = Types.PlayerData

local ArenaService = {}

local ARENA_NAME = "OceanArena"
ArenaService.MANAGER_TAG = "OceanManager"

local MARBLE = Color3.fromRGB(236, 232, 222)
local PAD_BASE = Color3.fromRGB(28, 54, 84)
local PLAZA_COLOR = Color3.fromRGB(232, 218, 182)
local ZONE_COLOR = Color3.fromRGB(222, 205, 160)
local STONE_COLOR = Color3.fromRGB(196, 186, 168)
local MYSTERY = Color3.fromRGB(170, 120, 255)

type Zone = {
	index: number,
	owner: Player?,
	folder: Folder,
	stations: Folder,
	stands: Folder,
	spawn: SpawnLocation,
	sign: TextLabel,
	pads: { [string]: Model },
	structures: { [string]: Model },
	managers: { [string]: Model },
	characterConnection: RBXScriptConnection?,
}

local zones: { Zone } = {}
local zoneByPlayer: { [Player]: Zone } = {}

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

-- ===== Pads =====

local PAD_LABELS: { [string]: string } = {
	Multiplier = "x2 Multiplier",
	Speed = "x2 Speed",
	Manager = "Hire Manager",
}

-- Walking surface under a pad.
local function surfaceFor(station: StationDef): number
	if station.kind == "Statue" then
		return station.position.Y
	elseif station.kind == "Buff" then
		return Stations.PLAZA_TOP
	end
	return Stations.ZONE_TOP
end

-- A flat walk-on pad at a world position: neon lip, slate pad and coloured inlay at distinct heights.
local function buildPad(station: StationDef, position: Vector3, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = station.id
	local surface = surfaceFor(station)
	local diameter = station.radius * 2
	local isDeed = station.kind == "Deed"
	local pad = disc("Pad", position, diameter, 0.5, surface + 0.45, PAD_BASE, Enum.Material.Slate, model)
	disc("Ring", position, diameter + 1, 0.3, surface + 0.25, station.color, Enum.Material.Neon, model, false)
	disc("Inlay", position, diameter * 0.6, 0.15, surface + 0.55, station.color, if isDeed then Enum.Material.Neon else Enum.Material.SmoothPlastic, model, false)
	model.PrimaryPart = pad
	if isDeed then
		-- The mystery pad: a floating orb with a big "???" and no hint of what is coming.
		local orb = part({
			name = "Orb",
			size = Vector3.new(3, 3, 3),
			cframe = CFrame.new(position.X, surface + 5, position.Z),
			color = MYSTERY,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Ball,
			collide = false,
			parent = model,
		})
		titleBillboard(orb, "???", 4, true, 220, 120)
	else
		local label = PAD_LABELS[station.kind] or station.displayName
		local width = if station.kind == "StandMain" then 190 elseif station.kind == "Statue" then 210 else 160
		titleBillboard(pad, label, if station.kind == "Statue" then 13 else 4.5, true, width, 60)
	end
	model.Parent = parent
	return model
end

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

-- World-space plot frame for a stand in a zone.
local function plotFrame(zoneIndex: number, standId: string): (Vector3, Vector3, Vector3, Color3)
	local plot = Stations.PLOT_BY_STAND[standId]
	return Stations.toWorld(zoneIndex, plot.center), Stations.zoneDirection(zoneIndex, plot.forward), Stations.zoneDirection(zoneIndex, plot.right), plot.color
end

local function buildStand(zone: Zone, standId: string): Model
	local def = Economy.STAND_BY_ID[standId]
	local worldCenter, forward, _, color = plotFrame(zone.index, standId)
	local model = Instance.new("Model")
	model.Name = standId
	local floor = Stations.ZONE_TOP
	local center = Vector3.new(worldCenter.X, floor, worldCenter.Z)
	-- Local frame: -Z of `facing` points at the plaza.
	local facing = CFrame.lookAt(center, center + forward)
	local base = disc("Base", center, 16, 0.4, floor + 0.3, MARBLE, Enum.Material.Marble, model)
	model.PrimaryPart = base
	local propFrame = facing * CFrame.new(0, 0.3, 1.5) * CFrame.Angles(0, math.pi, 0)
	local builder = PROP_BUILDERS[standId]
	if builder then
		builder(model, propFrame, color)
	end
	propPart(model, "Counter", Vector3.new(10, 2.6, 2.4), facing * CFrame.new(0, 0.3 + 1.3, -4.5), Color3.fromRGB(150, 105, 70), Enum.Material.Wood)
	propPart(model, "CounterTop", Vector3.new(10.4, 0.3, 2.8), facing * CFrame.new(0, 0.3 + 2.6 + 0.15, -4.5), color, Enum.Material.SmoothPlastic)
	local post = propPart(model, "SignPost", Vector3.new(1, 10, 1), facing * CFrame.new(0, 0.3 + 5, 6.5), MARBLE, Enum.Material.Marble)
	titleBillboard(post, def.name, 7.5, true, 260, 110)
	model.Parent = zone.stands
	return model
end

-- Manager NPC (crab or mermaid). Static on the server; every client plays the work loop locally
-- on models tagged MANAGER_TAG. Parts named "Arm" scoop.
local function buildManager(zone: Zone, standId: string): Model
	local def = Economy.STAND_BY_ID[standId]
	local worldCenter, forward, right = plotFrame(zone.index, standId)
	local model = Instance.new("Model")
	model.Name = "Manager_" .. standId
	local position = worldCenter + right * 7 + forward * 4
	local root = CFrame.lookAt(Vector3.new(position.X, Stations.ZONE_TOP, position.Z), Vector3.new(position.X, Stations.ZONE_TOP, position.Z) + forward)
	local function add(name: string, size: Vector3, offset: CFrame, color: Color3, shape: Enum.PartType?)
		part({ name = name, size = size, cframe = root * offset, color = color, material = Enum.Material.SmoothPlastic, shape = shape, collide = false, parent = model })
	end
	local eye = Color3.fromRGB(20, 20, 30)
	if def.npc == "Crab" then
		local shell = Color3.fromRGB(235, 80, 60)
		add("Body", Vector3.new(3.2, 1.6, 2.4), CFrame.new(0, 1.6, 0), shell, Enum.PartType.Ball)
		for _, x in { -0.6, 0.6 } do
			add("Stalk", Vector3.new(0.25, 0.9, 0.25), CFrame.new(x, 2.6, -0.6), shell)
			add("Eye", Vector3.new(0.45, 0.45, 0.45), CFrame.new(x, 3.1, -0.6), eye, Enum.PartType.Ball)
		end
		for _, x in { -2, 2 } do
			add("Arm", Vector3.new(1.2, 0.9, 1.2), CFrame.new(x, 2.2, -1.2), shell, Enum.PartType.Ball)
		end
		for i = -1, 1 do
			for _, x in { -1.4, 1.4 } do
				add("Leg", Vector3.new(0.25, 1.2, 0.25), CFrame.new(x, 0.7, i * 0.6) * CFrame.Angles(0, 0, math.rad(if x > 0 then -30 else 30)), shell)
			end
		end
	else
		local skin = Color3.fromRGB(255, 214, 180)
		local tail = Color3.fromRGB(60, 200, 190)
		add("Tail", Vector3.new(1.4, 2.6, 1.2), CFrame.new(0, 1.3, 0), tail, Enum.PartType.Ball)
		add("Fin", Vector3.new(0.3, 1.2, 1.6), CFrame.new(0, 0.3, 0.6) * CFrame.Angles(math.rad(30), 0, 0), tail)
		add("Body", Vector3.new(1.3, 1.6, 0.9), CFrame.new(0, 3.2, 0), Color3.fromRGB(255, 120, 170))
		add("Head", Vector3.new(1.2, 1.2, 1.2), CFrame.new(0, 4.5, 0), skin, Enum.PartType.Ball)
		add("Hair", Vector3.new(1.4, 1.3, 1), CFrame.new(0, 4.7, 0.25), Color3.fromRGB(250, 170, 60), Enum.PartType.Ball)
		for _, x in { -0.25, 0.25 } do
			add("Eye", Vector3.new(0.18, 0.2, 0.1), CFrame.new(x, 4.6, -0.6), eye)
		end
		for _, x in { -0.9, 0.9 } do
			add("Arm", Vector3.new(0.35, 1.4, 0.35), CFrame.new(x, 3.2, -0.3), skin)
		end
	end
	model.WorldPivot = root
	CollectionService:AddTag(model, ArenaService.MANAGER_TAG)
	model.Parent = zone.stands
	return model
end

-- ===== Hub =====

local function buildHub(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Hub"
	disc("HubFloor", Vector3.zero, Stations.HUB_RADIUS * 2, 0.6, Stations.ZONE_TOP, ZONE_COLOR, Enum.Material.Limestone, folder)

	local temple = Instance.new("Model")
	temple.Name = "EvolutionTemple"
	local center = Stations.TEMPLE_CENTER
	local floor = Stations.ZONE_TOP
	temple.PrimaryPart = disc("TempleBase", center, 14, 0.5, floor + 0.3, MARBLE, Enum.Material.Marble, temple)
	for i = 0, 5 do
		local a = math.rad(i * 60 + 30)
		local foot = center + Vector3.new(math.cos(a) * 5.5, 0, math.sin(a) * 5.5)
		part({ name = "Pillar", size = Vector3.new(1.4, 9, 1.4), cframe = CFrame.new(foot.X, floor + 0.3 + 4.5, foot.Z), color = Color3.fromRGB(170, 130, 230), material = Enum.Material.Marble, parent = temple })
	end
	local crystal = part({
		name = "Crystal",
		size = Vector3.new(4, 4, 4),
		cframe = CFrame.new(center.X, floor + 7, center.Z) * CFrame.Angles(math.rad(45), 0, math.rad(45)),
		color = Color3.fromRGB(200, 140, 255),
		material = Enum.Material.Neon,
		collide = false,
		parent = temple,
	})
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(200, 140, 255)
	light.Range = 18
	light.Brightness = 1.5
	light.Parent = crystal
	titleBillboard(crystal, "Evolution Temple", 5, true, 260, 140)
	temple.Parent = folder

	-- Stepping stones from the temple to the stairs.
	local z = center.Z - 7 - 4
	while z > Stations.STAIRWAY.baseZ + 6 do
		disc("Stone", Vector3.new(0, 0, z), 5, 0.3, Stations.ZONE_TOP + 0.3, STONE_COLOR, Enum.Material.Slate, folder, false)
		z -= 7
	end

	local stations = Instance.new("Folder")
	stations.Name = "Stations"
	stations.Parent = folder
	for _, station in Stations.HUB_LIST do
		buildPad(station, station.position, stations)
	end
	buildStairway(folder)
	folder.Parent = parent
end

-- ===== Zones =====

local function buildZoneBase(index: number, parent: Instance): Zone
	local folder = Instance.new("Folder")
	folder.Name = "Zone" .. index
	local center = Stations.zoneCenter(index)
	disc("ZoneFloor", center, Stations.ZONE_RADIUS * 2, 0.6, Stations.ZONE_TOP, ZONE_COLOR, Enum.Material.Sand, folder)
	disc("Plaza", center, Stations.ZONE_PLAZA_RADIUS * 2, 0.4, Stations.PLAZA_TOP, PLAZA_COLOR, Enum.Material.Limestone, folder)

	-- Border pearls around the zone edge.
	local count = 32
	local r = Stations.ZONE_RADIUS - 1
	for i = 1, count do
		local a = (i / count) * math.pi * 2
		part({
			name = "BorderPearl",
			size = Vector3.new(1.8, 1.8, 1.8),
			cframe = CFrame.new(center.X + math.cos(a) * r, Stations.ZONE_TOP + 0.6, center.Z + math.sin(a) * r),
			color = Color3.fromRGB(255, 246, 252),
			material = Enum.Material.SmoothPlastic,
			shape = Enum.PartType.Ball,
			collide = false,
			parent = folder,
		})
	end

	-- Path toward the Hub: stones inside the zone, then across the open sea floor.
	local toHub = -Vector3.new(center.X, 0, center.Z).Unit
	local totalDistance = Vector3.new(center.X, 0, center.Z).Magnitude
	local d = Stations.ZONE_PLAZA_RADIUS + 4
	while d < totalDistance - Stations.HUB_RADIUS - 3 do
		local point = center + toHub * d
		local insideZone = d < Stations.ZONE_RADIUS - 3
		local outsideZone = d > Stations.ZONE_RADIUS + 3
		local cfg = Stations.STAIRWAY
		local underStairs = math.abs(point.X) < cfg.width / 2 + 3 and point.Z < cfg.baseZ + 3 and point.Z > cfg.topZ - 3
		if (insideZone or outsideZone) and not underStairs then
			local surface = if insideZone then Stations.ZONE_TOP else Stations.SEA_FLOOR_TOP
			disc("Stone", point, 5, 0.3, surface + 0.3, STONE_COLOR, Enum.Material.Slate, folder, false)
		end
		d += 7
	end

	-- Owner sign beside the path, at the plaza edge.
	local signPosition = Stations.toWorld(index, Vector3.new(6, 0, -(Stations.ZONE_PLAZA_RADIUS + 3)))
	local post = part({
		name = "OwnerSign",
		size = Vector3.new(1, 8, 1),
		cframe = CFrame.new(signPosition.X, Stations.ZONE_TOP + 4, signPosition.Z),
		color = MARBLE,
		material = Enum.Material.Marble,
		parent = folder,
	})
	titleBillboard(post, "Free Reef", 6, false, 260, 200)
	local title = post:FindFirstChild("Title")
	local nameLabel = title and title:FindFirstChild("Name")
	assert(nameLabel and nameLabel:IsA("TextLabel"), "owner sign label")

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(8, 0.4, 8)
	-- Sits on the plaza (top 0.6) with its own top at 1.0, facing the first stand.
	local spawnPosition = Stations.toWorld(index, Stations.SPAWN_LOCAL) + Vector3.new(0, 0.2, 0)
	local facing = Stations.toWorld(index, Stations.SPAWN_FACING_LOCAL)
	spawn.CFrame = CFrame.lookAt(spawnPosition, Vector3.new(facing.X, spawnPosition.Y, facing.Z))
	spawn.Neutral = true
	spawn.Enabled = false
	spawn.Duration = 0
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Color = Color3.fromRGB(120, 210, 255)
	spawn.CastShadow = false
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = folder
	local decal = spawn:FindFirstChildOfClass("Decal")
	if decal then
		decal:Destroy()
	end

	local stations = Instance.new("Folder")
	stations.Name = "Stations"
	stations.Parent = folder
	local stands = Instance.new("Folder")
	stands.Name = "Stands"
	stands.Parent = folder
	folder.Parent = parent

	return {
		index = index,
		owner = nil,
		folder = folder,
		stations = stations,
		stands = stands,
		spawn = spawn,
		sign = nameLabel :: TextLabel,
		pads = {},
		structures = {},
		managers = {},
		characterConnection = nil,
	}
end

local function clearZone(zone: Zone)
	for _, model in zone.pads do
		model:Destroy()
	end
	for _, model in zone.structures do
		model:Destroy()
	end
	for _, model in zone.managers do
		model:Destroy()
	end
	table.clear(zone.pads)
	table.clear(zone.structures)
	table.clear(zone.managers)
end

-- ===== Public API =====

function ArenaService.init()
	local existing = Workspace:FindFirstChild(ARENA_NAME)
	if existing then
		existing:Destroy()
	end
	removeTemplateParts()
	local arena = Instance.new("Folder")
	arena.Name = ARENA_NAME

	local half = Stations.MAP_HALF
	part({
		name = "SeaFloor",
		size = Vector3.new(half * 2, 4, half * 2),
		cframe = CFrame.new(0, Stations.SEA_FLOOR_TOP - 2, 0),
		color = Color3.fromRGB(214, 196, 150),
		material = Enum.Material.Sand,
		parent = arena,
	})
	-- Invisible boundary walls around the square world.
	for _, side in { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) } do
		local alongX = side.X == 0
		part({
			name = "Boundary",
			size = if alongX then Vector3.new(half * 2 + 4, 80, 2) else Vector3.new(2, 80, half * 2 + 4),
			cframe = CFrame.new(side * (half + 1) + Vector3.new(0, 40, 0)),
			color = Color3.new(0, 0, 0),
			transparency = 1,
			parent = arena,
		})
	end

	buildHub(arena)
	local zonesFolder = Instance.new("Folder")
	zonesFolder.Name = "Zones"
	zonesFolder.Parent = arena
	for index = 1, Stations.ZONE_COUNT do
		zones[index] = buildZoneBase(index, zonesFolder)
	end
	arena.Parent = Workspace
end

local function moveToZone(character: Model, zone: Zone)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if root and zone.owner and character.Parent then
		character:PivotTo(zone.spawn.CFrame + Vector3.new(0, 3.5, 0))
	end
end

-- Gives the player the first free zone. Returns nil when all zones are taken.
function ArenaService.assignZone(player: Player): number?
	local existing = zoneByPlayer[player]
	if existing then
		return existing.index
	end
	for _, zone in zones do
		if not zone.owner then
			zone.owner = player
			zoneByPlayer[player] = zone
			zone.sign.Text = player.DisplayName .. "'s Reef"
			zone.spawn.Enabled = true
			player.RespawnLocation = zone.spawn
			player:SetAttribute("ZoneIndex", zone.index)
			zone.characterConnection = player.CharacterAdded:Connect(function(character)
				moveToZone(character, zone)
			end)
			if player.Character then
				task.spawn(moveToZone, player.Character, zone)
			end
			return zone.index
		end
	end
	return nil
end

function ArenaService.releaseZone(player: Player)
	local zone = zoneByPlayer[player]
	if not zone then
		return
	end
	zoneByPlayer[player] = nil
	if zone.characterConnection then
		zone.characterConnection:Disconnect()
		zone.characterConnection = nil
	end
	clearZone(zone)
	zone.owner = nil
	zone.sign.Text = "Free Reef"
	zone.spawn.Enabled = false
end

function ArenaService.zoneIndex(player: Player): number?
	local zone = zoneByPlayer[player]
	return if zone then zone.index else nil
end

-- Diff-rebuilds the player's zone to match their data (progressive reveal).
function ArenaService.syncZone(player: Player, data: PlayerData)
	local zone = zoneByPlayer[player]
	if not zone then
		return
	end
	for _, station in Stations.ZONE_LIST do
		local visible = EconomyMath.isPadVisible(data, station.kind, station.target or "")
		local built = zone.pads[station.id]
		if visible and not built then
			zone.pads[station.id] = buildPad(station, Stations.toWorld(zone.index, station.position), zone.stations)
		elseif not visible and built then
			built:Destroy()
			zone.pads[station.id] = nil
		end
	end
	for _, def in Economy.STANDS do
		local owned = EconomyMath.isOwned(data, def.id)
		local managed = EconomyMath.isManaged(data, def.id)
		local structure = zone.structures[def.id]
		if owned and not structure then
			zone.structures[def.id] = buildStand(zone, def.id)
		elseif not owned and structure then
			structure:Destroy()
			zone.structures[def.id] = nil
		end
		local manager = zone.managers[def.id]
		if managed and not manager then
			zone.managers[def.id] = buildManager(zone, def.id)
		elseif not managed and manager then
			manager:Destroy()
			zone.managers[def.id] = nil
		end
	end
end

-- After a deed purchase the structure appears where the player stands: move them onto the
-- stand's main pad, facing their new business.
function ArenaService.presentStand(player: Player, standId: string)
	local zone = zoneByPlayer[player]
	local main = Stations.BY_ID[standId .. "_Main"]
	local character = player.Character
	if not zone or not main or not character or not character:FindFirstChild("HumanoidRootPart") then
		return
	end
	local padPosition = Stations.toWorld(zone.index, main.position)
	local center = plotFrame(zone.index, standId)
	local from = padPosition + Vector3.new(0, 3.5, 0)
	character:PivotTo(CFrame.lookAt(from, Vector3.new(center.X, from.Y, center.Z)))
end

-- Server-side proximity check. Zone pads resolve to the player's OWN zone only.
function ArenaService.isNear(player: Player, station: StationDef): boolean
	local position = Stations.worldPosition(station, ArenaService.zoneIndex(player))
	if not position then
		return false
	end
	local character = player.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return false
	end
	local offset = root.Position - position
	local horizontal = Vector3.new(offset.X, 0, offset.Z).Magnitude
	return horizontal <= station.promptRadius + Stations.PROXIMITY_TOLERANCE
		and math.abs(offset.Y) <= Stations.VERTICAL_TOLERANCE
end

return ArenaService
