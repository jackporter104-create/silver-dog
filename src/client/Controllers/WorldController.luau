--!strict
--[[
	WorldController: per-player 3D presentation on top of the server-built world.

	  * Own zone and Hub pads: an info row on each pad's sign (price, level, cooldown) at 4 Hz.
	    Pads appear and disappear as the server reveals them, so rows attach on ChildAdded.
	    Other players' pads keep only their server title: prices stay private.
	  * Own stands: a progress bar over each counter and "+value" pops when a cycle pays out,
	    plus the stand's income on its sign.
	  * Every zone: manager NPCs (tagged by the server) play a looping work animation locally,
	    with distance LOD. Newly bought structures get a sparkle burst.
	  * Golden statues on the player's own statue pads, and the Heavenly Stairway barrier opening.
	Character physics are client-owned, so opening the barrier locally lets the player pass.
	Statue purchases are still validated by the server.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BigNumber = require(Shared.BigNumber)
local NumberFormat = require(Shared.NumberFormat)
local Types = require(Shared.Types)
local Economy = require(Shared.Config.Economy)
local Stations = require(Shared.Config.Stations)
local Statues = require(Shared.Config.Statues)

local StateController = require(script.Parent.StateController)

type StationDef = Stations.StationDef
type BigNumber = BigNumber.BigNumber

local WorldController = {}

local MANAGER_TAG = "OceanManager" -- must match ArenaService.MANAGER_TAG

type Label = { station: StationDef, text: TextLabel, parts: { BasePart } }
type StandVisual = {
	standId: string,
	model: Model,
	sign: TextLabel?,
	fill: Frame?,
	barGui: BillboardGui?,
	counter: BasePart?,
	cycleStart: number?,
	cycleEnd: number?,
	cycleValue: BigNumber?,
	loopPhase: number, -- managed stands: server-time origin of the visual loop
}
type Npc = { model: Model, parts: { BasePart }, offsets: { CFrame }, arms: { [number]: boolean }, root: CFrame, phase: number }

local player = Players.LocalPlayer
local labels: { [Instance]: Label } = {}
local stands: { [string]: StandVisual } = {}
local npcs: { [Model]: Npc } = {}
local builtStatues: { [string]: Model } = {}
local zoneConnections: { RBXScriptConnection } = {}
local visuals: Folder
local popupCount = 0
local attachedAt = math.huge

local AFFORDABLE = Color3.fromRGB(110, 255, 160)
local NORMAL = Color3.fromRGB(255, 255, 255)
local LOCKED = Color3.fromRGB(160, 170, 185)
local ACTIVE = Color3.fromRGB(255, 220, 90)
local MAX_POPUPS = 10
local MIN_POP_INTERVAL = 0.8 -- managed stands faster than this show a steady bar instead of pops
local NPC_ANIMATE_DISTANCE = 160

local function fmt(x: BigNumber): string
	return NumberFormat.format(x)
end

local function secondsText(seconds: number): string
	seconds = math.ceil(seconds)
	if seconds >= 60 then
		return string.format("%dm %02ds", seconds // 60, seconds % 60)
	end
	return seconds .. "s"
end

local function setDim(parts: { BasePart }, amount: number)
	for _, p in parts do
		p.LocalTransparencyModifier = amount
	end
end

local function infoRow(title: BillboardGui): TextLabel
	local existing = title:FindFirstChild("Info")
	if existing and existing:IsA("TextLabel") then
		return existing
	end
	local text = Instance.new("TextLabel")
	text.Name = "Info"
	text.Position = UDim2.fromScale(0, 0.6)
	text.Size = UDim2.fromScale(1, 0.4)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextStrokeTransparency = 0.3
	text.TextColor3 = NORMAL
	text.Text = ""
	text.Parent = title
	return text
end

local function modelParts(model: Instance): { BasePart }
	local parts: { BasePart } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	return parts
end

-- ===== Popups, progress, sparkles =====

local function popup(adornee: BasePart, text: string)
	if popupCount >= MAX_POPUPS then
		return
	end
	popupCount += 1
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(160, 36)
	gui.StudsOffsetWorldSpace = Vector3.new(math.random(-10, 10) / 10, 4, 0)
	gui.MaxDistance = 60
	gui.LightInfluence = 0
	gui.Adornee = adornee
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = ACTIVE
	label.TextStrokeTransparency = 0.3
	label.Text = text
	label.Parent = gui
	gui.Parent = visuals
	TweenService:Create(gui, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { StudsOffsetWorldSpace = gui.StudsOffsetWorldSpace + Vector3.new(0, 3, 0) }):Play()
	local fade = TweenService:Create(label, TweenInfo.new(0.9), { TextTransparency = 1, TextStrokeTransparency = 1 })
	fade:Play()
	fade.Completed:Connect(function()
		gui:Destroy()
		popupCount -= 1
	end)
end

local function sparkle(position: Vector3, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(position + Vector3.new(0, 3, 0))
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.8, 1.4)
	emitter.Speed = NumberRange.new(8, 16)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 0) })
	emitter.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
	emitter.LightEmission = 0.8
	emitter.Parent = anchor
	anchor.Parent = visuals
	emitter:Emit(40)
	task.delay(2, function()
		anchor:Destroy()
	end)
