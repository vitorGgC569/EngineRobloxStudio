local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.Unimpossible

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #4"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			return Balance.new():set("Bocchi", 2)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `if i was a bocchi would you be my nijika? x{ButtonInfo.Effect.Generation.Mul(1):toString()} gain`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 360000)
end

ButtonInfo.Roots = {"B15"}

return ButtonInfo
