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

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #4"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			return Balance.new():set("Bocchi", 1.365)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `x{ButtonInfo.Effect.Generation.Mul(1):toString()} gain.........nothing to see here.......`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 62000000)
end

ButtonInfo.Roots = {"B10"}

return ButtonInfo
