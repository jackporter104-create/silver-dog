--!strict
--[[
	HudController: the oceanic HUD, built in code (no external assets). Information only:
	there are NO purchase buttons. Everything is bought by stepping on floor pads (or pressing E).
	  * Currency pill: balance (extrapolated every frame) and managed income per second.
	  * Evolution badge, and a status panel with stands owned, managers and the active buff.
	  * Context prompt for the nearest pad, e.g. "[E] Buy Multiplier x16 - Cost: 1.5K", plus
	    that stand's income while you are near one of its pads.
	Restyled live by UiConfig (A/B variants and live overrides). The client does no economy math:
	it only formats and compares values the server sent.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BigNumber = require(Shared.BigNumber)
local NumberFormat = require(Shared.NumberFormat)
local Types = require(Shared.Types)
local Economy = require(Shared.Config.Economy)
local Evolution = require(Shared.Config.Evolution)
local Statues = require(Shared.Config.Statues)
local Stations = require(Shared.Config.Stations)
local Experiments = require(Shared.Config.Experiments)

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

local uiConfig: Types.UiConfig = table.clone(Experiments.UI_DEFAULTS)
local accentStrokes: { UIStroke } = {}

-- UI references, assigned in build().
local gui: ScreenGui
local scale: UIScale
local currencyLabel: TextLabel
local suffixLabel: TextLabel
local rateLabel: TextLabel
local evoTitle: TextLabel
local evoSub: TextLabel
local evoFill: Frame
local standsText: TextLabel
local buffText: TextLabel
local prompt: Frame
local promptTitle: TextLabel
local promptAction: TextLabel
local promptStand: TextLabel
local holdFill: Frame
local holdTrack: Frame
local toastList: Frame

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
	local status = panel({ Name = "Status", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 12), Size = UDim2.fromOffset(250, 92), Parent = gui })
	standsText = Theme.label({ Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -28, 0, 30), Text = "Stands 1/5", Font = Theme.FONT_BODY, TextXAlignment = Enum.TextXAlignment.Left, Parent = status })
	buffText = Theme.label({ Position = UDim2.fromOffset(14, 48), Size = UDim2.new(1, -28, 0, 30), Text = "", TextColor3 = C.gold, TextXAlignment = Enum.TextXAlignment.Left, Parent = status })
end

local function buildPrompt()
	prompt = panel({ Name = "Prompt", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -18), Size = UDim2.fromOffset(560, 132), Visible = false, Parent = gui })
	promptTitle = Theme.label({ Position = UDim2.fromOffset(16, 8), Size = UDim2.new(1, -32, 0, 34), Text = "", Parent = prompt })
	promptAction = Theme.label({ Position = UDim2.fromOffset(16, 46), Size = UDim2.new(1, -32, 0, 32), Text = "", TextColor3 = C.success, Parent = prompt })
	promptStand = Theme.label({ Position = UDim2.fromOffset(16, 84), Size = UDim2.new(1, -32, 0, 22), Text = "", Font = Theme.FONT_BODY, TextColor3 = C.muted, Parent = prompt })
	holdFill = bar(prompt, UDim2.new(0, 16, 1, -18), UDim2.new(1, -32, 0, 8), Color3.fromRGB(200, 120, 255))
	holdTrack = holdFill.Parent :: Frame
	holdTrack.Visible = false
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
		Theme.label({ Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 26), Text = "+" .. fmt(amount), TextColor3 = C.gold, Parent = frame })
	end
	task.delay(if kind == "Offline" then 7 else 3.5, function()
		local tween = TweenService:Create(frame, TweenInfo.new(0.3), { BackgroundTransparency = 1 })
		tween:Play()
		tween.Completed:Wait()
		frame:Destroy()
	end)
end

local function inputHint(): string
	return if UserInputService.KeyboardEnabled then "[E] " else "Step on: "
end

local function costLine(verb: string, cost: BigNumber, currency: BigNumber): (string, Color3)
	return inputHint() .. verb .. " - Cost: " .. fmt(cost), if BigNumber.gte(currency, cost) then C.success else C.locked
end

