--!strict
--[[
	HudController: the oceanic HUD, built in code (no external assets).
	Updates every frame from StateController's extrapolated values, never doing economy math.
	It formats and compares only. Restyled live by UiConfig (A/B variants and live overrides).
]]

local MarketplaceService = game:GetService("MarketplaceService")
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
local Monetization = require(Shared.Config.Monetization)
local Experiments = require(Shared.Config.Experiments)
local Seasons = require(Shared.Config.Seasons)

local StateController = require(script.Parent.Parent.Controllers.StateController)
local StationController = require(script.Parent.Parent.Controllers.StationController)
local Theme = require(script.Parent.Theme)

type BigNumber = BigNumber.BigNumber
type StationDef = Stations.StationDef

local HudController = {}

local C = Theme.Colors
local player = Players.LocalPlayer
local PER_NS_THRESHOLD = BigNumber.fromExponent(12)
local NANOSECONDS = BigNumber.fromExponent(9)
local MAX_POPUPS = 8

local uiConfig: Types.UiConfig = table.clone(Experiments.UI_DEFAULTS)
local accentStrokes: { UIStroke } = {}
local popupCount = 0

-- UI references, assigned in build().
local gui: ScreenGui
local scale: UIScale
local currencyLabel: TextLabel
local suffixLabel: TextLabel
local rateLabel: TextLabel
local evoTitle: TextLabel
local evoSub: TextLabel
local evoFill: Frame
local batteryText: TextLabel
local batteryFill: Frame
local investorText: TextLabel
local prompt: Frame
local promptTitle: TextLabel
local promptSub: TextLabel
local buyOne: TextButton
local buyTen: TextButton
local extraButton: TextButton
local tapButton: TextButton
local tapScale: UIScale
local toastList: Frame
local evolveModal: Frame
local perkRow: Frame
local evolveInfo: TextLabel

local function accentStroke(thickness: number): UIStroke
	local stroke = Theme.stroke(uiConfig.accentColor, thickness, 0.1)
	table.insert(accentStrokes, stroke)
	return stroke
end

local function panel(props: { [string]: any }): Frame
	props.BackgroundColor3 = C.panel
	local frame: Frame = Theme.make("Frame", props, {
		Theme.corner(20),
		Theme.gradient(C.panelLight, C.deep),
		accentStroke(3),
	})
	return frame
end

local function bar(parent: Instance, position: UDim2, size: UDim2, color: Color3): Frame
	local track: Frame = Theme.make("Frame", {
		Position = position,
		Size = size,
		BackgroundColor3 = C.deep,
		BorderSizePixel = 0,
		Parent = parent,
	}, { Theme.corner(8) })
	local fill: Frame = Theme.make("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = track,
	}, { Theme.corner(8), Theme.gradient(Color3.new(1, 1, 1), Color3.fromRGB(200, 200, 200)) })
	return fill
end

-- ===== Build =====

local function buildCurrency()
	local pill = panel({
		Name = "Currency",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.fromOffset(440, 108),
		Parent = gui,
	})
	local pearl: Frame = Theme.make("Frame", {
		Position = UDim2.fromOffset(14, 16),
		Size = UDim2.fromOffset(76, 76),
		BackgroundColor3 = C.pearl,
		Parent = pill,
	}, { Theme.corner(38), Theme.gradient(Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 190, 225), 45), Theme.stroke(Color3.new(1, 1, 1), 2, 0.3) })
	Theme.make("Frame", {
		Position = UDim2.fromScale(0.22, 0.16),
		Size = UDim2.fromScale(0.3, 0.22),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.2,
		Parent = pearl,
	}, { Theme.corner(20) })

	currencyLabel = Theme.label({ Position = UDim2.fromOffset(102, 6), Size = UDim2.new(1, -116, 0, 56), Text = "0", TextXAlignment = Enum.TextXAlignment.Left, Parent = pill })
	suffixLabel = Theme.label({ Position = UDim2.fromOffset(104, 60), Size = UDim2.new(1, -116, 0, 18), Text = "", Font = Theme.FONT_BODY, TextColor3 = C.gold, TextXAlignment = Enum.TextXAlignment.Left, Parent = pill })
	rateLabel = Theme.label({ Position = UDim2.fromOffset(104, 78), Size = UDim2.new(1, -116, 0, 24), Text = "+0/s", TextColor3 = C.success, TextXAlignment = Enum.TextXAlignment.Left, Parent = pill })
