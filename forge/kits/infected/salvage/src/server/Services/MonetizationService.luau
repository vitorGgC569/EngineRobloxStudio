--!strict
-- Single centralized ProcessReceipt (Roblox requirement: exactly one per game).
-- Idempotent: every granted receipt ID is recorded in the buyer's profile before
-- returning PurchaseGranted; retried receipts short-circuit to granted.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local MonetizationService = {}
MonetizationService.__index = MonetizationService

export type Deps = {
	dataService: any,
	economyService: any,
}

function MonetizationService.new(deps: Deps)
	local self = setmetatable({}, MonetizationService)
	self._deps = deps
	return self
end

function MonetizationService:_grant(player: Player, productId: number): boolean
	local products = GameConfig.Products.DevProducts
	local data = self._deps.dataService:get(player)
	if data == nil then
		return false
	end
	if productId == products.Coins1000 then
		data.coins += 1000
	elseif productId == products.Coins5000 then
		data.coins += 5000
	elseif productId == products.Coins12000 then
		data.coins += 12000
	elseif productId == products.CrateKey1 then
		self._deps.economyService:openCrate(player, "robux")
	elseif productId == products.CrateKey5 then
		for _ = 1, 5 do
			self._deps.economyService:openCrate(player, "robux")
		end
	elseif productId == products.PatientZeroToken then
		data.pzTokens += 1
	else
		warn(`[Monetization] Unknown product id {productId}`)
		return false
	end
	self._deps.dataService:sync(player)
	return true
end

function MonetizationService:start()
	MarketplaceService.ProcessReceipt = function(receiptInfo)
		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if player == nil then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		local data = self._deps.dataService:get(player)
		if data == nil then
			return Enum.ProductPurchaseDecision.NotProcessedYet -- profile not loaded yet; retry
		end
		local receiptKey = tostring(receiptInfo.PurchaseId)
		if data.receipts[receiptKey] == true then
			return Enum.ProductPurchaseDecision.PurchaseGranted -- already granted (retry)
		end
		local ok = self:_grant(player, receiptInfo.ProductId)
		if not ok then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		data.receipts[receiptKey] = true
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

return MonetizationService