-- Text for the action line of the prompt. Pure formatting of server-sent values.
local function actionText(station: StationDef, snap: Types.Snapshot, currency: BigNumber): (string, Color3)
	local view = snap.stations[station.id]
	if not view then
		return "", C.muted
	end
	local kind = station.kind
	local standDef = Economy.STAND_BY_ID[station.target or ""]
	local stand = snap.stands[station.target or ""]
	if kind == "StandMain" and standDef and stand then
		if not stand.owned then
			return costLine("Unlock " .. standDef.name, StateController.big(view.cost), currency)
		elseif stand.managed then
			return standDef.managerName .. " is running this stand", C.success
		end
		return string.format("Stand here to run: +%s every %.2gs", fmt(StateController.big(stand.manualValue)), math.max(stand.interval, Economy.MIN_MANUAL_INTERVAL)), C.gold
	elseif kind == "Buff" then
		local def = Economy.BUFF_BY_ID[station.target or ""]
		local buff = snap.buffs[station.target or ""]
		if not def or not buff or view.locked then
			return "Locked: " .. (view.lockReason or ""), C.locked
		end
		local active = StateController.remaining(buff.activeRemaining)
		if active > 0 then
			return string.format("Active: x%d on all stands, %s left", def.multiplier, secondsText(active)), C.gold
		end
		local cooldown = StateController.remaining(buff.cooldownRemaining)
		if cooldown > 0 then
			return "Recharging: " .. secondsText(cooldown), C.locked
		end
		return string.format("%sActivate: x%d Global Cash for %ds", inputHint(), def.multiplier, def.duration), C.success
	elseif kind == "Evolve" then
		local perk = Evolution.PERK_BY_ID[station.target or ""]
		if view.maxed then
			return "You are fully evolved!", C.success
		elseif view.locked then
			return "Locked: " .. (view.lockReason or ""), C.locked
		end
		return string.format("Stand on the pad %ds to EVOLVE with %s: %s", Evolution.CONFIRM_SECONDS, if perk then perk.name else "?", if perk then perk.description else ""), Color3.fromRGB(220, 170, 255)
	end
	if view.locked then
		return "Locked: " .. (view.lockReason or ""), C.locked
	end
	local cost = StateController.big(view.cost)
	if kind == "Multiplier" then
		if view.maxed then
			return "Multiplier maxed!", C.success
		end
		return costLine("Buy Multiplier x" .. fmt(BigNumber.pow(BigNumber.fromNumber(2), view.level + 1)), cost, currency)
	elseif kind == "Speed" then
		if view.maxed then
			return "Max speed reached!", C.success
		end
		return costLine("Buy Speed x" .. 2 ^ (view.level + 1), cost, currency)
	elseif kind == "Manager" and standDef then
		if view.maxed then
			return standDef.managerName .. " is hired!", C.success
		end
		return costLine("Hire " .. standDef.managerName, cost, currency)
	elseif kind == "Statue" then
		if view.maxed then
			return "Raised! Its power is yours forever", C.success
		end
		return costLine("Raise " .. station.displayName, cost, currency)
	end
	return "", C.muted
end

local function titleFor(station: StationDef): string
	local kind: string = station.kind
	if kind == "Evolve" then
		return "Evolution Temple"
	elseif kind == "Buff" then
		return "Global Buff: " .. station.displayName
	elseif kind == "Statue" then
		local def = Statues.BY_ID[station.target or ""]
		local source = if def and Economy.STAND_BY_ID[def.source] then Economy.STAND_BY_ID[def.source].name elseif def then def.source else ""
		return station.displayName .. (if def then string.format(" (x%s %s)", fmt(BigNumber.fromNumber(def.multiplier)), source) else "")
	end
	local standDef = Economy.STAND_BY_ID[station.stand or ""]
	if standDef and kind ~= "StandMain" then
		return standDef.name .. " • " .. station.displayName
	end
	return station.displayName
end