end

local function buildEvolution()
	local badge = panel({ Name = "Evolution", Position = UDim2.fromOffset(12, 12), Size = UDim2.fromOffset(240, 92), Parent = gui })
	evoTitle = Theme.label({ Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -28, 0, 30), Text = "EVOLUTION 1", TextXAlignment = Enum.TextXAlignment.Left, Parent = badge })
	evoSub = Theme.label({ Position = UDim2.fromOffset(14, 38), Size = UDim2.new(1, -28, 0, 20), Text = "", Font = Theme.FONT_BODY, TextColor3 = C.muted, TextXAlignment = Enum.TextXAlignment.Left, Parent = badge })
	evoFill = bar(badge, UDim2.fromOffset(14, 64), UDim2.new(1, -28, 0, 14), Color3.fromRGB(200, 120, 255))
end

local function buildStatus()
	local status = panel({ Name = "Status", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 12), Size = UDim2.fromOffset(240, 92), Parent = gui })
	batteryText = Theme.label({ Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -28, 0, 22), Text = "Auto-Clicker: none", Font = Theme.FONT_BODY, TextXAlignment = Enum.TextXAlignment.Left, Parent = status })
	batteryFill = bar(status, UDim2.fromOffset(14, 34), UDim2.new(1, -28, 0, 14), C.gold)
	investorText = Theme.label({ Position = UDim2.fromOffset(14, 56), Size = UDim2.new(1, -28, 0, 26), Text = "Investors: 0", TextColor3 = C.success, TextXAlignment = Enum.TextXAlignment.Left, Parent = status })
end

local function buildPrompt()
	prompt = panel({ Name = "Prompt", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -18), Size = UDim2.fromOffset(500, 156), Visible = false, Parent = gui })
	promptTitle = Theme.label({ Position = UDim2.fromOffset(16, 8), Size = UDim2.new(1, -32, 0, 36), Text = "", Parent = prompt })
	promptSub = Theme.label({ Position = UDim2.fromOffset(16, 44), Size = UDim2.new(1, -32, 0, 22), Text = "", Font = Theme.FONT_BODY, TextColor3 = C.muted, Parent = prompt })
	local row: Frame = Theme.make("Frame", { Position = UDim2.new(0, 16, 1, -78), Size = UDim2.new(1, -32, 0, 64), BackgroundTransparency = 1, Parent = prompt }, {
		Theme.make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 10) }),
	})
	buyOne = Theme.button({ Size = UDim2.fromOffset(220, 64), Text = "Buy", LayoutOrder = 1, Parent = row }, C.success)
	buyTen = Theme.button({ Size = UDim2.fromOffset(130, 64), Text = "x10", LayoutOrder = 2, Parent = row }, Color3.fromRGB(60, 170, 255))
	extraButton = Theme.button({ Size = UDim2.fromOffset(110, 64), Text = "", LayoutOrder = 3, Visible = false, Parent = row }, Color3.fromRGB(255, 170, 40))

	tapButton = Theme.make("TextButton", {
		Name = "Tap",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -190),
		Size = UDim2.fromOffset(170, 170),
		BackgroundColor3 = C.pearl,
		Text = "TAP!",
		Font = Theme.FONT,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(255, 90, 160),
		Visible = false,
		Parent = gui,
	}, {
		Theme.corner(85),
		Theme.gradient(Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 180, 220), 45),
		accentStroke(5),
		Theme.padding(30),
	})
	tapScale = Instance.new("UIScale")
	tapScale.Parent = tapButton
end

local function buildToasts()
	toastList = Theme.make("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 116),
		Size = UDim2.fromOffset(320, 400),
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		Theme.make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Right }),
	})
end

