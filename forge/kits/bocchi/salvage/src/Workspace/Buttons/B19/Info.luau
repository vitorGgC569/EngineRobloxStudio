local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.Friendliness

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #2"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		
	},
	OnPurchase = function()
		local operations = require(script.Parent.Parent["B15"].Info).Formula.operations
		operations[1].base -= 10
		operations[3].amount -= 1
		Utils.RefreshButton("B15")
	end
}

ButtonInfo.Descriptions = {
	Default = `nijika is an angel... right..? you agree right. BOOST BOCCHIS EVEN MORE BY NIJIKAS`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 1500000)
end


return ButtonInfo
