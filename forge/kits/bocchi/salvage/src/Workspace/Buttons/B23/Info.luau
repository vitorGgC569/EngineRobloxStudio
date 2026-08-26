local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.TrueEase

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #2"
ButtonInfo.MaxAmount = 1

local headingLabel = script.Parent.Button.SurfaceGui.Frame.Cost.HeadingLabel
ButtonInfo.Effect = {
	OnPurchase = function()
		Utils.AddShrineVirtualPlayer(1)
	end,
}

ButtonInfo.Descriptions = {
	Default = `i can't believe bocchi would do this! bocchi shrine prays by itself. NOOOOOO`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 15e6)
end


return ButtonInfo
