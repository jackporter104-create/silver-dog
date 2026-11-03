--!strict
--[[
	WorldController: client-side life for the server-built world. No 3D text anywhere.

	  * Animator: every Model tagged "OceanAnim" (clam lids, gears, corals, kelp, tentacles, pearls,
	    pad icons, flags) moves with one Workspace:BulkMoveTo per frame, with distance LOD.
	  * Managers (tag "OceanManager"): exaggerated idle with a bouncy walk-in-place, waving arms and
	    a spinning hop every few seconds.
	  * Glow (tag "OceanGlow"): TweenService loops pulse lights and neon parts.
	  * Juice: pads squish when stepped on, coins burst from your stands on every payout, and new
	    businesses (anyone's) appear with sparkles, bubbles and a highlight flash.
	  * Own reef: buff pads dim while recharging. Statues and the stairway barrier follow the snapshot.
	All of this is local: the server never replicates per-frame motion.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Economy = require(Shared.Config.Economy)
local Stations = require(Shared.Config.Stations)
local Statues = require(Shared.Config.Statues)

local StateController = require(script.Parent.StateController)
local StationController = require(script.Parent.StationController)
local StandTracker = require(script.Parent.StandTracker)

type StationDef = Stations.StationDef

local WorldController = {}

-- Must match ArenaService.ANIM_TAG / GLOW_TAG / MANAGER_TAG.
local ANIM_TAG = "OceanAnim"
local GLOW_TAG = "OceanGlow"
local MANAGER_TAG = "OceanManager"

local NEAR_DISTANCE = 70
local FAR_DISTANCE = 180 -- beyond this nothing animates
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local GOLD = Color3.fromRGB(255, 200, 60)

type Animated = {
	model: Model,
	kind: string,
	speed: number,
	amp: number,
	phase: number,
	pivot: CFrame,
	parts: { BasePart },
	offsets: { CFrame },
	arms: { [number]: boolean }?, -- managers only
}

local player = Players.LocalPlayer
local animated: { [Model]: Animated } = {}
local ownPads: { [string]: Model } = {}
local ownStands: { [string]: Model } = {}
local coinEmitters: { [Model]: ParticleEmitter } = {}
local builtStatues: { [string]: Model } = {}
local zoneConnections: { RBXScriptConnection } = {}
local visuals: Folder
local attachedAt = math.huge
local frame = 0

-- ===== Animator =====

local function capture(model: Model, kind: string, speed: number, amp: number, phase: number, collectArms: boolean): Animated
	local stored = model:GetAttribute("AnimPivot")
	local pivot = if typeof(stored) == "CFrame" then stored else model:GetPivot()
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local arms: { [number]: boolean }? = if collectArms then {} else nil
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			table.insert(offsets, pivot:ToObjectSpace(d.CFrame))
			if arms and d.Name == "Arm" then
				arms[#parts] = true
			end
		end
	end
	return { model = model, kind = kind, speed = speed, amp = amp, phase = phase, pivot = pivot, parts = parts, offsets = offsets, arms = arms }
end

local function numberAttribute(instance: Instance, name: string, fallback: number): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else fallback
end

local function trackAnimated(instance: Instance)
	if not instance:IsA("Model") or animated[instance] then
		return
	end
	-- Parts replicate right after the model; wait a frame so the capture sees all of them.
	task.defer(function()
		if not instance.Parent then
			return
		end
		local kind = instance:GetAttribute("Anim")
		animated[instance] = capture(
			instance,
			if typeof(kind) == "string" then kind else "Float",
			numberAttribute(instance, "AnimSpeed", 1),
			numberAttribute(instance, "AnimAmp", 0),
			numberAttribute(instance, "AnimPhase", 0),
			false
		)
	end)
end

local function trackManager(instance: Instance)
	if not instance:IsA("Model") or animated[instance] then
		return
	end
	task.defer(function()
		if instance.Parent then
			animated[instance] = capture(instance, "Manager", 1, 0, math.random() * 4, true)
		end
	end)
end

local function untrack(instance: Instance)
	if instance:IsA("Model") then
		animated[instance] = nil
	end
end

-- Transform of the pivot for one animation kind at time t.
local function pose(a: Animated, t: number): CFrame
	local kind, speed, amp, phase = a.kind, a.speed, a.amp, a.phase
	local wave = t * speed + phase
	if kind == "Hinge" then
		return CFrame.Angles(math.rad(amp) * math.sin(wave), 0, 0)
	elseif kind == "Spin" then
		return CFrame.Angles(0, wave, 0)
	elseif kind == "Sway" then
		return CFrame.Angles(math.rad(amp) * math.sin(wave), 0, math.rad(amp * 0.7) * math.sin(wave * 0.8 + 1.3))
	elseif kind == "Bounce" then
		return CFrame.new(0, amp * math.abs(math.sin(wave)), 0)
	elseif kind == "Float" then
		return CFrame.new(0, amp * math.sin(wave), 0) * CFrame.Angles(0, t * 0.9 + phase, 0)
	elseif kind == "Manager" then
		-- Bouncy idle, a lean from side to side, and every 4 s a big spinning hop.
		local cycle = (t + phase) % 4
		local hop = if cycle < 0.7 then cycle / 0.7 else 0
		local height = math.abs(math.sin(t * 5 + phase)) * 0.45 + math.sin(math.pi * hop) * 2.6
		local spin = if hop > 0 then (1 - math.cos(math.pi * hop)) * math.pi else 0
		return CFrame.new(0, height, 0) * CFrame.Angles(0, spin + math.sin(t * 1.6 + phase) * 0.3, math.sin(t * 2.5 + phase) * 0.18)
	end
	return CFrame.identity
end

local bulkParts: { BasePart } = {}
local bulkCFrames: { CFrame } = {}

local function animateAll()
	frame += 1
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else Vector3.zero
	local t = os.clock()
	table.clear(bulkParts)
	table.clear(bulkCFrames)
	local index = 0
	for model, a in animated do
		index += 1
		if not model.Parent then
			animated[model] = nil
			continue
		end
		local distance = (a.pivot.Position - cameraPosition).Magnitude
		if distance > FAR_DISTANCE then
			continue
		end
		-- Distance LOD: far animations update every third frame.
		if distance > NEAR_DISTANCE and (frame + index) % 3 ~= 0 then
			continue
		end
		local root = a.pivot * pose(a, t)
		local arms = a.arms
		local armSwing = if arms then CFrame.Angles(math.sin(t * 7 + a.phase) * 0.9, 0, 0) else nil
		for i, p in a.parts do
			local cf = root * a.offsets[i]
			if arms and armSwing and arms[i] then
				cf *= armSwing
			end
			table.insert(bulkParts, p)
			table.insert(bulkCFrames, cf)
		end
	end
	if #bulkParts > 0 then
		Workspace:BulkMoveTo(bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- ===== Glow (TweenService loops) =====

local function startGlow(instance: Instance)
	local period = instance:GetAttribute("GlowPeriod")
	local duration = if typeof(period) == "number" then period / 2 else 1.2
	local info = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, math.random() * duration)
	if instance:IsA("PointLight") then
		TweenService:Create(instance, info, { Brightness = instance.Brightness * 0.45 }):Play()
	elseif instance:IsA("BasePart") then
		TweenService:Create(instance, info, { Transparency = math.min(instance.Transparency + 0.35, 1) }):Play()
	end
end

-- ===== Juice =====

local function burst(position: Vector3, color: Color3, count: number, texture: string?, upward: boolean?)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(position)
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	e.Lifetime = NumberRange.new(0.8, 1.4)
	e.Speed = NumberRange.new(8, 16)
	e.SpreadAngle = if upward then Vector2.new(35, 35) else Vector2.new(180, 180)
	e.Acceleration = if upward then Vector3.new(0, -25, 0) else Vector3.zero
	e.EmissionDirection = Enum.NormalId.Top
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) })
	e.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
	e.LightEmission = 0.8
	if texture then
		e.Texture = texture
	end
	e.Parent = anchor
	anchor.Parent = visuals
	e:Emit(count)
	task.delay(2, function()
		anchor:Destroy()
	end)
end

-- A reusable gold-coin fountain above one of the player's stands.
local function coinEmitter(model: Model): ParticleEmitter?
	local existing = coinEmitters[model]
	if existing and existing.Parent then
		return existing
	end
	local base = model.PrimaryPart
	if not base then
		return nil
	end
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(2, 1, 2)
	anchor.CFrame = base.CFrame * CFrame.new(0, 7, 0)
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	e.Lifetime = NumberRange.new(0.9, 1.3)
	e.Speed = NumberRange.new(10, 16)
	e.SpreadAngle = Vector2.new(30, 30)
	e.EmissionDirection = Enum.NormalId.Top
	e.Acceleration = Vector3.new(0, -35, 0)
	e.RotSpeed = NumberRange.new(-180, 180)
	e.Size = NumberSequence.new(0.7)
	e.Color = ColorSequence.new(GOLD)
	e.LightEmission = 0.4
	e.Parent = anchor
	anchor.Parent = visuals
	coinEmitters[model] = e
	model.AncestryChanged:Connect(function()
		if not model.Parent then
			anchor:Destroy()
			coinEmitters[model] = nil
		end
	end)
	return e
end

local function onPayout(payout: StandTracker.Payout)
	local model = ownStands[payout.standId]
	local e = model and coinEmitter(model)
	if e then
		e:Emit(6)
	end
end

local function pressPad(station: StationDef)
	local model: Model? = ownPads[station.id]
	if not model then
		local arena = Workspace:FindFirstChild("OceanArena")
		local hub = arena and arena:FindFirstChild("Hub")
		local hubStations = hub and hub:FindFirstChild("Stations")
		local found = hubStations and hubStations:FindFirstChild(station.id)
		model = if found and found:IsA("Model") then found else nil
	end
	local inlay = model and model:FindFirstChild("Inlay")
	if not inlay or not inlay:IsA("BasePart") then
		return
	end
	local rest = inlay.CFrame
	inlay.CFrame = rest * CFrame.new(-0.12, 0, 0) -- cylinders run along X: local -X is down
	TweenService:Create(inlay, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = rest }):Play()
	burst(rest.Position + Vector3.new(0, 0.5, 0), station.color, 12, SPARKLE_TEXTURE, true)
