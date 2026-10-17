--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Save = Forge.Save
local Debug = Forge.Debug

local Progression = {}

function Progression.start()
	Players.PlayerAdded:Connect(function(player)
		-- profile loaded via Save.observe in init; nothing extra here
	end)
	Debug.info("progression started")
end

return Progression