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
	    everyone's businesses.
	  * No 3D text anywhere: pads carry floating 3D icons, and names, prices and prompts are shown
	    only in the 2D HUD. The owner's name is the zone folder's "OwnerName" attribute.

	Visuals: every business is a procedural model (Parts, WedgeParts, sphere-meshed ellipsoids,
	particles, lights). Moving pieces are Models tagged ANIM_TAG with an "Anim" attribute, and
	pulsing lights are tagged GLOW_TAG. Clients animate them locally (WorldController), so the
	server never replicates per-frame motion.
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
local ZONE_FLAG_COLORS = {
	Color3.fromRGB(255, 110, 150),
	Color3.fromRGB(90, 200, 255),
	Color3.fromRGB(255, 200, 70),
	Color3.fromRGB(120, 230, 140),
	Color3.fromRGB(190, 130, 255),
	Color3.fromRGB(255, 150, 80),
	Color3.fromRGB(80, 230, 210),
	Color3.fromRGB(255, 120, 220),
}

type Zone = {
	index: number,
	owner: Player?,
	folder: Folder,
	stations: Folder,
	stands: Folder,
	spawn: SpawnLocation,
	flag: BasePart,
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
-- ===== Animation tags (client-side animation, see WorldController) =====

ArenaService.ANIM_TAG = "OceanAnim"
ArenaService.GLOW_TAG = "OceanGlow"

-- Marks a Model for client-side animation. The model's WorldPivot is the animation origin:
--   Hinge  rotate about local X around the rest pose (clam lid, chest lid). amp = degrees
--   Spin   rotate about local Y at `speed` rad/s (gears, icons)
--   Sway   rock about local X and Z (corals, kelp, tentacles, flags). amp = degrees
--   Bounce hop up along local Y, |sin| (pearls). amp = studs
--   Float  bob along Y and slowly spin (pad icons). amp = studs
local function animate(model: Model, pivot: CFrame, kind: string, speed: number, amplitude: number, phase: number?)
	model.WorldPivot = pivot
	model:SetAttribute("AnimPivot", pivot) -- explicit copy: clients must not rely on WorldPivot replication
	model:SetAttribute("Anim", kind)
	model:SetAttribute("AnimSpeed", speed)
	model:SetAttribute("AnimAmp", amplitude)
	model:SetAttribute("AnimPhase", phase or math.random() * math.pi * 2)
	CollectionService:AddTag(model, ArenaService.ANIM_TAG)
end

-- Pulses a PointLight's brightness or a neon part's transparency with TweenService (client-side).
local function glow(instance: Instance, period: number)
	instance:SetAttribute("GlowPeriod", period)
	CollectionService:AddTag(instance, ArenaService.GLOW_TAG)
end

local function group(name: string, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	return model
end

-- Decorative part: anchored, no collision, no queries (stands get one invisible collider instead).
local function deco(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
	return part({ name = name, size = size, cframe = cframe, color = color, material = material, shape = shape, collide = false, parent = parent })
end

-- Smooth ellipsoid: a block with a sphere mesh (scales freely, unlike Ball parts).
local function ellipsoid(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material): Part
	local p = deco(parent, name, size, cframe, color, material)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	return p
end

-- Cylinder standing upright (Roblox cylinders run along X).
local function column(parent: Instance, name: string, height: number, diameter: number, base: CFrame, color: Color3, material: Enum.Material): Part
	return deco(parent, name, Vector3.new(height, diameter, diameter), base * CFrame.new(0, height / 2, 0) * CFrame.Angles(0, 0, math.rad(90)), color, material, Enum.PartType.Cylinder)
end

local function wedge(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material): WedgePart
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Anchored = true
	w.CanCollide = false
	w.CanQuery = false
	w.CanTouch = false
	w.CastShadow = false
	w.Size = size
	w.CFrame = cframe
	w.Color = color
	w.Material = material
	w.Parent = parent
	return w
end

local function emitter(parent: BasePart, props: { rate: number, color: Color3, size: number, speed: number, lifetime: number, texture: string?, spread: number?, accel: Vector3?, light: number? }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Rate = props.rate
	e.Color = ColorSequence.new(props.color)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, props.size), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	e.Speed = NumberRange.new(props.speed * 0.6, props.speed)
	e.Lifetime = NumberRange.new(props.lifetime * 0.6, props.lifetime)
	e.SpreadAngle = Vector2.new(props.spread or 25, props.spread or 25)
	e.Acceleration = props.accel or Vector3.zero
	e.LightEmission = props.light or 0.7
	if props.texture then
		e.Texture = props.texture
	end
	e.Parent = parent
	return e
end

local function pointLight(parent: BasePart, color: Color3, range: number, brightness: number): PointLight
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness
	light.Parent = parent
	glow(light, 2.5)
	return light
end

local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local BUBBLE_COLOR = Color3.fromRGB(210, 240, 255)
local GOLD = Color3.fromRGB(255, 200, 60)

-- ===== Pads =====

-- Walking surface under a pad.
local function surfaceFor(station: StationDef): number
	if station.kind == "Statue" then
		return station.position.Y
	elseif station.kind == "Buff" or station.kind == "Shop" then
		return Stations.PLAZA_TOP
	end
	return Stations.ZONE_TOP
end

-- Floating 3D icon above a pad: tells kids what a pad does without any text.
local function padIcon(station: StationDef, position: Vector3, surface: number, model: Model)
	local kind = station.kind
	if kind == "Statue" then
		return -- the raised statue itself stands on this pad
	end
	local icon = group("Icon", model)
	local c = CFrame.new(position.X, surface + 4.4, position.Z)
	if kind == "Deed" then
		-- A glowing mystery box with a golden ribbon.
		deco(icon, "Box", Vector3.new(2.6, 2.6, 2.6), c, station.color, Enum.Material.Neon)
		deco(icon, "RibbonX", Vector3.new(2.75, 2.75, 0.5), c, GOLD, Enum.Material.Foil)
		deco(icon, "RibbonZ", Vector3.new(0.5, 2.75, 2.75), c, GOLD, Enum.Material.Foil)
		for _, x in { -0.5, 0.5 } do
			deco(icon, "Bow", Vector3.new(0.9, 0.9, 0.9), c * CFrame.new(x, 1.7, 0), GOLD, Enum.Material.Foil, Enum.PartType.Ball)
		end
		local box = icon:FindFirstChild("Box") :: BasePart
		emitter(box, { rate = 4, color = Color3.fromRGB(230, 200, 255), size = 0.6, speed = 3, lifetime = 1.2, texture = SPARKLE_TEXTURE, spread = 180 })
		pointLight(box, station.color, 12, 1.5)
	elseif kind == "StandMain" then
		-- A spinning golden coin: "earn here".
		deco(icon, "Coin", Vector3.new(0.4, 2.6, 2.6), c, GOLD, Enum.Material.Foil, Enum.PartType.Cylinder)
		deco(icon, "CoinFace", Vector3.new(0.5, 1.6, 1.6), c, station.color, Enum.Material.Neon, Enum.PartType.Cylinder)
	elseif kind == "Multiplier" then
		-- A golden up-arrow: two mirrored wedges for the head, a block for the shaft.
		deco(icon, "Shaft", Vector3.new(0.7, 1.4, 0.8), c * CFrame.new(0, -0.6, 0), station.color, Enum.Material.Neon)
		wedge(icon, "HeadA", Vector3.new(0.7, 1.3, 1.1), c * CFrame.new(0, 0.75, -0.55), station.color, Enum.Material.Neon)
		wedge(icon, "HeadB", Vector3.new(0.7, 1.3, 1.1), c * CFrame.new(0, 0.75, 0.55) * CFrame.Angles(0, math.pi, 0), station.color, Enum.Material.Neon)
	elseif kind == "Speed" then
		-- A lightning bolt.
		deco(icon, "BoltTop", Vector3.new(0.6, 1.4, 0.6), c * CFrame.new(-0.3, 0.8, 0) * CFrame.Angles(0, 0, math.rad(-25)), station.color, Enum.Material.Neon)
		deco(icon, "BoltMid", Vector3.new(1.4, 0.5, 0.6), c, station.color, Enum.Material.Neon)
		deco(icon, "BoltLow", Vector3.new(0.6, 1.4, 0.6), c * CFrame.new(0.3, -0.8, 0) * CFrame.Angles(0, 0, math.rad(-25)), station.color, Enum.Material.Neon)
	elseif kind == "Manager" then
		-- A top hat: brim, crown and a green band.
		local hatColor = Color3.fromRGB(40, 40, 55)
		deco(icon, "Brim", Vector3.new(0.3, 2.8, 2.8), c * CFrame.new(0, -0.9, 0) * CFrame.Angles(0, 0, math.rad(90)), hatColor, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		deco(icon, "Crown", Vector3.new(1.8, 1.8, 1.8), c * CFrame.new(0, 0.1, 0) * CFrame.Angles(0, 0, math.rad(90)), hatColor, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		deco(icon, "Band", Vector3.new(0.45, 1.9, 1.9), c * CFrame.new(0, -0.45, 0) * CFrame.Angles(0, 0, math.rad(90)), station.color, Enum.Material.Neon, Enum.PartType.Cylinder)
	elseif kind == "Buff" or kind == "Evolve" then
		-- A glowing crystal.
		local size = if kind == "Buff" then Vector3.new(1.7, 1.7, 1.7) else Vector3.new(1.2, 2.4, 1.2)
		local crystal = deco(icon, "Crystal", size, c * CFrame.Angles(math.rad(45), 0, math.rad(45)), station.color, Enum.Material.Neon)
		glow(crystal, 1.8)
		pointLight(crystal, station.color, 10, 1.2)
	elseif kind == "Shop" then
		-- A tiny treasure chest overflowing with a pearl.
		deco(icon, "Chest", Vector3.new(2.2, 1.2, 1.5), c * CFrame.new(0, -0.4, 0), Color3.fromRGB(150, 95, 55), Enum.Material.Wood)
		deco(icon, "Lid", Vector3.new(2.2, 1.5, 1.5), c * CFrame.new(0, 0.2, 0), GOLD, Enum.Material.Foil, Enum.PartType.Cylinder)
		local pearl = deco(icon, "Pearl", Vector3.new(1.1, 1.1, 1.1), c * CFrame.new(0, 1.2, 0), Color3.fromRGB(255, 240, 250), Enum.Material.Neon, Enum.PartType.Ball)
		emitter(pearl, { rate = 3, color = GOLD, size = 0.5, speed = 2, lifetime = 1, texture = SPARKLE_TEXTURE, spread = 180 })
	end
	animate(icon, c, "Float", 1.6, 0.45)
end

-- A flat walk-on pad at a world position: neon lip, slate pad and coloured inlay at distinct
-- heights, with a floating icon. No text: names and prices live in the 2D HUD.
local function buildPad(station: StationDef, position: Vector3, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = station.id
	local surface = surfaceFor(station)
	local diameter = station.radius * 2
	local pad = disc("Pad", position, diameter, 0.5, surface + 0.45, PAD_BASE, Enum.Material.Slate, model)
	disc("Ring", position, diameter + 1, 0.3, surface + 0.25, station.color, Enum.Material.Neon, model, false)
	disc("Inlay", position, diameter * 0.6, 0.15, surface + 0.55, station.color, if station.kind == "Deed" then Enum.Material.Neon else Enum.Material.SmoothPlastic, model, false)
	model.PrimaryPart = pad
	padIcon(station, position, surface, model)
	model.Parent = parent
	return model
end

-- ===== Procedural business models =====
-- Each builder gets `base`: plot centre on top of the plot disc, +Z facing the plaza.

local function buildClamModel(model: Model, base: CFrame, color: Color3)
	local inner = Color3.fromRGB(255, 236, 246)
	local rib = color:Lerp(Color3.new(1, 1, 1), 0.35)
	ellipsoid(model, "ShellBottom", Vector3.new(12, 3.4, 10), base * CFrame.new(0, 1.4, 0), color, Enum.Material.SmoothPlastic)
	local nacre = ellipsoid(model, "Nacre", Vector3.new(10.2, 1.4, 8.4), base * CFrame.new(0, 2.6, 0), inner, Enum.Material.SmoothPlastic)
	nacre.Reflectance = 0.25
	for i = -3, 3 do
		deco(model, "Rib", Vector3.new(0.5, 0.5, 5.2), base * CFrame.Angles(0, math.rad(i * 18), 0) * CFrame.new(0, 1.1, 2.9) * CFrame.Angles(math.rad(-14), 0, 0), rib, Enum.Material.SmoothPlastic)
	end

	-- Lid: built at its open rest pose around a hinge on the back edge, then rocked by the client.
	local lid = group("Lid", model)
	local hinge = base * CFrame.new(0, 2.8, -4.6) * CFrame.Angles(math.rad(-50), 0, 0)
	ellipsoid(lid, "Shell", Vector3.new(12, 2.8, 10), hinge * CFrame.new(0, 0.9, 4.8), color, Enum.Material.SmoothPlastic)
	ellipsoid(lid, "Inside", Vector3.new(10.2, 1.2, 8.4), hinge * CFrame.new(0, 0.1, 4.8), inner, Enum.Material.SmoothPlastic)
	for i = -3, 3 do
		deco(lid, "Rib", Vector3.new(0.5, 0.5, 9), hinge * CFrame.new(0, 0, 4.8) * CFrame.Angles(0, math.rad(i * 13), 0) * CFrame.new(0, 2.1, 0), rib, Enum.Material.SmoothPlastic)
	end
	animate(lid, hinge, "Hinge", 0.5, 12)

	-- The pearl hops on the nacre and glows.
	local pearlGroup = group("PearlGroup", model)
	local pearlCenter = base * CFrame.new(0, 3.9, 2.4)
	local pearl = deco(pearlGroup, "Pearl", Vector3.new(3.4, 3.4, 3.4), pearlCenter, Color3.fromRGB(255, 245, 252), Enum.Material.Neon, Enum.PartType.Ball)
	pointLight(pearl, Color3.fromRGB(255, 220, 245), 16, 1.6)
	emitter(pearl, { rate = 3, color = Color3.fromRGB(255, 230, 250), size = 0.7, speed = 2.5, lifetime = 1.4, texture = SPARKLE_TEXTURE, spread = 180 })
	animate(pearlGroup, pearlCenter, "Bounce", 2.4, 0.8)
end

local CORAL_COLORS = {
	Color3.fromRGB(255, 90, 150),
	Color3.fromRGB(255, 160, 60),
	Color3.fromRGB(180, 110, 255),
	Color3.fromRGB(60, 230, 220),
	Color3.fromRGB(255, 230, 90),
}

local function buildCoralModel(model: Model, base: CFrame, _color: Color3)
	ellipsoid(model, "Reef", Vector3.new(13, 2.4, 11), base * CFrame.new(0, 0.7, 0), Color3.fromRGB(110, 95, 120), Enum.Material.Slate)
	local spots = {
		{ x = 0, z = -1.5, h = 13 },
		{ x = -3.5, z = 0, h = 10 },
		{ x = 3.4, z = -0.5, h = 11 },
		{ x = -1.8, z = 3, h = 7 },
		{ x = 2, z = 3.2, h = 8 },
		{ x = -4.5, z = -3, h = 8 },
		{ x = 4.4, z = -3.4, h = 9 },
	}
	for i, spot in spots do
		local color = CORAL_COLORS[(i - 1) % #CORAL_COLORS + 1]
		local coral = group("Coral", model)
		local root = base * CFrame.new(spot.x, 1.2, spot.z)
		local stem = color:Lerp(Color3.new(0, 0, 0), 0.25)
		column(coral, "Stem", spot.h, 1.2, root, stem, Enum.Material.SmoothPlastic)
		local tipTop = deco(coral, "Tip", Vector3.new(2, 2, 2), root * CFrame.new(0, spot.h, 0), color, Enum.Material.Neon, Enum.PartType.Ball)
		glow(tipTop, 2 + i * 0.3)
		-- Two side branches, angled outward.
		for side = -1, 1, 2 do
			local branchBase = root * CFrame.new(0, spot.h * 0.45, 0) * CFrame.Angles(0, math.rad(i * 50), math.rad(32 * side))
			local length = spot.h * 0.45
			column(coral, "Branch", length, 0.8, branchBase, stem, Enum.Material.SmoothPlastic)
			deco(coral, "Tip", Vector3.new(1.3, 1.3, 1.3), branchBase * CFrame.new(0, length, 0), color, Enum.Material.Neon, Enum.PartType.Ball)
		end
		if i == 1 then
			pointLight(tipTop, color, 18, 1.5)
			emitter(tipTop, { rate = 2, color = BUBBLE_COLOR, size = 0.5, speed = 3, lifetime = 3, spread = 30, accel = Vector3.new(0, 2, 0), light = 0.3 })
		end
		animate(coral, root, "Sway", 0.6 + i * 0.07, 5)
	end
end

local function buildGear(parent: Model, pivot: CFrame, radius: number, color: Color3, speed: number)
	-- Pivot local Y is the gear axle.
	local gear = group("Gear", parent)
	deco(gear, "Hub", Vector3.new(0.8, radius * 2, radius * 2), pivot * CFrame.Angles(0, 0, math.rad(90)), color, Enum.Material.Metal, Enum.PartType.Cylinder)
	deco(gear, "Axle", Vector3.new(1, 0.9, 0.9), pivot * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(60, 60, 70), Enum.Material.Metal, Enum.PartType.Cylinder)
	for k = 1, 8 do
		deco(gear, "Tooth", Vector3.new(0.9, 0.7, 0.9), pivot * CFrame.Angles(0, k * math.pi / 4, 0) * CFrame.new(radius + 0.3, 0, 0), color, Enum.Material.Metal)
	end
	animate(gear, pivot, "Spin", speed, 0, 0)
end

local function buildKelpBlade(parent: Model, root: CFrame, height: number, color: Color3)
	local kelp = group("Kelp", parent)
	deco(kelp, "Blade", Vector3.new(0.9, height, 0.25), root * CFrame.new(0, height / 2, 0), color, Enum.Material.SmoothPlastic)
	deco(kelp, "Leaf", Vector3.new(1.6, 1, 0.2), root * CFrame.new(0.5, height * 0.6, 0) * CFrame.Angles(0, 0, math.rad(-30)), color, Enum.Material.SmoothPlastic)
	deco(kelp, "Leaf", Vector3.new(1.6, 1, 0.2), root * CFrame.new(-0.5, height * 0.35, 0) * CFrame.Angles(0, 0, math.rad(30)), color, Enum.Material.SmoothPlastic)
	animate(kelp, root, "Sway", 0.8, 9)
end

local function buildKelpModel(model: Model, base: CFrame, color: Color3)
	local metal = Color3.fromRGB(120, 130, 145)
	local dark = Color3.fromRGB(70, 78, 90)
	deco(model, "Platform", Vector3.new(11, 1, 8), base * CFrame.new(0, 0.45, -0.5), dark, Enum.Material.DiamondPlate)
	for _, x in { -3, 3 } do
		local vatBase = base * CFrame.new(x, 0.9, -1.2)
		local vat = column(model, "Vat", 7, 4, vatBase, Color3.fromRGB(170, 225, 255), Enum.Material.Glass)
		vat.Transparency = 0.55
		column(model, "VatRim", 0.6, 4.4, vatBase * CFrame.new(0, 7, 0), metal, Enum.Material.Metal)
		buildKelpBlade(model, vatBase * CFrame.new(0, 0.2, 0), 6, color)
	end
	-- Pipes: across the vat tops, then down the back to the chimney.
	deco(model, "PipeTop", Vector3.new(6, 0.9, 0.9), base * CFrame.new(0, 8.4, -1.2), metal, Enum.Material.Metal, Enum.PartType.Cylinder)
	deco(model, "PipeBack", Vector3.new(4, 0.9, 0.9), base * CFrame.new(0, 8.4, -3) * CFrame.Angles(0, math.rad(90), 0), metal, Enum.Material.Metal, Enum.PartType.Cylinder)
	local chimneyBase = base * CFrame.new(0, 0.9, -4.6)
	column(model, "Chimney", 11, 1.8, chimneyBase, dark, Enum.Material.Metal)
	local top = column(model, "ChimneyTop", 0.6, 2.4, chimneyBase * CFrame.new(0, 11, 0), metal, Enum.Material.Metal)
	emitter(top, { rate = 4, color = BUBBLE_COLOR, size = 0.8, speed = 4, lifetime = 3, spread = 15, accel = Vector3.new(0, 2, 0), light = 0.3 })
	-- Two meshing gears on the front, axles pointing at the plaza.
	buildGear(model, base * CFrame.new(-1.6, 4.2, 1.9) * CFrame.Angles(math.rad(90), 0, 0), 1.9, GOLD, 1.6)
	buildGear(model, base * CFrame.new(1.9, 3.1, 1.9) * CFrame.Angles(math.rad(90), 0, 0), 1.3, Color3.fromRGB(200, 120, 70), -2.3)
	-- Kelp swaying around the factory.
	for i, spot in { Vector3.new(-5.6, 0, 2.6), Vector3.new(5.6, 0, 2.2), Vector3.new(-5.2, 0, -4), Vector3.new(5.4, 0, -3.8), Vector3.new(-6.2, 0, -0.8), Vector3.new(6.2, 0, -0.6) } do
		buildKelpBlade(model, base * CFrame.new(spot) * CFrame.Angles(0, i, 0), 6 + (i % 3) * 2, color)
	end
end

local function buildVaultModel(model: Model, base: CFrame, color: Color3)
	local wood = Color3.fromRGB(130, 80, 45)
	ellipsoid(model, "SandMound", Vector3.new(14, 3.4, 12), base * CFrame.new(0, 0.6, 0), Color3.fromRGB(225, 200, 150), Enum.Material.Sand)
	-- The chest sits half-buried and slightly tilted.
	local chest = base * CFrame.new(0, 2.1, -0.8) * CFrame.Angles(0, math.rad(-8), math.rad(6))
	deco(model, "Body", Vector3.new(7, 3.4, 4.6), chest, wood, Enum.Material.Wood)
	for _, y in { -1.2, 1.2 } do
		deco(model, "Band", Vector3.new(7.2, 0.45, 4.8), chest * CFrame.new(0, y, 0), color, Enum.Material.Foil)
	end
	deco(model, "Lock", Vector3.new(1, 1.2, 0.4), chest * CFrame.new(0, 0.6, 2.45), color, Enum.Material.Foil)
	local hoard = ellipsoid(model, "Hoard", Vector3.new(6.4, 1.8, 4), chest * CFrame.new(0, 1.9, 0), GOLD, Enum.Material.Neon)
	pointLight(hoard, GOLD, 18, 1.4)
	emitter(hoard, { rate = 4, color = Color3.fromRGB(255, 240, 160), size = 0.6, speed = 2, lifetime = 1.3, texture = SPARKLE_TEXTURE, spread = 180 })

	-- Lid open at the back edge, creaking gently.
	local lid = group("Lid", model)
	local hinge = chest * CFrame.new(0, 1.7, -2.3) * CFrame.Angles(math.rad(-70), 0, 0)
	deco(lid, "LidBox", Vector3.new(7, 0.9, 4.6), hinge * CFrame.new(0, 0.45, 2.3), wood, Enum.Material.Wood)
	deco(lid, "LidArc", Vector3.new(7, 2.6, 4.6), hinge * CFrame.new(0, 0.9, 2.3), wood, Enum.Material.Wood, Enum.PartType.Cylinder)
	deco(lid, "LidBand", Vector3.new(7.2, 2.7, 0.5), hinge * CFrame.new(0, 0.9, 2.3), color, Enum.Material.Foil)
	animate(lid, hinge, "Hinge", 0.8, 5)

	-- Coins spilling out toward the plaza, plus a few gems.
	local rng = Random.new(7)
	for i = 1, 16 do
		local t = i / 16
		local offset = Vector3.new(rng:NextNumber(-3.5, 3.5), 0, 1.6 + t * 4.4)
		local height = 2.4 - t * 1.6
		deco(model, "Coin", Vector3.new(0.25, 1.3, 1.3), base * CFrame.new(offset + Vector3.new(0, height, 0)) * CFrame.Angles(rng:NextNumber(-0.5, 0.5), rng:NextNumber(0, 6), math.rad(90) + rng:NextNumber(-0.4, 0.4)), GOLD, Enum.Material.Foil, Enum.PartType.Cylinder)
	end
	for i, gemColor in { Color3.fromRGB(255, 60, 90), Color3.fromRGB(60, 160, 255), Color3.fromRGB(80, 255, 140) } do
		local gem = deco(model, "Gem", Vector3.new(0.9, 0.9, 0.9), base * CFrame.new(-3 + i * 1.6, 1.6, 3.6 + (i % 2)) * CFrame.Angles(math.rad(45), 0, math.rad(45)), gemColor, Enum.Material.Neon)
		glow(gem, 1.5 + i * 0.4)
	end
end

local function buildTentacle(parent: Model, root: CFrame, length: number, color: Color3, glowColor: Color3)
	local tentacle = group("Tentacle", parent)
	local segments = 7
	local cf = root
	for i = 1, segments do
		local t = (i - 1) / (segments - 1)
		local size = 1.6 - t * 1.1
		-- Positive X rotation curls each segment toward +Z: up, then out toward the plaza.
		cf = cf * CFrame.Angles(math.rad(12), 0, 0) * CFrame.new(0, length / segments, 0)
		deco(tentacle, "Segment", Vector3.new(size, size, size), cf, color, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		if i % 2 == 0 then
			local sucker = deco(tentacle, "Sucker", Vector3.new(size * 0.45, size * 0.45, size * 0.45), cf * CFrame.new(0, 0, size * 0.42), glowColor, Enum.Material.Neon, Enum.PartType.Ball)
			glow(sucker, 1.6)
		end
	end
	animate(tentacle, root, "Sway", 1.1, 14)
end

local function buildKrakenModel(model: Model, base: CFrame, color: Color3)
	local rock = Color3.fromRGB(48, 42, 62)
	local glowColor = color:Lerp(Color3.fromRGB(220, 120, 255), 0.5)
	-- Rocky cave arch at the back, open toward the plaza.
	ellipsoid(model, "CaveBack", Vector3.new(12, 9, 7), base * CFrame.new(0, 3.6, -3.4), rock, Enum.Material.Slate)
	ellipsoid(model, "Dark", Vector3.new(6, 5.4, 3), base * CFrame.new(0, 2.8, -0.6), Color3.fromRGB(8, 4, 16), Enum.Material.SmoothPlastic)
	ellipsoid(model, "RockLeft", Vector3.new(4.6, 7, 6), base * CFrame.new(-4.6, 2.8, -0.8) * CFrame.Angles(0, 0, math.rad(8)), rock, Enum.Material.Slate)
	ellipsoid(model, "RockRight", Vector3.new(4.6, 7.6, 6), base * CFrame.new(4.6, 3, -1) * CFrame.Angles(0, 0, math.rad(-8)), rock, Enum.Material.Slate)
	ellipsoid(model, "Capstone", Vector3.new(10, 3, 6), base * CFrame.new(0, 7.4, -1.4), rock:Lerp(Color3.new(0, 0, 0), 0.2), Enum.Material.Slate)
	-- Glowing eyes in the dark.
	for _, x in { -1.2, 1.2 } do
		local eye = deco(model, "Eye", Vector3.new(1, 1, 1), base * CFrame.new(x, 3.6, 0.6), glowColor, Enum.Material.Neon, Enum.PartType.Ball)
		glow(eye, 3)
	end
	local light = deco(model, "Glow", Vector3.new(0.5, 0.5, 0.5), base * CFrame.new(0, 3, 1), glowColor, Enum.Material.Neon, Enum.PartType.Ball)
	light.Transparency = 1
	pointLight(light, glowColor, 20, 2)
	emitter(light, { rate = 3, color = glowColor, size = 1.6, speed = 1.5, lifetime = 3, spread = 60, accel = Vector3.new(0, 0.6, 0), light = 0.5 })
	-- Tentacles reaching out of the cave mouth.
	local roots = {
		{ x = -2.6, z = 1.2, yaw = 25, length = 8 },
		{ x = 2.6, z = 1.2, yaw = -25, length = 8.5 },
		{ x = -5.4, z = 2.4, yaw = 50, length = 6.5 },
		{ x = 5.4, z = 2.2, yaw = -50, length = 7 },
		{ x = 0, z = 1.8, yaw = 0, length = 9.5 },
	}
	for _, r in roots do
		buildTentacle(model, base * CFrame.new(r.x, 0.4, r.z) * CFrame.Angles(0, math.rad(r.yaw), 0), r.length, color:Lerp(Color3.fromRGB(60, 20, 90), 0.4), glowColor)
	end
end

local PROP_BUILDERS: { [string]: (Model, CFrame, Color3) -> () } = {
	PearlClam = buildClamModel,
	CoralFarm = buildCoralModel,
	KelpFactory = buildKelpModel,
	SunkenVault = buildVaultModel,
	KrakenDen = buildKrakenModel,
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
	part({
		name = "StairwayBarrier",
		size = Vector3.new(cfg.width + 2, 24, 1),
		cframe = CFrame.new(0, 12, cfg.baseZ + 3),
		color = Color3.fromRGB(150, 200, 255),
		material = Enum.Material.ForceField,
		transparency = 0.3,
		parent = folder,
	})
	folder.Parent = parent
end

-- World-space plot frame for a stand in a zone.
local function plotFrame(zoneIndex: number, standId: string): (Vector3, Vector3, Vector3, Color3)
	local plot = Stations.PLOT_BY_STAND[standId]
	return Stations.toWorld(zoneIndex, plot.center), Stations.zoneDirection(zoneIndex, plot.forward), Stations.zoneDirection(zoneIndex, plot.right), plot.color
end

local function buildStand(zone: Zone, standId: string): Model
	local worldCenter, forward, _, color = plotFrame(zone.index, standId)
	local model = Instance.new("Model")
	model.Name = standId
	local floor = Stations.ZONE_TOP
	local center = Vector3.new(worldCenter.X, floor, worldCenter.Z)
	-- Local frame: -Z of `facing` points at the plaza.
	local facing = CFrame.lookAt(center, center + forward)
	local base = disc("Base", center, 16, 0.4, floor + 0.3, MARBLE, Enum.Material.Marble, model)
	disc("BaseRing", center, 16.8, 0.3, floor + 0.25, color, Enum.Material.Neon, model, false)
	model.PrimaryPart = base
	-- Builders work in a frame whose +Z faces the plaza, on top of the plot disc.
	local propFrame = facing * CFrame.new(0, 0.3, 0) * CFrame.Angles(0, math.pi, 0)
	local builder = PROP_BUILDERS[standId]
	if builder then
		builder(model, propFrame, color)
	end
	-- One invisible collider instead of colliding decor: cheap physics and no snagging.
	part({
		name = "Collider",
		size = Vector3.new(9, 12, 12),
		cframe = CFrame.new(center.X, floor + 0.3 + 4.5, center.Z) * CFrame.Angles(0, 0, math.rad(90)),
		color = Color3.new(1, 1, 1),
		shape = Enum.PartType.Cylinder,
		transparency = 1,
		parent = model,
	})
	model.Parent = zone.stands
	return model
end

-- Manager NPC (crab or mermaid). Static on the server; every client plays the work loop locally
-- on models tagged MANAGER_TAG (bouncy idle with hops). Parts named "Arm" wave.
local function buildManager(zone: Zone, standId: string): Model
	local def = Economy.STAND_BY_ID[standId]
	local worldCenter, forward, right = plotFrame(zone.index, standId)
	local model = Instance.new("Model")
	model.Name = "Manager_" .. standId
	-- Just outside the plot disc, clear of the business model's decor.
	local position = worldCenter + right * 9.5 + forward * 4
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
	pointLight(crystal, Color3.fromRGB(200, 140, 255), 18, 1.5)
	glow(crystal, 2.2)
	emitter(crystal, { rate = 3, color = Color3.fromRGB(230, 190, 255), size = 0.7, speed = 2, lifetime = 1.6, texture = SPARKLE_TEXTURE, spread = 180 })
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

	-- Flagpole beside the path at the plaza edge. The owner's name is shown in the 2D HUD
	-- (folder attribute OwnerName); the flag lights up in the zone colour while the reef is owned.
	local signPosition = Stations.toWorld(index, Vector3.new(6, 0, -(Stations.ZONE_PLAZA_RADIUS + 3)))
	local poleBase = CFrame.new(signPosition.X, Stations.ZONE_TOP, signPosition.Z)
	column(folder, "FlagPole", 10, 0.6, poleBase, MARBLE, Enum.Material.Marble)
	local flagGroup = group("Flag", folder)
	local flagRoot = poleBase * CFrame.new(0, 9.2, 0) * CFrame.Angles(0, Stations.zoneYaw(index), 0)
	local flag = deco(flagGroup, "Cloth", Vector3.new(4, 2.4, 0.2), flagRoot * CFrame.new(2.2, -1, 0), ZONE_FLAG_COLORS[index] or MARBLE, Enum.Material.Fabric)
	flag.Transparency = 0.6
	animate(flagGroup, flagRoot, "Sway", 1.4, 6)
	folder:SetAttribute("OwnerName", "")

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
		flag = flag,
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
			zone.folder:SetAttribute("OwnerName", player.DisplayName)
			zone.folder:SetAttribute("OwnerUserId", player.UserId)
			zone.flag.Transparency = 0
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
	zone.folder:SetAttribute("OwnerName", "")
	zone.folder:SetAttribute("OwnerUserId", 0)
	zone.flag.Transparency = 0.6
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