local function buildEvolveModal()
	evolveModal = Theme.make("Frame", {
		Name = "EvolveModal",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		Visible = false,
		ZIndex = 10,
		Parent = gui,
	})
	local card = panel({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(860, 420), ZIndex = 11, Parent = evolveModal })
	Theme.label({ Position = UDim2.fromOffset(20, 14), Size = UDim2.new(1, -40, 0, 48), Text = "EVOLVE!", TextColor3 = Color3.fromRGB(220, 170, 255), ZIndex = 12, Parent = card })
	evolveInfo = Theme.label({ Position = UDim2.fromOffset(20, 62), Size = UDim2.new(1, -40, 0, 48), Text = "", Font = Theme.FONT_BODY, TextWrapped = true, ZIndex = 12, Parent = card })
	perkRow = Theme.make("Frame", { Position = UDim2.fromOffset(20, 122), Size = UDim2.new(1, -40, 0, 210), BackgroundTransparency = 1, ZIndex = 12, Parent = card }, {
		Theme.make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 12) }),
	})
	local cancel = Theme.button({ AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -16), Size = UDim2.fromOffset(200, 54), Text = "Not yet", ZIndex = 12, Parent = card }, C.locked)
	cancel.Activated:Connect(function()
		evolveModal.Visible = false
	end)
end

-- ===== Behaviour =====

local function toast(kind: Types.NotifyKind, text: string, amount: BigNumber?)
	local color = if kind == "Error" then C.danger
		elseif kind == "Success" then C.success
		elseif kind == "Evolution" then Color3.fromRGB(200, 120, 255)
		elseif kind == "Offline" then C.gold
		else C.panelLight
	local frame: Frame = Theme.make("Frame", {
		Size = UDim2.fromOffset(320, if amount then 84 else 58),
		BackgroundColor3 = C.deep,
		BackgroundTransparency = 0.1,
		LayoutOrder = -math.floor(os.clock() * 100),
		Parent = toastList,
	}, { Theme.corner(14), Theme.stroke(color, 3), Theme.padding(8) })
	Theme.label({ Size = UDim2.new(1, 0, 0, 40), Text = text, Font = Theme.FONT_BODY, TextWrapped = true, Parent = frame })
	if amount then
		Theme.label({ Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 26), Text = "+" .. NumberFormat.format(amount), TextColor3 = C.gold, Parent = frame })
	end
	task.delay(if kind == "Offline" then 7 else 3.5, function()
		local tween = TweenService:Create(frame, TweenInfo.new(0.3), { BackgroundTransparency = 1 })
		tween:Play()
		tween.Completed:Wait()
		frame:Destroy()
	end)
end

