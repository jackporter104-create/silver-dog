--!strict
--[[
	WorldController: per-player 3D presentation of arena state. The arena itself is shared and
	built by the server, so everything here is local:
	  * An info row on every pad's sign (price, level, cooldown) refreshed at 4 Hz.
	  * Locked stands and their pads look ghosted. Locked or recharging buff pads are dimmed.
	  * Manager NPCs (crab / mermaid) appear at managed stands and play a looping work animation.
	  * A progress bar over each stand counter, with "+value" pops when a cycle pays out.
	  * Golden statues on owned pedestals, and the Heavenly Stairway barrier opening.
	Character physics are client-owned, so opening the barrier locally lets the player pass.
	Statue purchases are still validated by the server.
]]

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

type Label = { station: StationDef, text: TextLabel, parts: { BasePart } }
type StandVisual = {
	standId: string,
	sign: TextLabel?,
	props: { BasePart },
	fill: Frame?,
	barGui: BillboardGui?,
	counter: BasePart?,
	cycleStart: number?,
	cycleEnd: number?,
	cycleValue: BigNumber?,
	loopPhase: number, -- managed stands: server-time origin of the visual loop
}
type Npc = { parts: { BasePart }, offsets: { CFrame }, arms: { [number]: boolean }, root: CFrame, phase: number }

local labels: { Label } = {}
local stands: { [string]: StandVisual } = {}
local npcs: { [string]: Npc } = {}
local builtStatues: { [string]: Model } = {}
local visuals: Folder
local popupCount = 0

local AFFORDABLE = Color3.fromRGB(110, 255, 160)
local NORMAL = Color3.fromRGB(255, 255, 255)
local LOCKED = Color3.fromRGB(160, 170, 185)
local ACTIVE = Color3.fromRGB(255, 220, 90)
local GHOST = 0.7
local MAX_POPUPS = 10
local MIN_POP_INTERVAL = 0.8 -- managed stands faster than this show a steady bar instead of pops

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

local function setGhost(parts: { BasePart }, amount: number)
	for _, p in parts do
		p.LocalTransparencyModifier = amount
	end
end

local function infoRow(title: BillboardGui): TextLabel
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

-- ===== Popups & progress =====

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

-- ===== Manager NPCs =====

