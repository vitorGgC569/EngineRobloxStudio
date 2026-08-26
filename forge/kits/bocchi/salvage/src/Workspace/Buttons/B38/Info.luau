local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.ReversedPeripherality

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #1"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		Pow = function()
			return Balance.new():set("Bocchi", 1.02)
		end,
	}
}

ButtonInfo.Descriptions = {
	Default = `womp WOMP CAPS LOCK IS BACK LETS GOOO ^{ButtonInfo.Effect.Generation.Pow(1):toString()}`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 40e9)
end


return ButtonInfo