local function clickPopup(amount: BigNumber)
	if popupCount >= MAX_POPUPS or not tapButton.Visible then
		return
	end
	popupCount += 1
	local label = Theme.label({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = tapButton.Position + UDim2.fromOffset(math.random(-60, 60), -180),
		Size = UDim2.fromOffset(160, 40),
		Text = "+" .. NumberFormat.format(amount),
		TextColor3 = C.gold,
		Parent = gui,
	})
	local tween = TweenService:Create(label, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = label.Position - UDim2.fromOffset(0, 70),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	tween:Play()
	tween.Completed:Connect(function()
		label:Destroy()
		popupCount -= 1
	end)
	tapScale.Scale = uiConfig.tapButtonScale * 0.92
	TweenService:Create(tapScale, TweenInfo.new(0.12), { Scale = uiConfig.tapButtonScale }):Play()
end

local function costOf(view: Types.StationView?, ten: boolean): BigNumber?
	if not view then
		return nil
	end
	local raw = if ten then view.cost10 else view.cost
	return if raw then StateController.big(raw) else nil
end

local function stationDescription(station: StationDef, view: Types.StationView): string
	if view.locked and view.lockReason then
		return "Locked: " .. view.lockReason
	end
	local kind = station.kind
	if kind == "Generator" then
		local def = Economy.GENERATOR_BY_ID[station.target or ""]
		return string.format("Owned: %d  •  %s", view.level, if def then def.description else "")
	elseif kind == "ClickUpgrade" then
		return string.format("Click power level %d", view.level)
	elseif kind == "Investor" then
		return string.format("Investors: %d  •  each gives +1%% passive income", view.level)
	elseif kind == "AutoClicker" then
		return if view.maxed then "Fully upgraded!" else string.format("Auto-Clicker Mk.%d → Mk.%d", view.level, view.level + 1)
	elseif kind == "Battery" then
		return if view.maxed then "Your Auto-Clicker never runs out!" else "Refill your Auto-Clicker battery"
	elseif kind == "Evolution" then
		return if view.maxed then "Fully evolved!" else "Sacrifice this run for a massive multiplier"
	elseif kind == "Statue" then
		return if view.maxed then "Raised! Its power is yours forever" else "A permanent colossal multiplier"
	end
	return "Tap the pearl to earn!"
end

local function refreshPrompt()
	local station = StationController.nearest()
	local snap = StateController.snapshot()
	tapButton.Visible = station ~= nil and station.kind == "Clam"
	if not station or not snap then
		prompt.Visible = false
		return
	end
	local view = snap.stations[station.id]
	if not view then
		prompt.Visible = false
		return
	end
	prompt.Visible = true
	promptTitle.Text = station.displayName
	promptSub.Text = stationDescription(station, view)

	local kind = station.kind
	local supportsTen = kind == "Generator" or kind == "ClickUpgrade" or kind == "Investor"
	buyTen.Visible = supportsTen and not view.locked and not view.maxed
	extraButton.Visible = false
	if kind == "Battery" and Monetization.BATTERY_OVERCHARGE_PRODUCT_ID ~= 0 then
		extraButton.Visible = true
		extraButton.Text = "⚡ Overcharge"
	elseif kind == "AutoClicker" and Monetization.INFINITE_AUTO_CLICKER_PASS_ID ~= 0 and not snap.autoClicker.infinite then
		extraButton.Visible = true
		extraButton.Text = "∞ Infinite"
	end
	buyOne.Visible = kind ~= "Clam"
end

-- Called every frame. Cheap: one format and a couple of comparisons.
local function refreshPromptButtons(currency: BigNumber)
	local station = StationController.nearest()
	local snap = StateController.snapshot()
	if not prompt.Visible or not station or not snap then
		return
	end
	local view = snap.stations[station.id]
	if not view then
		return
	end
	local kind = station.kind
	local cost = costOf(view, false)
	local text: string
	local enabled: boolean
	if view.maxed then
		text, enabled = (if kind == "Statue" then "Raised!" else "MAX"), false
	elseif view.locked then
		text, enabled = "Locked", false
	elseif kind == "Battery" then
		text, enabled = "Recharge", true
	elseif kind == "Evolution" then
		text, enabled = "EVOLVE!", snap.evolution.canEvolve
	elseif cost then
		enabled = BigNumber.gte(currency, cost)
		text = (if kind == "Statue" then "Raise " elseif kind == "AutoClicker" then "Upgrade " else "Buy ") .. NumberFormat.format(cost)
	else
		text, enabled = "Use", true
	end
	buyOne.Text = text
	buyOne.BackgroundColor3 = if enabled then C.success else C.locked
	local cost10 = costOf(view, true)
	if buyTen.Visible and cost10 then
		buyTen.Text = "x10 " .. NumberFormat.format(cost10)
		buyTen.BackgroundColor3 = if BigNumber.gte(currency, cost10) then Color3.fromRGB(60, 170, 255) else C.locked
	end
end

local function openEvolveModal()
	local snap = StateController.snapshot()
	if not snap then
		return
	end
	local evo = snap.evolution
	if not evo.canEvolve then
		toast("Error", "Earn " .. NumberFormat.format(StateController.big(evo.requirement)) .. " this run to evolve!")
		return
	end
	evolveInfo.Text = string.format(
		"You will LOSE all %s, Investors and upgrades.\nAll income becomes x%s (now x%s). Choose a bonus to keep forever:",
		Seasons.get(snap.seasonId).currencyName,
		NumberFormat.format(StateController.big(evo.nextMultiplier)),
		NumberFormat.format(StateController.big(evo.multiplier))
	)
	for _, child in perkRow:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for index, perk in evo.perks do
		local card: Frame = Theme.make("Frame", { Size = UDim2.fromOffset(150, 205), BackgroundColor3 = C.deep, LayoutOrder = index, ZIndex = 12, Parent = perkRow }, {
			Theme.corner(16),
			accentStroke(2),
			Theme.padding(8),
		})
		Theme.label({ Size = UDim2.new(1, 0, 0, 44), Text = perk.name, TextWrapped = true, ZIndex = 13, Parent = card })
		Theme.label({ Position = UDim2.fromOffset(0, 48), Size = UDim2.new(1, 0, 0, 70), Text = perk.description, Font = Theme.FONT_BODY, TextColor3 = C.muted, TextWrapped = true, ZIndex = 13, Parent = card })
		Theme.label({ Position = UDim2.fromOffset(0, 118), Size = UDim2.new(1, 0, 0, 22), Text = "Owned: " .. perk.stacks, Font = Theme.FONT_BODY, TextColor3 = C.gold, ZIndex = 13, Parent = card })
		local choose = Theme.button({ AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 44), Text = "Choose", ZIndex = 13, Parent = card }, Color3.fromRGB(170, 90, 255))
		choose.Activated:Connect(function()
			local station = StationController.nearest()
			if station and station.kind == "Evolution" then
				StationController.send(station, index)
			end
			evolveModal.Visible = false
		end)
	end
	evolveModal.Visible = true
