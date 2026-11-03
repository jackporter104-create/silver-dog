--!strict
--[[
	WorldController: per-player 3D presentation of arena state.
	  * Billboard labels on each station: level and price, green when affordable (4 Hz).
	  * Golden statues on pedestals the player owns (built client-side).
	  * Opens the Heavenly Stairway barrier locally once the server reports it unlocked.
	    Character physics are client-owned, so a local collision change lets the player pass.
	    Purchases there are still validated by the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BigNumber = require(Shared.BigNumber)
local NumberFormat = require(Shared.NumberFormat)
local Types = require(Shared.Types)
local Stations = require(Shared.Config.Stations)
local Statues = require(Shared.Config.Statues)

local StateController = require(script.Parent.StateController)
local StationController = require(script.Parent.StationController)

type StationDef = Stations.StationDef

local WorldController = {}

type Label = { station: StationDef, text: TextLabel }

local labels: { Label } = {}
local builtStatues: { [string]: Model } = {}
local visuals: Folder

local AFFORDABLE = Color3.fromRGB(110, 255, 160)
local EXPENSIVE = Color3.fromRGB(255, 255, 255)
local LOCKED = Color3.fromRGB(160, 170, 185)

-- Adds the per-player price row to the station's server-built "Title" billboard,
-- so name and price form one stacked sign instead of two overlapping ones.
local function makeLabel(station: StationDef, title: BillboardGui)
	local text = Instance.new("TextLabel")
	text.Name = "Info"
	text.Position = UDim2.fromScale(0, 0.6)
	text.Size = UDim2.fromScale(1, 0.4)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextStrokeTransparency = 0.3
	text.TextColor3 = EXPENSIVE
	text.Text = ""
	text.Parent = title
	table.insert(labels, { station = station, text = text })
end

local function refreshLabels()
	local snap = StateController.snapshot()
	if not snap then
		return
	end
	local currency = StateController.displayCurrency()
	for _, label in labels do
		local view = snap.stations[label.station.id]
		if view then
			if view.maxed then
				label.text.Text = if label.station.kind == "Statue" then "Raised!" else "MAX"
				label.text.TextColor3 = AFFORDABLE
			elseif view.locked then
				label.text.Text = "Locked"
				label.text.TextColor3 = LOCKED
			elseif view.cost then
				local cost = StateController.big(view.cost)
				local prefix = if label.station.kind == "Generator" then "Lv " .. view.level .. "  •  " else ""
				label.text.Text = prefix .. NumberFormat.format(cost)
				label.text.TextColor3 = if BigNumber.gte(currency, cost) then AFFORDABLE else EXPENSIVE
			elseif label.station.kind == "Evolution" then
				label.text.Text = if snap.evolution.canEvolve then "READY!" else "Evolution " .. snap.evolution.level
				label.text.TextColor3 = if snap.evolution.canEvolve then AFFORDABLE else EXPENSIVE
			else
				label.text.Text = ""
			end
		end
	end
end

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
	local base = CFrame.new(position)
	-- Pedestal sits on the pad inlay (top at +1.2) and stays clear of the sign pillar.
	add(Vector3.new(4.4, 2, 4.4), base * CFrame.new(0, 2.2, 0), nil, Enum.Material.Marble)
	-- A leaping golden fish.
	add(Vector3.new(4, 4, 4), base * CFrame.new(0, 7.5, 0), Enum.PartType.Ball)
	add(Vector3.new(3, 3, 3), base * CFrame.new(0, 10, -1.5), Enum.PartType.Ball)
	add(Vector3.new(1, 4, 3), base * CFrame.new(0, 4.5, 2) * CFrame.Angles(math.rad(35), 0, 0))
	add(Vector3.new(0.6, 2, 2), base * CFrame.new(1.8, 7.5, 0) * CFrame.Angles(0, 0, math.rad(25)))
	add(Vector3.new(0.6, 2, 2), base * CFrame.new(-1.8, 7.5, 0) * CFrame.Angles(0, 0, math.rad(-25)))
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

local function pulsePearl(station: StationDef?)
	if not station or station.kind ~= "Clam" then
		return
	end
	local arena = Workspace:FindFirstChild("OceanArena")
	local model = arena and arena:FindFirstChild("Stations") and (arena :: any).Stations:FindFirstChild(station.id)
	local pearl = model and model:FindFirstChild("Pearl")
	if pearl and pearl:IsA("BasePart") then
		pearl.Size = Vector3.new(6, 6, 6)
		TweenService:Create(pearl, TweenInfo.new(0.15, Enum.EasingStyle.Back), { Size = Vector3.new(5, 5, 5) }):Play()
	end
end

function WorldController.init()
	visuals = Instance.new("Folder")
	visuals.Name = "LocalArenaVisuals"
	visuals.Parent = Workspace

	task.spawn(function()
		local arena = Workspace:WaitForChild("OceanArena", 60)
		local stationsFolder = arena and arena:WaitForChild("Stations", 30)
		if not stationsFolder then
			warn("[WorldController] Arena not found")
			return
		end
		for _, station in Stations.LIST do
			if station.kind ~= "Clam" then
				local model = stationsFolder:WaitForChild(station.id, 30)
				local pillar = model and model:WaitForChild("Pillar", 10)
				local title = pillar and pillar:WaitForChild("Title", 10)
				if title and title:IsA("BillboardGui") then
					makeLabel(station, title)
				end
			end
		end
		refreshLabels()
	end)

	StateController.snapshotChanged:Connect(onSnapshot)
	StationController.clicked:Connect(function()
		pulsePearl(StationController.nearest())
	end)
	task.spawn(function()
		while true do
			task.wait(0.25)
			refreshLabels()
		end
	end)
end

return WorldController
