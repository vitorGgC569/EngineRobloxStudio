local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.A

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #1"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Shrine = {
		Mul = function()
			return Balance.new():set("Guitars", 4)
		end,
	}
}

ButtonInfo.Descriptions = {
	Default = `yawn. x{ButtonInfo.Effect.Shrine.Mul(1):toString()} gain`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 20000000)
end

ButtonInfo.Roots = {"B23"}


return ButtonInfo
