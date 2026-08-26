local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.TrueEase

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #5"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	WalkSpeed = 4
}

ButtonInfo.Descriptions = {
	Default = `Bocchi hates walking, just like you. +{ButtonInfo.Effect.WalkSpeed} walkspeed`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Guitars", 5e6)
end

ButtonInfo.Roots = {"B25"}


return ButtonInfo
