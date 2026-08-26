local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.Exist

ButtonInfo.Name = "you exist for bocchi #1"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			return Balance.new():set("Nijika", 3)
		end
	},
	Cube = {
		Mul = function(amount: number)
			return Balance.new():set("Drums", 3)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `click click click the cube x3 nijika and drums`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 5e9):set("Drums", 200)
end



return ButtonInfo
