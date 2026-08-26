local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Cmdr = require(ReplicatedStorage:WaitForChild("CmdrClient"))
Cmdr:SetActivationKeys({ Enum.KeyCode.F2 })

local Lumin = require(ReplicatedStorage.Packages.framework)
local Packets = require(ReplicatedStorage.Packets)

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
end
Lumin.Start(controllers)

Packets.testPacket.listen(function(data)
	print(data.message)
end)

