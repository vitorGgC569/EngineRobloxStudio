local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.Unimpossible

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #1"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		Add = function(amount: number)
			return Balance.new():set("Nijika", 1)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `they CONNECT LIKE HOW YOU CONNECT WITH BOCCHI!. thats right. START PRODUCING +{ButtonInfo.Effect.Generation.Add(1):toString()}/S!!!!!`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 50000)
end

ButtonInfo.Roots = {"B12", "B9"}

return ButtonInfo
