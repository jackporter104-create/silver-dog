--!strict
--[[
	ArenaService: builds the physical arena on the server from Config/Stations.
	Geometry is static and anchored. Collisions and queries are off where they are not needed.
	Station models are named by station id, so clients can attach per-player labels.
	Interaction is NOT done with server Touched events (exploitable). Clients send an
	intent and the server validates distance against Config/Stations.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Stations = require(Shared.Config.Stations)

type StationDef = Stations.StationDef

local ArenaService = {}

local ARENA_NAME = "OceanArena"

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

local function cylinderCFrame(position: Vector3): CFrame
	-- Cylinders extend along X. Rotate so the flat face points up.
	return CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
end

local function titleBillboard(adornee: BasePart, text: string, offsetY: number)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Title"
	gui.Size = UDim2.fromOffset(220, 40)
	gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	gui.MaxDistance = 90
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
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
	local pad = part({
		name = "Pad",
		size = Vector3.new(1, station.radius * 1.3, station.radius * 1.3),
		cframe = cylinderCFrame(pos + Vector3.new(0, 0.5, 0)),
		color = Color3.fromRGB(30, 60, 90),
		material = Enum.Material.Slate,
		shape = Enum.PartType.Cylinder,
		parent = model,
	})
	part({
		name = "Ring",
		size = Vector3.new(1.1, station.radius * 1.36, station.radius * 1.36),
		cframe = cylinderCFrame(pos + Vector3.new(0, 0.45, 0)),
		color = station.color,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Cylinder,
		collide = false,
		parent = model,
	})
	local pillar = part({
		name = "Pillar",
		size = Vector3.new(2.4, 7, 2.4),
		cframe = CFrame.new(pos + Vector3.new(0, 4.5, -station.radius * 0.45)),
		color = Color3.fromRGB(40, 80, 120),
		material = Enum.Material.Glass,
		transparency = 0.2,
		parent = model,
	})
	part({
		name = "Orb",
		size = Vector3.new(3, 3, 3),
		cframe = CFrame.new(pos + Vector3.new(0, 9.5, -station.radius * 0.45)),
		color = station.color,
		material = Enum.Material.Neon,
		shape = Enum.PartType.Ball,
		collide = false,
		parent = model,
	})
	model.PrimaryPart = pad
	titleBillboard(pillar, station.displayName, 8)
	model.Parent = parent
	return model
end

local function buildClam(station: StationDef, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = station.id
	local pos = station.position
	local base = part({
		name = "Pad",
		size = Vector3.new(1, 22, 22),
		cframe = cylinderCFrame(pos + Vector3.new(0, 0.5, 0)),
		color = Color3.fromRGB(240, 200, 220),
		material = Enum.Material.Sand,
		shape = Enum.PartType.Cylinder,
		parent = model,
	})
	local shellColor = Color3.fromRGB(255, 180, 210)
	part({ name = "ShellBottom", size = Vector3.new(14, 3, 11), cframe = CFrame.new(pos + Vector3.new(0, 2, 0)), color = shellColor, material = Enum.Material.Pebble, parent = model })
	part({
		name = "ShellTop",
		size = Vector3.new(14, 2, 11),
		cframe = CFrame.new(pos + Vector3.new(0, 7, 3)) * CFrame.Angles(math.rad(-35), 0, 0),
		color = shellColor,
		material = Enum.Material.Pebble,
		parent = model,
	})
	local pearl = part({
		name = "Pearl",
		size = Vector3.new(5, 5, 5),
		cframe = CFrame.new(pos + Vector3.new(0, 5.5, 0)),
		color = Color3.fromRGB(250, 245, 255),
		material = Enum.Material.Neon,
		shape = Enum.PartType.Ball,
		collide = false,
		parent = model,
	})
	local light = Instance.new("PointLight")
	light.Range = 14
	light.Brightness = 1.5
	light.Color = Color3.fromRGB(220, 230, 255)
	light.Parent = pearl
	model.PrimaryPart = base
	titleBillboard(pearl, station.displayName, 6)
	model.Parent = parent
	return model
end

local function buildAltar(station: StationDef, parent: Instance): Model
	local model = buildPad(station, parent)
	local pos = station.position
	for i = 0, 5 do
		local a = math.rad(i * 60)
		part({
			name = "AltarPillar",
			size = Vector3.new(2, 16, 2),
			cframe = CFrame.new(pos + Vector3.new(math.cos(a) * 12, 8, math.sin(a) * 12)),
			color = Color3.fromRGB(120, 80, 200),
			material = Enum.Material.Marble,
			parent = model,
		})
	end
	return model
end

local function buildStairway(parent: Instance)
	local cfg = Stations.STAIRWAY
	local folder = Instance.new("Folder")
	folder.Name = "HeavenlyStairway"
	local depth = (cfg.baseZ - cfg.topZ) / cfg.stepCount
	local rise = cfg.topY / cfg.stepCount
	for i = 1, cfg.stepCount do
		local t = i / cfg.stepCount
		part({
			name = "Step" .. i,
			size = Vector3.new(cfg.width, rise * i, depth + 0.05),
			cframe = CFrame.new(0, rise * i / 2, cfg.baseZ - depth * (i - 0.5)),
			color = Color3.fromRGB(180, 220, 255):Lerp(Color3.fromRGB(255, 240, 200), t),
			material = if i % 4 == 0 then Enum.Material.Neon else Enum.Material.Marble,
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
	-- Guard rails so players do not walk off the platform edge.
	local half = cfg.platformSize / 2
	for _, offset in { Vector3.new(half.X, 0, 0), Vector3.new(-half.X, 0, 0) } do
		part({ name = "Rail", size = Vector3.new(1, 6, cfg.platformSize.Y), cframe = CFrame.new(center + offset + Vector3.new(0, 3, 0)), color = Color3.fromRGB(255, 220, 140), material = Enum.Material.Neon, transparency = 0.5, parent = folder })
	end
	part({ name = "Rail", size = Vector3.new(cfg.platformSize.X, 6, 1), cframe = CFrame.new(center + Vector3.new(0, 3, -half.Y)), color = Color3.fromRGB(255, 220, 140), material = Enum.Material.Neon, transparency = 0.5, parent = folder })
	-- Front rails on either side of the stair opening.
	local frontWidth = half.X - cfg.width / 2
	for _, sign in { -1, 1 } do
		part({
			name = "Rail",
			size = Vector3.new(frontWidth, 6, 1),
			cframe = CFrame.new(sign * (cfg.width / 2 + frontWidth / 2), center.Y + 3, center.Z + half.Y),
			color = Color3.fromRGB(255, 220, 140),
			material = Enum.Material.Neon,
			transparency = 0.5,
			parent = folder,
		})
		-- Tall side rails along the stairs double as the arena boundary where the stairs leave the floor.
		local railHeight = cfg.topY + 8
		part({
			name = "StairRail",
			size = Vector3.new(1, railHeight, cfg.baseZ - cfg.topZ),
			cframe = CFrame.new(sign * (cfg.width / 2 + 0.5), railHeight / 2, (cfg.baseZ + cfg.topZ) / 2),
			color = Color3.fromRGB(200, 230, 255),
			material = Enum.Material.Glass,
			transparency = 0.7,
			parent = folder,
		})
	end

	-- Locked until the client is told the stairway is open. Each client disables collision
	-- locally (character physics are client-owned). Statue purchases are validated server-side regardless.
	local barrier = part({
		name = "StairwayBarrier",
		size = Vector3.new(cfg.width + 4, 30, 2),
		cframe = CFrame.new(0, 15, cfg.baseZ + 2),
		color = Color3.fromRGB(150, 200, 255),
		material = Enum.Material.ForceField,
		transparency = 0.2,
		parent = folder,
	})
	titleBillboard(barrier, "Heavenly Stairway: reach Evolution 5", 0)
	folder.Parent = parent
end

function ArenaService.init()
	local existing = Workspace:FindFirstChild(ARENA_NAME)
	if existing then
		existing:Destroy()
	end
	local arena = Instance.new("Folder")
	arena.Name = ARENA_NAME

	part({
		name = "SeaFloor",
		size = Vector3.new(4, Stations.FLOOR_RADIUS * 2, Stations.FLOOR_RADIUS * 2),
		cframe = cylinderCFrame(Vector3.new(0, -2, 0)),
		color = Color3.fromRGB(214, 196, 150),
		material = Enum.Material.Sand,
		shape = Enum.PartType.Cylinder,
		parent = arena,
	})
	-- Invisible boundary ring (24 segments).
	local segments = 24
	local radius = Stations.FLOOR_RADIUS - 1
	local segmentLength = 2 * math.pi * radius / segments + 1
	local northSegment = segments * 3 // 4 -- angle 270 deg = -Z, where the stairway leaves the floor
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

	-- Plug the gaps between the stair rails and the neighbouring boundary segments.
	local gapEdge = segmentLength / 2
	local stairEdge = Stations.STAIRWAY.width / 2 + 1
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

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(10, 1, 10)
	spawn.CFrame = CFrame.new(Stations.SPAWN_POSITION + Vector3.new(0, 0.5, 0))
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Material = Enum.Material.Neon
	spawn.Color = Color3.fromRGB(0, 200, 255)
	spawn.Transparency = 0.4
	spawn.Parent = arena

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
