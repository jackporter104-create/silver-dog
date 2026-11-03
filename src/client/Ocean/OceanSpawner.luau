--!strict
--[[
	OceanSpawner: procedural, progression-driven underwater environment (client-only visuals).

	Progression: every Evolution level adds fish, corals, kelp and bubbles, raises colour
	saturation and clears the water. Later levels add jellyfish, mantas, glowing fish and
	finally legendary whales. The active Season supplies the palette and the fog and tint colours.

	Mobile budget:
	  * A creature count cap derived from the device's graphics quality (lower on touch devices).
	  * All schools move with ONE Workspace:BulkMoveTo per frame instead of thousands of
	    property writes. Distance-banded update rates act as LOD (far fish update every 6th frame).
	  * Kelp sway and light-ray shimmer use TweenService (engine-side, no Lua per frame).
	  * Decor goes into designed zones (coral beds, a kelp rim) and Stations.isClearForDecor
	    keeps it out of walkways and stations, so the arena reads as a planned space.
	  * Every part is anchored with CanCollide, CanTouch, CanQuery and CastShadow all false.
	    Parts share primitive shapes and materials, so the engine can instance them.
	  * Particle emitters are few and low-rate. Bloom is skipped on mobile.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Seasons = require(Shared.Config.Seasons)
local Stations = require(Shared.Config.Stations)
local Evolution = require(Shared.Config.Evolution)

local StateController = require(script.Parent.Parent.Controllers.StateController)
local FishFactory = require(script.Parent.FishFactory)

type Creature = FishFactory.Creature

type Swimmer = {
	creature: Creature,
	mode: "Orbit" | "Bob",
	center: Vector3,
	radius: number,
	height: number,
	angularSpeed: number,
	phase: number,
	bobAmplitude: number,
	bobSpeed: number,
	offset: Vector3,
	lastPosition: Vector3,
}

local OceanSpawner = {}

local DECOR_SEED = 4242
local FISH_SEED = 777
local NEAR_DISTANCE = 90
local MID_DISTANCE = 180

local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local root: Folder
local decorFolder: Folder
local fishFolder: Folder
local swimmers: { Swimmer } = {}
local tweens: { Tween } = {}
local bulkParts: { BasePart } = {}
local bulkCFrames: { CFrame } = {}
local frame = 0
local currentLevel = 0
local currentSeason = ""

-- ===== Budget & progression =====

local function qualityLevel(): number
	local ok, level = pcall(function()
		return UserSettings():GetService("UserGameSettings").SavedQualityLevel
	end)
	if ok and level ~= Enum.SavedQualitySetting.Automatic then
		return level.Value
	end
	return 5
end

local function creatureBudget(): number
	local budget = 30 + qualityLevel() * 9
	return if isMobile then math.min(budget, 45) else budget
end

type Progression = {
	fish: number,
	corals: number,
	kelp: number,
	bubbles: number,
	vibrancy: number, -- 0 (dull) .. 1 (vivid)
	glowChance: number,
	kinds: { FishFactory.CreatureKind },
	whales: number,
	waterDensity: number,
}

local function progression(level: number): Progression
	local t = (level - 1) / math.max(Evolution.MAX_LEVEL - 1, 1)
	local budget = creatureBudget()
	local kinds: { FishFactory.CreatureKind } = { "Fish" }
	if level >= 2 then
		table.insert(kinds, "Tropical")
	end
	if level >= 4 then
		table.insert(kinds, "Manta")
	end
	return {
		fish = math.min(budget, 14 + (level - 1) * 10),
		corals = math.min(math.floor(budget * 0.8), 18 + level * 6),
		kelp = math.min(if isMobile then 14 else 30, 8 + level * 3),
		bubbles = math.min(if isMobile then 3 else 6, 2 + level // 2),
		vibrancy = t,
		glowChance = if level >= 8 then 0.5 elseif level >= 6 then 0.25 else 0,
		kinds = kinds,
		whales = if level >= 8 then 2 elseif level >= 7 then 1 else 0,
		waterDensity = 0.45 - 0.2 * t,
	}
end

local DULL = Color3.fromRGB(110, 130, 150)

local function vivid(color: Color3, vibrancy: number): Color3
	return color:Lerp(DULL, 0.6 * (1 - vibrancy))
end

-- ===== Helpers =====

local function decorPart(size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material
	p.Shape = shape or Enum.PartType.Block
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = decorFolder
	return p
end

local function loopTween(instance: Instance, info: TweenInfo, goal: { [string]: any })
	local tween = TweenService:Create(instance, info, goal)
	tween:Play()
	table.insert(tweens, tween)
end

-- Jittered point near `center` that keeps walkways, stations and the stairway clear.
local function nearPoint(rng: Random, center: Vector3, spread: number, footprint: number): Vector3?
	for _ = 1, 8 do
		local point = center + Vector3.new(rng:NextNumber(-spread, spread), 0, rng:NextNumber(-spread, spread))
		if Stations.isClearForDecor(point, footprint) then
			return point
		end
	end
	return nil
end

-- Coral bed centres in priority order. Progression fills them front to back, so the
-- arena gains framing accents first, then gaps between generators, then the outer rim.
local function bedCenters(): { Vector3 }
	local beds: { Vector3 } = {}
	-- Accents on the inner ring framing the axis lanes and the clam/station pairs.
	for _, angle in { 25, 335, 155, 205, 90, 270 } do
		table.insert(beds, Stations.polar(angle, Stations.INNER_RING_RADIUS))
	end
	-- Between neighbouring generators on the outer ring.
	for _, angle in { 52.5, 307.5, 77.5, 282.5, 102.5, 257.5, 127.5, 232.5 } do
		table.insert(beds, Stations.polar(angle, Stations.OUTER_RING_RADIUS))
	end
	-- Outer rim, every 20 degrees (the stairway gap is filtered by isClearForDecor).
	for angle = 10, 350, 20 do
		table.insert(beds, Stations.polar(angle, 124))
	end
	return beds
end

-- ===== Atmosphere =====

local function ensure<T>(className: string, name: string, parent: Instance): T
	local existing = parent:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return (existing :: any) :: T
	end
	local created = Instance.new(className :: any)
	created.Name = name
	created.Parent = parent
	return (created :: any) :: T
end

local function applyAtmosphere(theme: Types.SeasonTheme, p: Progression)
	Lighting.Ambient = theme.ambient
	Lighting.OutdoorAmbient = theme.ambient
	Lighting.ClockTime = 13
	Lighting.Brightness = 2
	Lighting.GlobalShadows = not isMobile

	local atmosphere: Atmosphere = ensure("Atmosphere", "OceanAtmosphere", Lighting)
	atmosphere.Density = p.waterDensity
	atmosphere.Offset = 0.1
	atmosphere.Color = theme.fogColor
	atmosphere.Decay = theme.fogColor:Lerp(Color3.new(0, 0, 0), 0.5)
	atmosphere.Glare = 0
	atmosphere.Haze = 2

	local correction: ColorCorrectionEffect = ensure("ColorCorrectionEffect", "OceanTint", Lighting)
	correction.TintColor = theme.waterTint
	correction.Saturation = -0.3 + 0.6 * p.vibrancy
	correction.Contrast = 0.05

	if not isMobile then
		local bloom: BloomEffect = ensure("BloomEffect", "OceanBloom", Lighting)
		-- Gentle bloom: a high threshold keeps neon pads and orbs from smearing into streaks.
		bloom.Intensity = 0.25 + 0.25 * p.vibrancy
		bloom.Size = 18
		bloom.Threshold = 2.2
	end

	local arena = Workspace:FindFirstChild("OceanArena")
	local floor = arena and arena:FindFirstChild("SeaFloor")
	if floor and floor:IsA("BasePart") then
		floor.Color = theme.floorColor
	end
end

-- ===== Decor =====

local function spawnCoral(rng: Random, position: Vector3, palette: { Color3 }, vibrancy: number)
	local color = vivid(palette[rng:NextInteger(1, #palette)], vibrancy)
	local style = rng:NextInteger(1, 3)
	local base = CFrame.new(position)
	if style == 1 then
		-- Branching coral: a few tilted cylinders tipped with balls.
		for _ = 1, rng:NextInteger(3, 5) do
			local height = rng:NextNumber(3, 7)
			local tilt = CFrame.Angles(rng:NextNumber(-0.5, 0.5), rng:NextNumber(0, math.pi * 2), rng:NextNumber(-0.5, 0.5))
			local stem = base * tilt * CFrame.new(0, height / 2, 0)
			decorPart(Vector3.new(height, 0.8, 0.8), stem * CFrame.Angles(0, 0, math.rad(90)), color, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
			decorPart(Vector3.new(1.4, 1.4, 1.4), stem * CFrame.new(0, height / 2, 0), color:Lerp(Color3.new(1, 1, 1), 0.3), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		end
	elseif style == 2 then
		-- Brain coral dome.
		local size = rng:NextNumber(3, 6)
		decorPart(Vector3.new(size, size, size), base * CFrame.new(0, size * 0.2, 0), color, Enum.Material.Pebble, Enum.PartType.Ball)
	else
		-- Tube sponge cluster.
		for _ = 1, rng:NextInteger(2, 4) do
			local height = rng:NextNumber(2, 5)
			local offset = Vector3.new(rng:NextNumber(-1.5, 1.5), height / 2, rng:NextNumber(-1.5, 1.5))
			decorPart(Vector3.new(height, 1.2, 1.2), CFrame.new(position + offset) * CFrame.Angles(0, 0, math.rad(90)), color, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		end
	end
end

local function spawnKelp(rng: Random, position: Vector3, vibrancy: number)
	local height = rng:NextNumber(10, 22)
	local color = vivid(Color3.fromRGB(60, 170, 90), vibrancy)
	local pivot = CFrame.new(position) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	local blade = decorPart(Vector3.new(0.8, height, 0.25), pivot * CFrame.Angles(0, 0, -0.1) * CFrame.new(0, height / 2, 0), color, Enum.Material.SmoothPlastic)
	loopTween(
		blade,
		TweenInfo.new(rng:NextNumber(2.5, 4), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ CFrame = pivot * CFrame.Angles(0, 0, 0.1) * CFrame.new(0, height / 2, 0) }
	)
end

local function spawnBubbles(position: Vector3, color: Color3)
	local vent = decorPart(Vector3.new(2, 1, 2), CFrame.new(position + Vector3.new(0, 0.3, 0)), Color3.fromRGB(80, 80, 90), Enum.Material.Slate, Enum.PartType.Ball)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = if isMobile then 2 else 4
	emitter.Lifetime = NumberRange.new(6, 9)
	emitter.Speed = NumberRange.new(4, 7)
	emitter.SpreadAngle = Vector2.new(12, 12)
	emitter.Acceleration = Vector3.new(0, 1.2, 0)
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0.9) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 0.6
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Parent = vent
end

type LightRay = { part: Part, center: Vector3, axis: Vector3 }
local lightRays: { LightRay } = {}
local RAY_HIDE_DISTANCE = 22
local RAY_FADE_DISTANCE = 30

-- Faint neon sheets high above the arena. Their base stays above head height, and each
-- frame step() fades any sheet the camera gets close to. A camera passing through a
-- glowing sheet is what produced the white flicker streaks.
local function spawnLightRays(rng: Random, color: Color3, count: number)
	for i = 1, count do
		local angle = (i / count) * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		local radius = rng:NextNumber(50, 120)
		local length = 140
		local center = Vector3.new(math.cos(angle) * radius, 30 + length / 2, math.sin(angle) * radius)
		local cframe = CFrame.new(center) * CFrame.Angles(0, rng:NextNumber(0, math.pi), math.rad(rng:NextNumber(6, 14)))
		local ray = decorPart(Vector3.new(rng:NextNumber(6, 12), length, 0.2), cframe, color, Enum.Material.Neon)
		ray.Transparency = 0.93
		loopTween(ray, TweenInfo.new(rng:NextNumber(3, 6), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.98 })
		table.insert(lightRays, { part = ray, center = center, axis = cframe.UpVector * (length / 2) })
	end
end

local function fadeLightRays(cameraPosition: Vector3)
	for _, ray in lightRays do
		-- Distance from the camera to the sheet's long axis segment.
		local axisLengthSq = ray.axis:Dot(ray.axis)
		local t = math.clamp((cameraPosition - ray.center):Dot(ray.axis) / axisLengthSq, -1, 1)
		local distance = (cameraPosition - (ray.center + ray.axis * t)).Magnitude
		ray.part.LocalTransparencyModifier = math.clamp((RAY_HIDE_DISTANCE + RAY_FADE_DISTANCE - distance) / RAY_FADE_DISTANCE, 0, 1)
	end
end

local function spawnRock(rng: Random, point: Vector3)
	local size = rng:NextNumber(5, 10)
	decorPart(Vector3.new(size, size, size), CFrame.new(point + Vector3.new(0, size * 0.15, 0)), Color3.fromRGB(95, 100, 110), Enum.Material.Slate, Enum.PartType.Ball)
end

local function spawnDecor(theme: Types.SeasonTheme, p: Progression)
	local rng = Random.new(DECOR_SEED)
	local beds = bedCenters()

	-- Coral beds: 2-4 corals around each bed centre, until the progression budget is used.
	local placed = 0
	for _, bed in beds do
		if placed >= p.corals then
			break
		end
		for _ = 1, rng:NextInteger(2, 4) do
			local point = nearPoint(rng, bed, 5, 3)
			if point and placed < p.corals then
				spawnCoral(rng, point, theme.coralPalette, p.vibrancy)
				placed += 1
			end
		end
	end

	-- Kelp forest ringing the arena edge, framing the play space as a backdrop.
	for i = 1, p.kelp do
		local angle = (i / p.kelp) * 360 + rng:NextNumber(-4, 4)
		local point = Stations.polar(angle, rng:NextNumber(120, 133))
		if Stations.isClearForDecor(point, 1) then
			spawnKelp(rng, point, p.vibrancy)
		end
	end

	-- Boulders tucked into the rim between kelp.
	for i = 1, 12 do
		local point = Stations.polar(i * 30 + 15 + rng:NextNumber(-5, 5), rng:NextNumber(126, 131))
		if Stations.isClearForDecor(point, 4) then
			spawnRock(rng, point)
		end
	end

	-- Bubble vents in the gaps between generators (bed list entries 7..14).
	for i = 1, p.bubbles do
		local bed = beds[6 + i]
		if bed then
			local point = nearPoint(rng, bed, 3, 2)
			if point then
				spawnBubbles(point, theme.bubbleColor)
			end
		end
	end
	spawnLightRays(rng, theme.lightRayColor, if isMobile then 3 else 6)
end

-- ===== Creatures =====

local function addSwimmer(creature: Creature, swimmer: Swimmer)
	creature.model.Parent = fishFolder
	table.insert(swimmers, swimmer)
end

local function spawnCreatures(theme: Types.SeasonTheme, p: Progression, level: number)
	local rng = Random.new(FISH_SEED + level)
	local remaining = p.fish
	while remaining > 0 do
		local kind: FishFactory.CreatureKind = p.kinds[rng:NextInteger(1, #p.kinds)]
		local schoolSize = if kind == "Manta" then 1 else math.min(remaining, rng:NextInteger(3, 7))
		local color = vivid(theme.fishPalette[rng:NextInteger(1, #theme.fishPalette)], p.vibrancy)
		local glowing = rng:NextNumber() < p.glowChance
		-- Above station signs (~14 studs) and player cameras, below the light-ray bases.
		local radius = rng:NextNumber(30, Stations.FLOOR_RADIUS - 10)
		local height = rng:NextNumber(20, 42)
		local speed = rng:NextNumber(4, 9) * (if rng:NextNumber() < 0.5 then -1 else 1)
		local phase = rng:NextNumber(0, math.pi * 2)
		for _ = 1, schoolSize do
			local size = if kind == "Manta" then rng:NextNumber(2.5, 3.5) else rng:NextNumber(1.2, 2)
			local creature = FishFactory.build(kind, color, size, glowing)
			addSwimmer(creature, {
				creature = creature,
				mode = "Orbit",
				center = Vector3.zero,
				radius = radius,
				height = height,
				angularSpeed = speed / radius,
				phase = phase,
				bobAmplitude = rng:NextNumber(0.5, 2),
				bobSpeed = rng:NextNumber(0.5, 1.2),
				offset = Vector3.new(rng:NextNumber(-3, 3), rng:NextNumber(-2, 2), rng:NextNumber(-3, 3)),
				lastPosition = Vector3.zero,
			})
		end
		remaining -= schoolSize
	end

	local jellyBeds = bedCenters()
	if level >= 3 then
		for _ = 1, math.min(4 + level, 12) do
			local point = jellyBeds[rng:NextInteger(1, #jellyBeds)]
			local creature = FishFactory.build("Jelly", vivid(theme.fishPalette[rng:NextInteger(1, #theme.fishPalette)], p.vibrancy), rng:NextNumber(1, 1.8), true)
			addSwimmer(creature, {
				creature = creature,
				mode = "Bob",
				center = point + Vector3.new(0, rng:NextNumber(20, 36), 0),
				radius = 0,
				height = 0,
				angularSpeed = 0,
				phase = rng:NextNumber(0, math.pi * 2),
				bobAmplitude = rng:NextNumber(2, 4),
				bobSpeed = rng:NextNumber(0.4, 0.8),
				offset = Vector3.zero,
				lastPosition = point,
			})
		end
	end

	for i = 1, p.whales do
		local creature = FishFactory.build("Whale", Color3.fromRGB(120, 170, 255):Lerp(Color3.fromRGB(255, 230, 150), (i - 1) * 0.6), 3, level >= 8)
		addSwimmer(creature, {
			creature = creature,
			mode = "Orbit",
			center = Vector3.zero,
			radius = 170 + i * 25,
			height = 100 + i * 10, -- well above the statue platform (y 56)
			angularSpeed = 3 / (170 + i * 25),
			phase = i * math.pi,
			bobAmplitude = 3,
			bobSpeed = 0.2,
			offset = Vector3.zero,
			lastPosition = Vector3.zero,
		})
	end
end

-- ===== Per-frame animation (one BulkMoveTo) =====

local function step()
	frame += 1
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else Vector3.zero
	fadeLightRays(cameraPosition)
	local t = os.clock()
	table.clear(bulkParts)
	table.clear(bulkCFrames)

	for index, s in swimmers do
		local distance = (s.lastPosition - cameraPosition).Magnitude
		local interval = if distance < NEAR_DISTANCE then 1 elseif distance < MID_DISTANCE then 3 else 6
		if (frame + index) % interval ~= 0 then
			continue
		end

		local rootCFrame: CFrame
		if s.mode == "Bob" then
			local position = s.center + Vector3.new(0, math.sin(t * s.bobSpeed + s.phase) * s.bobAmplitude, 0)
			rootCFrame = CFrame.new(position) * CFrame.Angles(0, t * 0.2 + s.phase, 0)
			s.lastPosition = position
		else
			local theta = s.phase + s.angularSpeed * t
			local direction = if s.angularSpeed >= 0 then 1 else -1
			local position = s.center
				+ Vector3.new(math.cos(theta) * s.radius, s.height + math.sin(t * s.bobSpeed + s.phase) * s.bobAmplitude, math.sin(theta) * s.radius)
				+ s.offset
			local tangent = Vector3.new(-math.sin(theta), 0, math.cos(theta)) * direction
			rootCFrame = CFrame.lookAt(position, position + tangent)
			s.lastPosition = position
		end

		local creature = s.creature
		local wag = math.sin(t * (if creature.kind == "Whale" then 1.5 else 9) + s.phase) * 0.35
		for i, part in creature.parts do
			local cf = rootCFrame * creature.offsets[i]
			if i == creature.tailIndex then
				cf *= CFrame.Angles(0, wag, 0)
			end
			table.insert(bulkParts, part)
			table.insert(bulkCFrames, cf)
		end
	end

	if #bulkParts > 0 then
		Workspace:BulkMoveTo(bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- ===== Rebuild on progression / season change =====

local function rebuild(level: number, seasonId: string)
	if level == currentLevel and seasonId == currentSeason then
		return
	end
	currentLevel, currentSeason = level, seasonId
	for _, tween in tweens do
		tween:Cancel()
	end
	table.clear(tweens)
	table.clear(swimmers)
	table.clear(lightRays)
	decorFolder:ClearAllChildren()
	fishFolder:ClearAllChildren()

	local theme = Seasons.get(seasonId).theme
	local p = progression(level)
	applyAtmosphere(theme, p)
	spawnDecor(theme, p)
	spawnCreatures(theme, p, level)
end

local function seasonAttribute(): string
	local value = ReplicatedStorage:GetAttribute("SeasonId")
	return if typeof(value) == "string" then value else Seasons.DEFAULT_ID
end

function OceanSpawner.init()
	root = Instance.new("Folder")
	root.Name = "OceanVisuals"
	decorFolder = Instance.new("Folder")
	decorFolder.Name = "Decor"
	decorFolder.Parent = root
	fishFolder = Instance.new("Folder")
	fishFolder.Name = "Creatures"
	fishFolder.Parent = root
	root.Parent = Workspace

	rebuild(1, seasonAttribute())
	StateController.snapshotChanged:Connect(function(snap: Types.Snapshot)
		rebuild(snap.evolution.level, snap.seasonId)
	end)
	ReplicatedStorage:GetAttributeChangedSignal("SeasonId"):Connect(function()
		rebuild(currentLevel, seasonAttribute())
	end)
	RunService.Heartbeat:Connect(step)
end

return OceanSpawner
