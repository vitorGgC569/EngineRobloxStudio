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

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #5"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			return Balance.new():set("Drums", 3)
		end
	},
}

ButtonInfo.Descriptions = {
	Default = `lets just stop`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 20e9):set("Nijika", 150000):set("Drums", 2000):set("Guitars", 150000)
end



return ButtonInfo
