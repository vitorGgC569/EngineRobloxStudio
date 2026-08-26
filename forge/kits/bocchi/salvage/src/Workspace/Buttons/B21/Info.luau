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

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #4"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Shrine = {
		Mul = function()
			return Balance.new():set("Guitars", 3)
		end,
	}
}

ButtonInfo.Descriptions = {
	Default = `all this holy nijika light is making you UNFAITHFUL to bocchi. x{ButtonInfo.Effect.Shrine.Mul(1):toString()} if you continue PRAYING TO BOCCHI`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 4000000)
end


return ButtonInfo
