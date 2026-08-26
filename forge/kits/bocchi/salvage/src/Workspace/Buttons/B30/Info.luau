local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.FelixTheA

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #1"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	OnPurchase = function()
		local operations = require(script.Parent.Parent["B6"].Info).Formula.operations
		operations[1].base -= 9
		Utils.RefreshButton("B6")
	end
}

ButtonInfo.Descriptions = {
	Default = `BOCCHI IS BACK IN BUSINESS! !!! !!!!! log of bocchi playtime boost is decreased by number of exclamation marks`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 800e6)
end

return ButtonInfo
