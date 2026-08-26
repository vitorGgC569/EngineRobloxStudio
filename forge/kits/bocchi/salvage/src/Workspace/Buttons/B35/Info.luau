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

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #3"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			return Balance.new():set("Nijika", 1.2121)
		end
	},
}

ButtonInfo.Descriptions = {
	Default = `can you quit already`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Guitars", 50000)
end



return ButtonInfo
