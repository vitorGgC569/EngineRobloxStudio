--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local constants = require(ReplicatedStorage.constants)
local Lumin = require(ReplicatedStorage.Packages.framework)
local Packets = require(ReplicatedStorage.Packets)
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)

local DetailsController = {}
DetailsController.__index = DetailsController

function DetailsController:Init()
	Packets.changeTime.listen(function(data)
		constants.INTERFACE.DetailsWindow.PlaytimeLabel.Text = "Playtime: " .. AlyaNum.toString(math.floor(data.playTime))
		constants.INTERFACE.DetailsWindow.SessionTimeLabel.Text = "Session Time: " .. AlyaNum.toString(math.floor(data.sessionTime))
	end)
end


return DetailsController