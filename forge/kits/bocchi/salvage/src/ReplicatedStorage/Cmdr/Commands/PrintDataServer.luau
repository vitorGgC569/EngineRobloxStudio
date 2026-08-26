return function (context, button: number, amount: number)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local DataController = require(ServerScriptService.Controllers.DataController)
	print(DataController.ServerProfile.Data)
end