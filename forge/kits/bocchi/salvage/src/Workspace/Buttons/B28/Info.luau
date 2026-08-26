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

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #3"
ButtonInfo.MaxAmount = 1

local headingLabel = script.Parent.Button.SurfaceGui.Frame.Cost.HeadingLabel
ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			headingLabel.Text = "😭😭😭😭😭😭😭😭"
			return Balance.new():set("Bocchi", 2):set("Nijika", 0.5)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `im sorry nijika... im so sorry 😭😭😭 KILL half your nijikas for x2 bocchis 😭😭😭😭😭😭😭😭`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 245e6):set("Nijika", 12000)
end


return ButtonInfo
