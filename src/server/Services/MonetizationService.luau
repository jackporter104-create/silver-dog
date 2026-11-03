--!strict
--[[
	MonetizationService: gamepass entitlements and developer-product receipts. Server-authoritative.

	Gamepasses (MonetizationConfig.Gamepasses):
	  * Ownership is checked with UserOwnsGamePassAsync when the player joins, and granted live
	    when PromptGamePassPurchaseFinished reports a purchase (server-side signal).
	  * Exposed to clients as player attributes (read-only for them) so the shop shows "Owned".

	Developer products (MonetizationConfig.Products), ProcessReceipt:
	  * Idempotent: the PurchaseId is recorded in the profile together with the grant, and
	    PurchaseGranted is returned only after that save succeeds. If the save fails, Roblox retries
	    the receipt later and the recorded id prevents a double grant.
	  * Unknown products, unloaded players or failed grants return NotProcessedYet (retried later).
	  * Starter Pack is one-time. A second purchase (e.g. two prompts open at once) still gives value:
	    it is converted into a Time Warp instead of being refused.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local MonetizationConfig = require(Shared.Config.MonetizationConfig)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)

type Entitlements = Types.Entitlements
type ProductHandler = (player: Player) -> boolean

local MonetizationService = {}

local PASSES = MonetizationConfig.Gamepasses
local PRODUCTS = MonetizationConfig.Products

local entitlementsByPlayer: { [Player]: Entitlements } = {}

local function ownsPass(player: Player, passId: number): boolean
	if passId == 0 then
		return false
	end
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	if not ok then
		warn("[MonetizationService] Gamepass check failed for " .. passId .. ": " .. tostring(result))
		return false
	end
	return result == true
end

local function publish(player: Player, entitlements: Entitlements)
	entitlementsByPlayer[player] = entitlements
	player:SetAttribute("OwnsDoubleIncome", entitlements.doubleIncome)
	player:SetAttribute("OwnsAutoCollect", entitlements.autoCollect)
end

-- Called once on join, before the economy session starts.
function MonetizationService.resolveEntitlements(player: Player): Entitlements
	local entitlements: Entitlements = {
		doubleIncome = ownsPass(player, PASSES.DoubleIncome.id),
		autoCollect = ownsPass(player, PASSES.AutoCollect.id),
	}
	publish(player, entitlements)
	return entitlements
end

-- ===== Products =====

local PRODUCT_HANDLERS: { [number]: ProductHandler } = {}

local function register(product: MonetizationConfig.Product, handler: ProductHandler)
	if product.id ~= 0 then
		assert(PRODUCT_HANDLERS[product.id] == nil, "Duplicate developer product id " .. product.id)
		PRODUCT_HANDLERS[product.id] = handler
	end
end

register(PRODUCTS.TimeWarp, function(player: Player): boolean
	return EconomyService.grantTimeWarp(player)
end)

register(PRODUCTS.StarterPack, function(player: Player): boolean
	local data = DataService.get(player)
	if data and data.starterPackClaimed then
		-- Already claimed: never charge for nothing.
		return EconomyService.grantTimeWarp(player)
	end
	return EconomyService.grantStarterPack(player)
end)

local function processReceipt(receipt: { [string]: any }): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player or not EconomyService.isActive(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local data = DataService.get(player)
	local purchaseId = receipt.PurchaseId
	if not data or typeof(purchaseId) ~= "string" then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if data.receipts[purchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	local handler = PRODUCT_HANDLERS[receipt.ProductId]
	if not handler then
		warn("[MonetizationService] No handler for product " .. tostring(receipt.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not handler(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	data.receipts[purchaseId] = os.time()
	if DataService.saveAsync(player, false) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	-- The grant is in memory but not saved: Roblox retries, and the recorded id stops a double grant.
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function MonetizationService.init()
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, purchased: boolean)
		if not purchased or passId == 0 then
			return
		end
		local current = entitlementsByPlayer[player]
		if not current then
			return
		end
		local updated: Entitlements = {
			doubleIncome = current.doubleIncome or passId == PASSES.DoubleIncome.id,
			autoCollect = current.autoCollect or passId == PASSES.AutoCollect.id,
		}
		publish(player, updated)
		EconomyService.setEntitlements(player, updated)
	end)
	Players.PlayerRemoving:Connect(function(player)
		entitlementsByPlayer[player] = nil
	end)
end

return MonetizationService
