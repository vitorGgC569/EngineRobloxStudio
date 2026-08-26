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

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #-1"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			return Balance.new():set("Bocchi", 1.365)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `WHAT HAVE YOU DONE... YOU MADE BOCCHI NEGATIVE.......... I END YOU`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 5e15)
end

ButtonInfo.Roots = {"B13"}

return ButtonInfo