local function npcPart(model: Model, size: Vector3, color: Color3, shape: Enum.PartType?, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.Color = color
	p.Shape = shape or Enum.PartType.Block
	p.Material = material or Enum.Material.SmoothPlastic
	p.Parent = model
	return p
end

local function buildNpc(standId: string): Npc?
	local plot = Stations.PLOT_BY_STAND[standId]
	local def = Economy.STAND_BY_ID[standId]
	if not plot or not def then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = "Manager_" .. standId
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local arms: { [number]: boolean } = {}
	local function add(p: BasePart, offset: CFrame, isArm: boolean?)
		table.insert(parts, p)
		table.insert(offsets, offset)
		if isArm then
			arms[#parts] = true
		end
	end
	local eye = Color3.fromRGB(20, 20, 30)
	if def.npc == "Crab" then
		local shell = Color3.fromRGB(235, 80, 60)
		add(npcPart(model, Vector3.new(3.2, 1.6, 2.4), shell, Enum.PartType.Ball), CFrame.new(0, 1.6, 0))
		for _, x in { -0.6, 0.6 } do
			add(npcPart(model, Vector3.new(0.25, 0.9, 0.25), shell), CFrame.new(x, 2.6, -0.6))
			add(npcPart(model, Vector3.new(0.45, 0.45, 0.45), eye, Enum.PartType.Ball), CFrame.new(x, 3.1, -0.6))
		end
		for _, x in { -2, 2 } do
			add(npcPart(model, Vector3.new(1.2, 0.9, 1.2), shell, Enum.PartType.Ball), CFrame.new(x, 2.2, -1.2), true)
		end
		for i = -1, 1 do
			for _, x in { -1.4, 1.4 } do
				add(npcPart(model, Vector3.new(0.25, 1.2, 0.25), shell), CFrame.new(x, 0.7, i * 0.6) * CFrame.Angles(0, 0, math.rad(if x > 0 then -30 else 30)))
			end
		end
	else
		local skin = Color3.fromRGB(255, 214, 180)
		local tail = Color3.fromRGB(60, 200, 190)
		add(npcPart(model, Vector3.new(1.4, 2.6, 1.2), tail, Enum.PartType.Ball), CFrame.new(0, 1.3, 0))
		add(npcPart(model, Vector3.new(0.3, 1.2, 1.6), tail), CFrame.new(0, 0.3, 0.6) * CFrame.Angles(math.rad(30), 0, 0))
		add(npcPart(model, Vector3.new(1.3, 1.6, 0.9), Color3.fromRGB(255, 120, 170)), CFrame.new(0, 3.2, 0))
		add(npcPart(model, Vector3.new(1.2, 1.2, 1.2), skin, Enum.PartType.Ball), CFrame.new(0, 4.5, 0))
		add(npcPart(model, Vector3.new(1.4, 1.3, 1), Color3.fromRGB(250, 170, 60), Enum.PartType.Ball), CFrame.new(0, 4.7, 0.25))
		for _, x in { -0.25, 0.25 } do
			add(npcPart(model, Vector3.new(0.18, 0.2, 0.1), eye), CFrame.new(x, 4.6, -0.6))
		end
		for _, x in { -0.9, 0.9 } do
			add(npcPart(model, Vector3.new(0.35, 1.4, 0.35), skin), CFrame.new(x, 3.2, -0.3), true)
		end
	end
	model.Parent = visuals
	-- Beside the counter, facing the plaza.
	local position = plot.center + plot.right * 7 + plot.forward * 4 + Vector3.new(0, Stations.SEA_FLOOR_TOP, 0)
	return { parts = parts, offsets = offsets, arms = arms, root = CFrame.lookAt(position, position + plot.forward), phase = math.random() * 6 }
end

local bulkParts: { BasePart } = {}
local bulkCFrames: { CFrame } = {}

-- Looping "work" animation: a bounce and sway, with arms or claws scooping in front.
local function animateNpcs()
	local t = os.clock()
	table.clear(bulkParts)
	table.clear(bulkCFrames)
	for _, npc in npcs do
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
	if kind == "StandMain" then
		local stand = snap.stands[station.target or ""]
		if not stand or not stand.owned then
			return priced("Unlock: ")
		elseif stand.managed then
			return "Managed", AFFORDABLE
		end
		return "Stand here to run!", ACTIVE
	elseif kind == "Buff" then
		local buff = snap.buffs[station.target or ""]
		if view.locked or not buff then
			return view.lockReason or "Locked", LOCKED
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
		local next = NumberFormat.format(BigNumber.pow(BigNumber.fromNumber(2), view.level + 1))
		return priced("x" .. next .. ": ")
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
	for _, label in labels do
		local text, color = stationText(label.station, snap, currency)
		label.text.Text = text
		label.text.TextColor3 = color
		local view = snap.stations[label.station.id]
		local kind: string = label.station.kind
		local dim = 0
		local locked = view ~= nil and view.locked
		if kind == "Buff" then
			local buff = snap.buffs[label.station.target or ""]
			if locked then
				dim = GHOST
			elseif buff and StateController.remaining(buff.activeRemaining) <= 0 and StateController.remaining(buff.cooldownRemaining) > 0 then
				dim = 0.5
			end
		elseif locked and kind ~= "Evolve" then
			dim = GHOST
		end
		setGhost(label.parts, dim)
	end
	for standId, visual in stands do
		local stand = snap.stands[standId]
		if stand and visual.sign then
			if stand.owned then
				local rate = StateController.big(stand.rate)
				visual.sign.Text = (if stand.managed then "" else "By hand: ") .. NumberFormat.formatRate(rate)
				visual.sign.TextColor3 = if stand.managed then AFFORDABLE else ACTIVE
			else
				local view = snap.stations[standId .. "_Main"]
				local cost = StateController.big(view and view.cost)
				visual.sign.Text = "Locked • " .. fmt(cost)
				visual.sign.TextColor3 = LOCKED
			end
		end
		if stand then
			setGhost(visual.props, if stand.owned then 0 else GHOST)
		end
	end
end

-- ===== Stand progress =====

local function updateProgress()
	local snap = StateController.snapshot()
	if not snap then
		return
	end
	local now = Workspace:GetServerTimeNow()
	for standId, visual in stands do
		local stand = snap.stands[standId]
		local gui, fill = visual.barGui, visual.fill
		if not stand or not gui or not fill or not visual.counter then
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
					popup(visual.counter, "+" .. fmt(StateController.big(stand.cycleValue)))
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
					popup(visual.counter, "+" .. fmt(value))
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
		local p = npcPart(model, size, gold, shape, material or Enum.Material.Foil)
		p.CFrame = cframe
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
		end
	end

	-- Managers: spawn NPCs for newly managed stands, remove them after an Evolution.
	for _, def in Economy.STANDS do
		local stand = snap.stands[def.id]
		local managed = stand ~= nil and stand.managed
		local npc = npcs[def.id]
		if managed and not npc then
			local built = buildNpc(def.id)
			if built then
				npcs[def.id] = built
				local visual = stands[def.id]
				if visual then
					visual.loopPhase = Workspace:GetServerTimeNow()
				end
			end
		elseif not managed and npc then
			local model = npc.parts[1] and npc.parts[1].Parent
			if model then
				model:Destroy()
			end
			npcs[def.id] = nil
		end
	end

	local arena = Workspace:FindFirstChild("OceanArena")
	local stairway = arena and arena:FindFirstChild("HeavenlyStairway")
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

local function attachArena(arena: Instance)
	local stationsFolder = arena:WaitForChild("Stations", 30)
	local standsFolder = arena:WaitForChild("Stands", 30)
	if not stationsFolder or not standsFolder then
		warn("[WorldController] Arena folders not found")
		return
	end
	for _, station in Stations.LIST do
		local model = stationsFolder:WaitForChild(station.id, 30)
		local pad = model and model:WaitForChild("Pad", 10)
		local title = pad and pad:WaitForChild("Title", 10)
		if model and title and title:IsA("BillboardGui") then
			table.insert(labels, { station = station, text = infoRow(title), parts = modelParts(model) })
		end
	end
	for _, plot in Stations.PLOTS do
		local model = standsFolder:WaitForChild(plot.standId, 30)
		if model then
			local post = model:WaitForChild("SignPost", 10)
			local title = post and post:WaitForChild("Title", 10)
			local counter = model:WaitForChild("Counter", 10)
			local props: { BasePart } = {}
			for _, p in modelParts(model) do
				if p.Name ~= "Base" then
					table.insert(props, p)
				end
			end
			local visual: StandVisual = {
				standId = plot.standId,
				sign = if title and title:IsA("BillboardGui") then infoRow(title) else nil,
				props = props,
				counter = if counter and counter:IsA("BasePart") then counter else nil,
				loopPhase = Workspace:GetServerTimeNow(),
			}
			if visual.counter then
				visual.barGui, visual.fill = makeBar(visual.counter)
			end
			stands[plot.standId] = visual
		end
	end
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
