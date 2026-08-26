return function (context)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local ButtonController = require(ServerScriptService.Controllers.ButtonController)
	ButtonController.AmountsPerButton = {}
	ButtonController:RefreshButtons()
end