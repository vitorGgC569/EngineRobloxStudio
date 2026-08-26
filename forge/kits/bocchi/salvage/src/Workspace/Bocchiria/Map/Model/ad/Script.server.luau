local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local Utils = require(ReplicatedStorage.Utils)


MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, purchasedPassID, purchaseSuccess)
	if purchaseSuccess ~= true or purchasedPassID ~= Utils.DoubleBocchiPass.Id then
		script.Parent.PurchaseSound:Play()
		Utils.DoubleBocchiPass.Enabled = true
	end

	
end)

script.Parent.ClickDetector.MouseClick:Connect(function(player)
	script.Parent.PromptSound:Play()
	MarketplaceService:PromptPurchase(player, Utils.DoubleBocchiPass.Id)
end)