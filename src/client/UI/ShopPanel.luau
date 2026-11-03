--!strict
--[[
	ShopPanel: the Shell Shop, opened by stepping on the Shop pad in your reef's plaza (never from a
	HUD button). Lists the gamepasses and developer products from MonetizationConfig:
	  * id 0          -> "Coming soon" (not set up yet)
	  * owned pass    -> "Owned"  (player attributes set by MonetizationService)
	  * claimed pack  -> "Claimed" (snapshot.starterPackClaimed)
	  * otherwise     -> Robux price from MarketplaceService:GetProductInfo, and a Buy button that
	                     opens the Roblox purchase prompt. All granting happens on the server.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MonetizationConfig = require(Shared.Config.MonetizationConfig)

local StateController = require(script.Parent.Parent.Controllers.StateController)
local Theme = require(script.Parent.Theme)

local ShopPanel = {}

type Item = {
	key: string,
	isPass: boolean,
	id: number,
	name: string,
	description: string,
	color: Color3,
	ownedAttribute: string?,
}

type Card = { item: Item, button: TextButton, price: TextLabel }

local C = Theme.Colors
local player = Players.LocalPlayer
local PASSES = MonetizationConfig.Gamepasses
local PRODUCTS = MonetizationConfig.Products

local ITEMS: { Item } = {
	{ key = "DoubleIncome", isPass = true, id = PASSES.DoubleIncome.id, name = PASSES.DoubleIncome.name, description = PASSES.DoubleIncome.description, color = Color3.fromRGB(255, 200, 60), ownedAttribute = "OwnsDoubleIncome" },
	{ key = "AutoCollect", isPass = true, id = PASSES.AutoCollect.id, name = PASSES.AutoCollect.name, description = PASSES.AutoCollect.description, color = Color3.fromRGB(90, 200, 255), ownedAttribute = "OwnsAutoCollect" },
	{ key = "TimeWarp", isPass = false, id = PRODUCTS.TimeWarp.id, name = PRODUCTS.TimeWarp.name, description = PRODUCTS.TimeWarp.description, color = Color3.fromRGB(190, 130, 255) },
	{ key = "StarterPack", isPass = false, id = PRODUCTS.StarterPack.id, name = PRODUCTS.StarterPack.name, description = PRODUCTS.StarterPack.description, color = Color3.fromRGB(110, 230, 150) },
}

local root: Frame
local cards: { Card } = {}
local prices: { [number]: string } = {}

local function setButton(button: TextButton, text: string, enabled: boolean, color: Color3)
	button.Text = text
	button.Active = enabled
	button.AutoButtonColor = enabled
	button.BackgroundColor3 = if enabled then color else C.locked
end

local function refresh()
	local snap = StateController.snapshot()
	for _, card in cards do
		local item = card.item
		card.price.Text = prices[item.id] or ""
		if item.id == 0 then
			setButton(card.button, "Coming soon", false, item.color)
		elseif item.ownedAttribute and player:GetAttribute(item.ownedAttribute) == true then
			setButton(card.button, "Owned ✓", false, item.color)
		elseif item.key == "StarterPack" and snap and snap.starterPackClaimed then
			setButton(card.button, "Claimed ✓", false, item.color)
		else
			setButton(card.button, "Buy", true, item.color)
		end
	end
end

local function fetchPrice(item: Item)
	if item.id == 0 or prices[item.id] then
		return
	end
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(item.id, if item.isPass then Enum.InfoType.GamePass else Enum.InfoType.Product)
		end)
		if ok and typeof(info) == "table" and typeof((info :: any).PriceInRobux) == "number" then
			prices[item.id] = "R$ " .. tostring((info :: any).PriceInRobux)
			refresh()
		end
	end)
end

local function buy(item: Item)
	if item.id == 0 then
		return
	end
	if item.isPass then
		MarketplaceService:PromptGamePassPurchase(player, item.id)
	else
		MarketplaceService:PromptProductPurchase(player, item.id)
	end
end

function ShopPanel.init(gui: ScreenGui)
	root = Theme.make("Frame", {
		Name = "ShellShop",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.48),
		Size = UDim2.fromOffset(820, 360),
		BackgroundColor3 = C.panel,
		Visible = false,
		ZIndex = 20,
		Parent = gui,
	}, {
		Theme.corner(22),
		Theme.gradient(C.panelLight, C.deep),
		Theme.stroke(C.gold, 3),
	})
	Theme.label({ Position = UDim2.fromOffset(20, 12), Size = UDim2.new(1, -90, 0, 44), Text = "Shell Shop", TextColor3 = C.gold, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 21, Parent = root })
	local close = Theme.button({ AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 14), Size = UDim2.fromOffset(52, 44), Text = "X", ZIndex = 21, Parent = root }, C.danger)
	close.Activated:Connect(function()
		ShopPanel.close()
	end)

	local row: Frame = Theme.make("Frame", { Position = UDim2.fromOffset(20, 70), Size = UDim2.new(1, -40, 1, -90), BackgroundTransparency = 1, ZIndex = 21, Parent = root }, {
		Theme.make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 14) }),
	})
	for index, item in ITEMS do
		local card: Frame = Theme.make("Frame", { Size = UDim2.fromOffset(180, 268), BackgroundColor3 = C.deep, LayoutOrder = index, ZIndex = 21, Parent = row }, {
			Theme.corner(16),
			Theme.stroke(item.color, 3),
			Theme.padding(10),
		})
		Theme.make("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromOffset(64, 64), BackgroundColor3 = item.color, ZIndex = 22, Parent = card }, {
			Theme.corner(32),
			Theme.gradient(Color3.new(1, 1, 1), Color3.fromRGB(180, 180, 180), 45),
		})
		Theme.label({ Position = UDim2.fromOffset(0, 70), Size = UDim2.new(1, 0, 0, 30), Text = item.name, TextColor3 = item.color, ZIndex = 22, Parent = card })
		Theme.label({ Position = UDim2.fromOffset(0, 102), Size = UDim2.new(1, 0, 0, 68), Text = item.description, Font = Theme.FONT_BODY, TextWrapped = true, TextColor3 = C.foam, ZIndex = 22, Parent = card })
		local price = Theme.label({ Position = UDim2.fromOffset(0, 172), Size = UDim2.new(1, 0, 0, 24), Text = "", TextColor3 = C.gold, ZIndex = 22, Parent = card })
		local button = Theme.button({ AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 46), Text = "Buy", ZIndex = 22, Parent = card }, item.color)
		button.Activated:Connect(function()
			if button.Active then
				buy(item)
			end
		end)
		table.insert(cards, { item = item, button = button, price = price })
	end

	player:GetAttributeChangedSignal("OwnsDoubleIncome"):Connect(refresh)
	player:GetAttributeChangedSignal("OwnsAutoCollect"):Connect(refresh)
	StateController.snapshotChanged:Connect(function()
		if root.Visible then
			refresh()
		end
	end)
end

function ShopPanel.open()
	for _, item in ITEMS do
		fetchPrice(item)
	end
	refresh()
	root.Visible = true
end

function ShopPanel.close()
	root.Visible = false
end

function ShopPanel.isOpen(): boolean
	return root.Visible
end

return ShopPanel
