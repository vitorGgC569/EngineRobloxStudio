local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.A

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #4"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			return Balance.new():set("Nijika", Utils.Currencies:get("Nijika"):lessThan(100000) and 2 or 1.5)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `yawn BE GRATEFUL TO NIJIKA TOO. X2 NIJIKA IF LESS THAN 100K NIJIKAS, IF NOT X1.5 NIJIKA`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 17000)
end

ButtonInfo.Roots = {"B26"}


return ButtonInfo