end

local function makeBar(counter: BasePart): (BillboardGui, Frame)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Progress"
	gui.Size = UDim2.fromOffset(120, 14)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)
	gui.MaxDistance = 70
	gui.LightInfluence = 0
	gui.Adornee = counter
	gui.Enabled = false
	local track = Instance.new("Frame")
	track.Size = UDim2.fromScale(1, 1)
	track.BackgroundColor3 = Color3.fromRGB(10, 40, 70)
	track.BorderSizePixel = 0
	track.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = track
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = ACTIVE
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0.5, 0)
	fillCorner.Parent = fill
	gui.Parent = visuals
	return gui, fill
end

-- ===== Manager NPCs (every zone) =====

local function trackNpc(instance: Instance)
	if not instance:IsA("Model") or npcs[instance] then
		return
	end
	local root = instance:GetPivot()
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local arms: { [number]: boolean } = {}
	for _, p in modelParts(instance) do
		table.insert(parts, p)
		table.insert(offsets, root:ToObjectSpace(p.CFrame))
		if p.Name == "Arm" then
			arms[#parts] = true
		end
	end
	npcs[instance] = { model = instance, parts = parts, offsets = offsets, arms = arms, root = root, phase = math.random() * 6 }
end

local bulkParts: { BasePart } = {}
local bulkCFrames: { CFrame } = {}

-- Looping "work" animation: a bounce and sway, with arms or claws scooping in front.
local function animateNpcs()
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else Vector3.zero
	local t = os.clock()
	table.clear(bulkParts)
	table.clear(bulkCFrames)
	for model, npc in npcs do
		if not model.Parent then
			npcs[model] = nil
			continue
		end
		if (npc.root.Position - cameraPosition).Magnitude > NPC_ANIMATE_DISTANCE then
			continue
		end
		local bounce = math.abs(math.sin(t * 4 + npc.phase)) * 0.35
		local root = npc.root * CFrame.new(0, bounce, 0) * CFrame.Angles(0, math.sin(t * 1.5 + npc.phase) * 0.25, 0)
		local scoop = math.sin(t * 6 + npc.phase) * 0.6
		for i, p in npc.parts do
			local cf = root * npc.offsets[i]
			if npc.arms[i] then
				cf *= CFrame.Angles(scoop, 0, 0)
			end
			table.insert(bulkParts, p)
			table.insert(bulkCFrames, cf)
		end
	end
	if #bulkParts > 0 then
		Workspace:BulkMoveTo(bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- ===== Labels =====

local function stationText(station: StationDef, snap: Types.Snapshot, currency: BigNumber): (string, Color3)
	local view = snap.stations[station.id]
	if not view then
		return "", NORMAL
	end
	local kind = station.kind
	local function priced(prefix: string): (string, Color3)
		local cost = StateController.big(view.cost)
		return prefix .. fmt(cost), if BigNumber.gte(currency, cost) then AFFORDABLE else NORMAL
	end
	if kind == "Deed" then
		return priced("Unlock: ")
	elseif kind == "StandMain" then
		local stand = snap.stands[station.target or ""]
		if stand and stand.managed then
			return "Managed", AFFORDABLE
		end
		return "Stand here to run!", ACTIVE
	elseif kind == "Buff" then
		local buff = snap.buffs[station.target or ""]
		if not buff then
			return "", NORMAL
		end
		local active = StateController.remaining(buff.activeRemaining)
		if active > 0 then
			return "ACTIVE " .. secondsText(active), ACTIVE
		end
		local cooldown = StateController.remaining(buff.cooldownRemaining)
		if cooldown > 0 then
			return "Recharging " .. secondsText(cooldown), LOCKED
		end
		local def = Economy.BUFF_BY_ID[station.target or ""]
		return if def then "Ready! x" .. def.multiplier else "Ready!", AFFORDABLE
	elseif kind == "Evolve" then
		if view.maxed then
			return "Fully evolved", AFFORDABLE
		elseif view.locked then
			return view.lockReason or "Locked", LOCKED
		end
		return "Stand here 2s to evolve", ACTIVE
	end
	if view.maxed then
		if kind == "Manager" then
			return "Hired!", AFFORDABLE
		elseif kind == "Statue" then
			return "Raised!", AFFORDABLE
		end
		return "MAX", AFFORDABLE
	elseif view.locked then
		return "Locked", LOCKED
	elseif kind == "Multiplier" then
		return priced("x" .. fmt(BigNumber.pow(BigNumber.fromNumber(2), view.level + 1)) .. ": ")
	elseif kind == "Speed" then
		return priced("x" .. 2 ^ (view.level + 1) .. ": ")
	end
	return priced("")
end

local function refreshLabels()
	local snap = StateController.snapshot()
	if not snap then
		return
	end
	local currency = StateController.displayCurrency()
	for model, label in labels do
		if not model.Parent then
			labels[model] = nil
			continue
		end
		local text, color = stationText(label.station, snap, currency)
		label.text.Text = text
		label.text.TextColor3 = color
		local dim = 0
		if label.station.kind == "Buff" then
			local buff = snap.buffs[label.station.target or ""]
			if buff and StateController.remaining(buff.activeRemaining) <= 0 and StateController.remaining(buff.cooldownRemaining) > 0 then
				dim = 0.5
			end
		end
		setDim(label.parts, dim)
	end
	for standId, visual in stands do
		if not visual.model.Parent then
			if visual.barGui then
				visual.barGui:Destroy()
			end
			stands[standId] = nil
			continue
		end
		local stand = snap.stands[standId]
		if stand and visual.sign then
			local rate = StateController.big(stand.rate)
			visual.sign.Text = (if stand.managed then "" else "By hand: ") .. NumberFormat.formatRate(rate)
			visual.sign.TextColor3 = if stand.managed then AFFORDABLE else ACTIVE
		end
	end
end

-- ===== Stand progress (own zone) =====

local function updateProgress()
	local snap = StateController.snapshot()
	if not snap then
		return
	end
	local now = Workspace:GetServerTimeNow()
	for standId, visual in stands do
		local stand = snap.stands[standId]
		local gui, fill, counter = visual.barGui, visual.fill, visual.counter
		if not stand or not gui or not fill or not counter then
			continue
		end
		if stand.owned and stand.managed then
			gui.Enabled = true
			local interval = stand.interval
			if interval < MIN_POP_INTERVAL then
				fill.Size = UDim2.fromScale(1, 1)
			else
				local progress = ((now - visual.loopPhase) % interval) / interval
				local previous = fill.Size.X.Scale
				fill.Size = UDim2.fromScale(progress, 1)
				if progress < previous then
					popup(counter, "+" .. fmt(StateController.big(stand.cycleValue)))
				end
			end
		elseif visual.cycleStart and visual.cycleEnd then
			gui.Enabled = true
			local start, finish = visual.cycleStart :: number, visual.cycleEnd :: number
			local progress = math.clamp((now - start) / math.max(finish - start, 1e-3), 0, 1)
			fill.Size = UDim2.fromScale(progress, 1)
			if progress >= 1 then
				local value = visual.cycleValue
				if value then
					popup(counter, "+" .. fmt(value))
				end
				visual.cycleStart, visual.cycleEnd, visual.cycleValue = nil, nil, nil
			end
		else
			gui.Enabled = stand.owned
			fill.Size = UDim2.fromScale(0, 1)
		end
	end
end

local function onCycle(event: Types.CycleEvent)
	local visual = stands[event.standId]
	local snap = StateController.snapshot()
	local stand = snap and snap.stands[event.standId]
	if not visual or not stand then
		return
	end
	local interval = math.max(stand.interval, Economy.MIN_MANUAL_INTERVAL)
	visual.cycleStart = event.endsAt - interval
	visual.cycleEnd = event.endsAt
	visual.cycleValue = StateController.big(event.value)
end

-- ===== Statues & stairway =====

local function buildStatue(statueId: string, position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "Statue_" .. statueId
	local gold = Color3.fromRGB(255, 205, 90)
	local function add(size: Vector3, cframe: CFrame, shape: Enum.PartType?, material: Enum.Material?)
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
	end
	-- Pedestal sits on the pad inlay (top at +0.55).
	local base = CFrame.new(position + Vector3.new(0, 0.55, 0))
	add(Vector3.new(4.4, 2, 4.4), base * CFrame.new(0, 1, 0), nil, Enum.Material.Marble)
	-- A leaping golden fish.
	add(Vector3.new(4, 4, 4), base * CFrame.new(0, 6.3, 0), Enum.PartType.Ball)
	add(Vector3.new(3, 3, 3), base * CFrame.new(0, 8.8, -1.5), Enum.PartType.Ball)
	add(Vector3.new(1, 4, 3), base * CFrame.new(0, 3.3, 2) * CFrame.Angles(math.rad(35), 0, 0))
	add(Vector3.new(0.6, 2, 2), base * CFrame.new(1.8, 6.3, 0) * CFrame.Angles(0, 0, math.rad(25)))
	add(Vector3.new(0.6, 2, 2), base * CFrame.new(-1.8, 6.3, 0) * CFrame.Angles(0, 0, math.rad(-25)))
	local glow = Instance.new("PointLight")
	glow.Color = gold
	glow.Range = 16
	glow.Brightness = 2
	glow.Parent = model:FindFirstChildWhichIsA("BasePart")
	model.Parent = visuals
	return model
end

local function onSnapshot(snap: Types.Snapshot)
	for _, statue in Statues.LIST do
		if snap.statues[statue.id] and not builtStatues[statue.id] then
			local station = Stations.BY_ID["Statue_" .. statue.id]
			if station then
				builtStatues[statue.id] = buildStatue(statue.id, station.position)
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
		local title = barrier:FindFirstChild("Title")
		if title and title:IsA("BillboardGui") then
			title.Enabled = not open
		end
	end
	refreshLabels()
end

-- ===== Attaching to server-built instances =====

local function attachPad(model: Instance)
	local station = Stations.BY_ID[model.Name]
	if not station or labels[model] then
		return
	end
	task.spawn(function()
		local title: Instance? = nil
		if station.kind == "Deed" then
			local orb = model:WaitForChild("Orb", 10)
			title = orb and orb:WaitForChild("Title", 10)
		else
			local pad = model:WaitForChild("Pad", 10)
			title = pad and pad:WaitForChild("Title", 10)
		end
		if title and title:IsA("BillboardGui") and model.Parent then
			labels[model] = { station = station, text = infoRow(title), parts = modelParts(model) }
			refreshLabels()
		end
	end)
end

local function attachStand(model: Instance)
	if not model:IsA("Model") or not Economy.STAND_BY_ID[model.Name] then
		return
	end
	task.spawn(function()
		local post = model:WaitForChild("SignPost", 10)
		local title = post and post:WaitForChild("Title", 10)
		local counter = model:WaitForChild("Counter", 10)
		if not model.Parent then
			return
		end
		local visual: StandVisual = {
			standId = model.Name,
			model = model,
			sign = if title and title:IsA("BillboardGui") then infoRow(title) else nil,
			counter = if counter and counter:IsA("BasePart") then counter else nil,
			loopPhase = Workspace:GetServerTimeNow(),
		}
		if visual.counter then
			visual.barGui, visual.fill = makeBar(visual.counter)
		end
		stands[model.Name] = visual
	end)
end

-- Sparkle when any player's new structure appears (skipped for what already exists on join).
local function watchStructures(zones: Instance)
	local function hookZone(zone: Instance)
		local standsFolder = zone:WaitForChild("Stands", 30)
		if not standsFolder then
			return
		end
		standsFolder.ChildAdded:Connect(function(child)
			if os.clock() - attachedAt > 3 and child:IsA("Model") and Economy.STAND_BY_ID[child.Name] then
				local pivot = child:GetPivot()
				local plot = Stations.PLOT_BY_STAND[child.Name]
				sparkle(pivot.Position, if plot then plot.color else Color3.new(1, 1, 1))
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
	for model in labels do
		if model.Parent and Stations.BY_ID[model.Name] and Stations.BY_ID[model.Name].scope == "Zone" then
			labels[model] = nil
		end
	end
	for standId, visual in stands do
		if visual.barGui then
			visual.barGui:Destroy()
		end
		stands[standId] = nil
	end

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
	for _, child in stationsFolder:GetChildren() do
		attachPad(child)
	end
	for _, child in standsFolder:GetChildren() do
		attachStand(child)
	end
	table.insert(zoneConnections, stationsFolder.ChildAdded:Connect(attachPad))
	table.insert(zoneConnections, standsFolder.ChildAdded:Connect(attachStand))
end

local function attachArena(arena: Instance)
	local hub = arena:WaitForChild("Hub", 30)
	local hubStations = hub and hub:WaitForChild("Stations", 30)
	if hubStations then
		for _, child in hubStations:GetChildren() do
			attachPad(child)
		end
	end
	local zones = arena:WaitForChild("Zones", 30)
	if not zones then
		warn("[WorldController] Zones not found")
		return
	end
	watchStructures(zones)
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

	for _, instance in CollectionService:GetTagged(MANAGER_TAG) do
		trackNpc(instance)
	end
	CollectionService:GetInstanceAddedSignal(MANAGER_TAG):Connect(trackNpc)
	CollectionService:GetInstanceRemovedSignal(MANAGER_TAG):Connect(function(instance)
		if instance:IsA("Model") then
			npcs[instance] = nil
		end
	end)

	StateController.snapshotChanged:Connect(onSnapshot)
	StateController.cycleStarted:Connect(onCycle)
	RunService.Heartbeat:Connect(function()
		animateNpcs()
		updateProgress()
	end)
	task.spawn(function()
		while true do
			task.wait(0.25)
			refreshLabels()
		end
	end)
end

return WorldController
