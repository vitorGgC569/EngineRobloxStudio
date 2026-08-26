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

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #3"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	OnPurchase = function()
		
	end,
}

ButtonInfo.Descriptions = {
	Default = `BOCCHIRIUM ORB now gives 3X BOCCHI and 2X NIJIKA!!!!!!`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 35e6):set("Nijika", 2000)
end

ButtonInfo.Roots = {"B22"}

return ButtonInfo
