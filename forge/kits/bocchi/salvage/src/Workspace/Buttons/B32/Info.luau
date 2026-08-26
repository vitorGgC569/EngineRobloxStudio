local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.FelixTheA

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #3"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Shrine = {
		Pow = function()
			return Balance.new():set("Guitars", 1.05)
		end
	},
	Cube = {
		Mul = function()
			return Balance.new():set("Drums", 2)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `x2 drums... ............ .......... .... ........ ...... and ^1.05 guitars huh what is a ^?`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 2e9)
end

return ButtonInfo
