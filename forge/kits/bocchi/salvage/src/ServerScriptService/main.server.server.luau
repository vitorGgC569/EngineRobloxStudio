local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Cmdr = require(ReplicatedStorage.Packages.cmdr)
Cmdr.Registry:RegisterDefaultCommands()
Cmdr.Registry:RegisterCommandsIn(ReplicatedStorage.Cmdr.Commands)
Cmdr.Registry:RegisterHooksIn(ReplicatedStorage.Cmdr.Hooks)

local Lumin = require(ReplicatedStorage.Packages.framework)

local todo = {}

local controllers = {}
for i, module in pairs(script.Parent.Controllers:GetChildren()) do
	if (not module:IsA("ModuleScript")) then
		continue
	end
	local controller = require(module)
	if (typeof(controller) ~= "table") then
		continue
	end
	table.insert(controllers, controller)
	table.insert(todo, function()
		if (controller.OnPlayerAdded ~= nil) then
			for i, player in pairs(Players:GetPlayers()) do
				controller:OnPlayerAdded(player)
			end
			Players.PlayerAdded:Connect(function(player)
				controller:OnPlayerAdded(player)
			end)
		end
	end)
end


Lumin.Start(controllers)
for i, v in pairs(todo) do
	task.spawn(v)
end