end

local function onSnapshot(snap: Types.Snapshot)
	local evo = snap.evolution
	evoTitle.Text = "EVOLUTION " .. evo.level
	evoSub.Text = "All income x" .. NumberFormat.format(StateController.big(evo.multiplier))
	if evo.requirement then
		local progress = StateController.big(evo.progress)
		local requirement = StateController.big(evo.requirement)
		-- Log-scale progress feels fair across many orders of magnitude.
		local ratio = if progress.m > 0 then math.clamp(BigNumber.log10(progress) / BigNumber.log10(requirement), 0, 1) else 0
		evoFill.Size = UDim2.fromScale(ratio, 1)
		evoFill.BackgroundColor3 = if evo.canEvolve then C.gold else Color3.fromRGB(200, 120, 255)
	else
		evoFill.Size = UDim2.fromScale(1, 1)
		evoSub.Text ..= "  •  MAX"
	end
	investorText.Text = string.format("Investors: %d (+%s%%)", snap.investors, NumberFormat.format(BigNumber.fromNumber(snap.investorBonus * 100)))
	refreshPrompt()
end

local function refreshBattery()
	local snap = StateController.snapshot()
	if not snap or (snap.autoClicker.tier == 0 and not snap.autoClicker.infinite) then
		batteryText.Text = "Auto-Clicker: none"
		batteryFill.Size = UDim2.fromScale(0, 1)
		return
	end
	local auto = snap.autoClicker
	if auto.infinite then
		batteryText.Text = string.format("Auto %g/s  •  ∞", auto.clicksPerSecond)
		batteryFill.Size = UDim2.fromScale(1, 1)
		return
	end
	local charge = StateController.charge()
	batteryText.Text = string.format("Auto %g/s  •  %d/%d", auto.clicksPerSecond, charge, auto.capacity)
	batteryFill.Size = UDim2.fromScale(if auto.capacity > 0 then math.clamp(charge / auto.capacity, 0, 1) else 0, 1)
	batteryFill.BackgroundColor3 = if charge > 0 then C.gold else C.danger
end