end

-- Sparkles, bubbles and a highlight flash when any business appears (skipped on join).
local function celebrate(model: Model)
	if os.clock() - attachedAt < 3 then
		return
	end
	local plot = Stations.PLOT_BY_STAND[model.Name]
	local color = if plot then plot.color else Color3.new(1, 1, 1)
	local pivot = model:GetPivot().Position
	burst(pivot + Vector3.new(0, 4, 0), color, 40, SPARKLE_TEXTURE)
	burst(pivot + Vector3.new(0, 1, 0), Color3.fromRGB(210, 240, 255), 25, nil, true)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = color
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.2
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = model
	highlight.Parent = visuals
	local fade = TweenService:Create(highlight, TweenInfo.new(1.6, Enum.EasingStyle.Quad), { FillTransparency = 1, OutlineTransparency = 1 })
	fade:Play()
	fade.Completed:Connect(function()
		highlight:Destroy()
	end)
end

-- ===== Own reef state =====

local function refreshPads()
	local snap = StateController.snapshot()
	if not snap then
		return
	end
	for id, model in ownPads do
		if not model.Parent then
			ownPads[id] = nil
			continue
		end
		local station = Stations.BY_ID[id]
		if station and station.kind == "Buff" then
			local buff = snap.buffs[station.target or ""]
			local recharging = buff ~= nil and StateController.remaining(buff.activeRemaining) <= 0 and StateController.remaining(buff.cooldownRemaining) > 0
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") then
					d.LocalTransparencyModifier = if recharging then 0.55 else 0
				end
			end
		end
	end