local function standLine(station: StationDef, snap: Types.Snapshot): string
	local standId = station.stand
	local stand = standId and snap.stands[standId]
	if not standId or not stand or not stand.owned then
		return ""
	end
	local def = Economy.STAND_BY_ID[standId]
	local rate = StateController.big(stand.rate)
	local how = if stand.managed then "managed" else "by hand"
	return string.format("%s income: %s (%s) • x%s value • %.2gs cycle", def.name, NumberFormat.formatRate(rate), how, fmt(BigNumber.pow(BigNumber.fromNumber(2), stand.multiplier)), stand.interval)
end

local function refreshPrompt(currency: BigNumber)
	local station = StationController.nearest()
	local snap = StateController.snapshot()
	if not station or not snap then
		prompt.Visible = false
		return
	end
	prompt.Visible = true
	promptTitle.Text = titleFor(station)
	local text, color = actionText(station, snap, currency)
	promptAction.Text = text
	promptAction.TextColor3 = color
	promptStand.Text = standLine(station, snap)
	local hold = StationController.evolveHoldProgress()
	holdFill.Size = UDim2.fromScale(hold, 1)
	holdTrack.Visible = hold > 0
end

local function onSnapshot(snap: Types.Snapshot)
	local evo = snap.evolution
	evoTitle.Text = "EVOLUTION " .. evo.level
	evoSub.Text = "All income x" .. fmt(StateController.big(evo.multiplier))
	if evo.requirement then
		local progress = StateController.big(evo.progress)
		local requirement = StateController.big(evo.requirement)
		-- Log-scale progress feels fair across many orders of magnitude.
		local ratio = if progress.m > 0 then math.clamp(BigNumber.log10(progress) / BigNumber.log10(requirement), 0, 1) else 0
		evoFill.Size = UDim2.fromScale(ratio, 1)
		evoFill.BackgroundColor3 = if evo.canEvolve then C.gold else Color3.fromRGB(200, 120, 255)
		if evo.canEvolve then
			evoSub.Text ..= "  •  READY!"
		end
	else
		evoFill.Size = UDim2.fromScale(1, 1)
		evoSub.Text ..= "  •  MAX"
	end
	local owned, managed = 0, 0
	for _, def in Economy.STANDS do
		local stand = snap.stands[def.id]
		if stand and stand.owned then
			owned += 1
			if stand.managed then
				managed += 1
			end
		end
	end
	standsText.Text = string.format("Stands %d/%d  •  Managers %d", owned, #Economy.STANDS, managed)
end

local function refreshBuff()
	local snap = StateController.snapshot()
	if not snap then
		return
	end
	local bestName, bestMult, bestLeft = nil, 1, 0
	for _, def in Economy.BUFFS do
		local buff = snap.buffs[def.id]
		local left = if buff then StateController.remaining(buff.activeRemaining) else 0
		if left > 0 and def.multiplier > bestMult then
			bestName, bestMult, bestLeft = def.name, def.multiplier, left
		end
	end
	buffText.Text = if bestName then string.format("x%d Global Cash • %s", bestMult, secondsText(bestLeft)) else "No buff active"
	buffText.TextColor3 = if bestName then C.gold else C.muted
end

local function applyUiConfig(config: Types.UiConfig)
	if typeof(config.accentColor) == "Color3" then
		uiConfig.accentColor = config.accentColor
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
	currencyLabel.Text = fmt(currency)
	suffixLabel.Text = NumberFormat.suffixName(currency) or ""
	local rate = StateController.rate()
	if uiConfig.showPerNanosecond and BigNumber.gte(rate, PER_NS_THRESHOLD) then
		rateLabel.Text = "+" .. NumberFormat.format(BigNumber.div(rate, NANOSECONDS), { decimals = 1 }) .. " / nanosecond"
	else
		rateLabel.Text = "+" .. NumberFormat.formatRate(rate)
	end
	refreshPrompt(currency)
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

	StateController.snapshotChanged:Connect(onSnapshot)
	StateController.notified:Connect(function(n: Types.Notification)
		toast(n.kind, n.text, if n.amount then StateController.big(n.amount) else nil)
	end)
	StateController.uiConfigChanged:Connect(function(config: Types.UiConfig)
		applyUiConfig(config)
		updateScale()
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
			refreshBuff()
			task.wait(0.25)
		end
	end)
end

return HudController
