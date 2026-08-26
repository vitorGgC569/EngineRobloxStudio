local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.Negativity

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #3"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			return Balance.new():set("Bocchi", Utils.Currencies:get("Bocchi"):lessThan(100000) and 2 or 1.5)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `you BETTER BE GRATEFUL. BOCCHI IS GOING OUT OF HER WAY TO GIVE YOU A BOOST. x2 Bocchi gain if less than 100K bocchis. if NOT, 1.5X. HUH. WHERES YOUR GRATITUDE`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 17000)
end

return ButtonInfo
