--!optimize 2

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local constants = require(ReplicatedStorage.constants)
local Lumin = require(ReplicatedStorage.Packages.framework)
local Packets = require(ReplicatedStorage.Packets)

local MessageController = {}
MessageController.__index = MessageController

local MESSAGE_LABEL = constants.ASSETS.MessageWindow.MessageLabel
local lastMessage: TextLabel? = nil
local repeats = 0

function MessageController:Init()
	Packets.error.listen(function(data)
		constants.ASSETS.Sounds.Error:Play()
		if (lastMessage ~= nil and lastMessage.Name == data) then
			Debris:AddItem(lastMessage, 0)
			repeats += 1
		else
			repeats = 0
		end
		local messageLabel = MESSAGE_LABEL:Clone()
		messageLabel.UIScale.Scale = 0.6
		messageLabel.Text = data .. (repeats > 0 and ` (x{repeats + 1})` or "")
		messageLabel.Name = data
		messageLabel.Parent = constants.INTERFACE.MessageWindow
		TweenService:Create(messageLabel.UIScale, TweenInfo.new(0.2), { Scale = 1 }):Play()
		task.delay(string.len(data) / 3 + 3, function()
			if (messageLabel ~= nil and messageLabel.Parent ~= nil) then
				TweenService:Create(messageLabel, TweenInfo.new(1), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
				TweenService:Create(messageLabel.UIScale, TweenInfo.new(1), { Scale = 0 }):Play()
				Debris:AddItem(messageLabel, 2)
			end
		end)
		lastMessage = messageLabel
	end)
end


return MessageController