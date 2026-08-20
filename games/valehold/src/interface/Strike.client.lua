--!strict
-- The client half of the RPG: pressing a key asks the server to swing.
--
-- The remote carries *intent* and nothing else. A client that reports its own
-- damage is a client that reports whatever it likes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local strike = ReplicatedStorage:WaitForChild("Strike")

UserInputService.InputBegan:Connect(function(input, typing)
	if typing then
		return
	end
	if input.KeyCode == Enum.KeyCode.E
		or input.UserInputType == Enum.UserInputType.MouseButton1 then
		strike:FireServer()
	end
end)

-- Touch: a tap anywhere that is not the movement stick swings.
if UserInputService.TouchEnabled then
	UserInputService.TouchTapInWorld:Connect(function()
		strike:FireServer()
	end)
end
