--!strict
--[[
	MonetizationService: gamepass entitlements and developer-product receipts.

	ProcessReceipt is idempotent. The purchase id is stored in the player's profile in the
	same document as the grant. PurchaseGranted is returned only after that save succeeds.
	If the save fails, Roblox retries, and the recorded id prevents a double grant.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Monetization = require(Shared.Config.Monetization)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)

local MonetizationService = {}

local PASS_ID = Monetization.DOUBLE_INCOME_PASS_ID
local TIME_WARP_ID = Monetization.TIME_WARP_PRODUCT_ID

function MonetizationService.resolveEntitlements(player: Player): Types.Entitlements
	local owns = false
	if PASS_ID ~= 0 then
		local ok, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, PASS_ID)
		end)
		owns = ok and result == true
		if not ok then
			warn("[MonetizationService] Gamepass check failed: " .. tostring(result))
		end
	end
	return { doubleIncome = owns }
end

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

	local granted = false
	if TIME_WARP_ID ~= 0 and receipt.ProductId == TIME_WARP_ID then
		granted = EconomyService.grantTimeWarp(player)
	end
	if not granted then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	data.receipts[purchaseId] = os.time()
	if DataService.saveAsync(player, false) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function MonetizationService.init()
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, purchased: boolean)
		if purchased and PASS_ID ~= 0 and passId == PASS_ID then
			EconomyService.setEntitlements(player, { doubleIncome = true })
		end
	end)
end

return MonetizationService
