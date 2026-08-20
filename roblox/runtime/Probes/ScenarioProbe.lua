local ScenarioProbe = {}

function ScenarioProbe.run(runtime, player)
	local beforeCurrency = player:GetAttribute("Currency")
	runtime:Navigate(player, "BasicPackStore")
	runtime:Interact(player, "PurchasePrompt")
	runtime:Interact(player, "PurchasePrompt")
	local afterCurrency = player:GetAttribute("Currency")
	return {
		status = afterCurrency == beforeCurrency - 100 and #runtime:GetInventory(player) == 1 and "PASS" or "FAIL",
		currencyDelta = afterCurrency - beforeCurrency,
		inventoryCount = #runtime:GetInventory(player),
	}
end

return ScenarioProbe

