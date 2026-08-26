return function (context, button: string, amount: number)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local ButtonController = require(ServerScriptService.Controllers.ButtonController)
	local Utils = require(ReplicatedStorage.Utils)
	ButtonController:SetButtonAmount(button, amount)
	ButtonController:RefreshButtons()
	Utils.ClearCache()
end