end

-- ===== Statues & stairway =====

local function buildStatue(statueId: string, position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "Statue_" .. statueId
	local gold = Color3.fromRGB(255, 205, 90)
	local function add(size: Vector3, cframe: CFrame, shape: Enum.PartType?, material: Enum.Material?): Part
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Size = size
		p.CFrame = cframe
		p.Shape = shape or Enum.PartType.Block
		p.Material = material or Enum.Material.Foil
		p.Color = gold
		p.Parent = model
		return p
	end
	-- Pedestal sits on the pad inlay (top at +0.55).
	local base = CFrame.new(position + Vector3.new(0, 0.55, 0))
	add(Vector3.new(4.4, 2, 4.4), base * CFrame.new(0, 1, 0), nil, Enum.Material.Marble)
	-- A leaping golden fish.
	local body = add(Vector3.new(4, 4, 4), base * CFrame.new(0, 6.3, 0), Enum.PartType.Ball)
	add(Vector3.new(3, 3, 3), base * CFrame.new(0, 8.8, -1.5), Enum.PartType.Ball)
	add(Vector3.new(1, 4, 3), base * CFrame.new(0, 3.3, 2) * CFrame.Angles(math.rad(35), 0, 0))
	add(Vector3.new(0.6, 2, 2), base * CFrame.new(1.8, 6.3, 0) * CFrame.Angles(0, 0, math.rad(25)))
	add(Vector3.new(0.6, 2, 2), base * CFrame.new(-1.8, 6.3, 0) * CFrame.Angles(0, 0, math.rad(-25)))
	local light = Instance.new("PointLight")
	light.Color = gold
	light.Range = 16
	light.Brightness = 2
	light.Parent = body
	startGlow(light)
	model.Parent = visuals
	return model
end

local function onSnapshot(snap: Types.Snapshot)
	for _, statue in Statues.LIST do
		if snap.statues[statue.id] and not builtStatues[statue.id] then
			local station = Stations.BY_ID["Statue_" .. statue.id]
			if station then
				local model = buildStatue(statue.id, station.position)
				builtStatues[statue.id] = model
				celebrate(model)
			end
		elseif not snap.statues[statue.id] and builtStatues[statue.id] then
			builtStatues[statue.id]:Destroy()
			builtStatues[statue.id] = nil
		end
	end
	local arena = Workspace:FindFirstChild("OceanArena")
	local hub = arena and arena:FindFirstChild("Hub")
	local stairway = hub and hub:FindFirstChild("HeavenlyStairway")
	local barrier = stairway and stairway:FindFirstChild("StairwayBarrier")
	if barrier and barrier:IsA("BasePart") then
		local open = snap.stairwayUnlocked
		if open and barrier.CanCollide then
			TweenService:Create(barrier, TweenInfo.new(1.5), { Transparency = 1 }):Play()
		end
		barrier.CanCollide = not open
	end
	refreshPads()
end

-- ===== Attaching to server-built instances =====

local function watchZones(zones: Instance)
	local function hookZone(zone: Instance)
		local standsFolder = zone:WaitForChild("Stands", 30)
		if not standsFolder then
			return
		end
		standsFolder.ChildAdded:Connect(function(child)
			if child:IsA("Model") and Economy.STAND_BY_ID[child.Name] then
				task.defer(celebrate, child)
			end
		end)
	end
	for _, zone in zones:GetChildren() do
		task.spawn(hookZone, zone)
	end
	zones.ChildAdded:Connect(hookZone)
end

local function attachOwnZone(zones: Instance)
	for _, connection in zoneConnections do
		connection:Disconnect()
	end
	table.clear(zoneConnections)
	table.clear(ownPads)
	table.clear(ownStands)
	local zoneIndex = player:GetAttribute("ZoneIndex")
	if typeof(zoneIndex) ~= "number" then
		return
	end
	local zone = zones:WaitForChild("Zone" .. zoneIndex, 30)
	local stationsFolder = zone and zone:WaitForChild("Stations", 30)
	local standsFolder = zone and zone:WaitForChild("Stands", 30)
	if not stationsFolder or not standsFolder then
		warn("[WorldController] Own zone not found")
		return
	end
	local function addPad(child: Instance)
		if child:IsA("Model") and Stations.BY_ID[child.Name] then
			ownPads[child.Name] = child
		end
	end
	local function addStand(child: Instance)
		if child:IsA("Model") and Economy.STAND_BY_ID[child.Name] then
			ownStands[child.Name] = child
		end
	end
	for _, child in stationsFolder:GetChildren() do
		addPad(child)
	end
	for _, child in standsFolder:GetChildren() do
		addStand(child)
	end
	table.insert(zoneConnections, stationsFolder.ChildAdded:Connect(addPad))
	table.insert(zoneConnections, standsFolder.ChildAdded:Connect(addStand))
end

local function attachArena(arena: Instance)
	local zones = arena:WaitForChild("Zones", 30)
	if not zones then
		warn("[WorldController] Zones not found")
		return
	end
	watchZones(zones)
	attachOwnZone(zones)
	player:GetAttributeChangedSignal("ZoneIndex"):Connect(function()
		attachOwnZone(zones)
	end)
	attachedAt = os.clock()
	local snap = StateController.snapshot()
	if snap then
		onSnapshot(snap)
	end
end

local function bindTag(tag: string, added: (Instance) -> (), removed: ((Instance) -> ())?)
	for _, instance in CollectionService:GetTagged(tag) do
		added(instance)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(added)
	if removed then
		CollectionService:GetInstanceRemovedSignal(tag):Connect(removed)
	end
end

function WorldController.init()
	visuals = Instance.new("Folder")
	visuals.Name = "LocalArenaVisuals"
	visuals.Parent = Workspace

	task.spawn(function()
		local arena = Workspace:WaitForChild("OceanArena", 60)
		if arena then
			attachArena(arena)
		else
			warn("[WorldController] Arena not found")
		end
	end)

	bindTag(ANIM_TAG, trackAnimated, untrack)
	bindTag(MANAGER_TAG, trackManager, untrack)
	bindTag(GLOW_TAG, startGlow)

	StateController.snapshotChanged:Connect(onSnapshot)
	StandTracker.payout:Connect(onPayout)
	StationController.stepped:Connect(pressPad)
	RunService.Heartbeat:Connect(animateAll)
	task.spawn(function()
		while true do
			task.wait(0.5)
			refreshPads()
		end
	end)
end

return WorldController