local function applyUiConfig(config: Types.UiConfig)
	if typeof(config.accentColor) == "Color3" then
		uiConfig.accentColor = config.accentColor
	end
	if typeof(config.tapButtonScale) == "number" then
		uiConfig.tapButtonScale = math.clamp(config.tapButtonScale, 0.5, 2)
	end
	if typeof(config.showPerNanosecond) == "boolean" then
		uiConfig.showPerNanosecond = config.showPerNanosecond
	end
	if typeof(config.compactHud) == "boolean" then
		uiConfig.compactHud = config.compactHud
	end
	if config.promptPosition == "Bottom" or config.promptPosition == "Center" then
		uiConfig.promptPosition = config.promptPosition
	end
	for _, stroke in accentStrokes do
		stroke.Color = uiConfig.accentColor
	end
	tapScale.Scale = uiConfig.tapButtonScale
	prompt.AnchorPoint = if uiConfig.promptPosition == "Center" then Vector2.new(0.5, 0.5) else Vector2.new(0.5, 1)
	prompt.Position = if uiConfig.promptPosition == "Center" then UDim2.fromScale(0.5, 0.62) else UDim2.new(0.5, 0, 1, -18)
end

local function updateScale()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local viewport = camera.ViewportSize
	local base = math.min(viewport.X / 1280, viewport.Y / 760)
	scale.Scale = math.clamp(base, 0.5, 1.25) * (if uiConfig.compactHud then 0.85 else 1)
end

local function onFrame()
	local currency = StateController.displayCurrency()
	currencyLabel.Text = NumberFormat.format(currency)
	suffixLabel.Text = NumberFormat.suffixName(currency) or ""
	local rate = StateController.rate()
	if uiConfig.showPerNanosecond and BigNumber.gte(rate, PER_NS_THRESHOLD) then
		rateLabel.Text = "+" .. NumberFormat.format(BigNumber.div(rate, NANOSECONDS), { decimals = 1 }) .. " / nanosecond"
	else
		rateLabel.Text = "+" .. NumberFormat.formatRate(rate)
	end
	refreshPromptButtons(currency)
end

local function promptBuy(ten: boolean)
	local station = StationController.nearest()
	if not station then
		return
	end
	if station.kind == "Evolution" then
		openEvolveModal()
		return
	end
	StationController.send(station, if ten then 10 else 1)
end

function HudController.init()
	gui = Theme.make("ScreenGui", {
		Name = "OceanHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	scale = Instance.new("UIScale")
	scale.Parent = gui

	buildCurrency()
	buildEvolution()
	buildStatus()
	buildPrompt()
	buildToasts()
	buildEvolveModal()

	buyOne.Activated:Connect(function()
		promptBuy(false)
	end)
	buyTen.Activated:Connect(function()
		promptBuy(true)
	end)
	tapButton.Activated:Connect(function()
		StationController.interact(1)
	end)
	extraButton.Activated:Connect(function()
		local station = StationController.nearest()
		if not station then
			return
		end
		if station.kind == "Battery" and Monetization.BATTERY_OVERCHARGE_PRODUCT_ID ~= 0 then
			MarketplaceService:PromptProductPurchase(player, Monetization.BATTERY_OVERCHARGE_PRODUCT_ID)
		elseif station.kind == "AutoClicker" and Monetization.INFINITE_AUTO_CLICKER_PASS_ID ~= 0 then
			MarketplaceService:PromptGamePassPurchase(player, Monetization.INFINITE_AUTO_CLICKER_PASS_ID)
		end
	end)

	StateController.snapshotChanged:Connect(onSnapshot)
	StateController.notified:Connect(function(n: Types.Notification)
		toast(n.kind, n.text, if n.amount then StateController.big(n.amount) else nil)
	end)
	StateController.uiConfigChanged:Connect(function(config: Types.UiConfig)
		applyUiConfig(config)
		updateScale()
	end)
	StationController.nearestChanged:Connect(function(_station: StationDef?)
		refreshPrompt()
		evolveModal.Visible = false
	end)
	StationController.clicked:Connect(clickPopup)
	StationController.choiceRequested:Connect(function(_station: StationDef)
		openEvolveModal()
	end)

	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end
	updateScale()
	applyUiConfig(uiConfig)

	RunService.RenderStepped:Connect(onFrame)
	task.spawn(function()
		while true do
			refreshBattery()
			task.wait(0.25)
		end
	end)
end

return HudController
