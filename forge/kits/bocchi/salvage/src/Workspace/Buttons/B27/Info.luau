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

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #2"
ButtonInfo.MaxAmount = 1

ButtonInfo.Formula = Formula.new():div(200):add(200):log(20):pow(1.1):div(4):add(1) :: Formula.Formula
ButtonInfo.FormulaVariable = "guitars"

local headingLabel = script.Parent.Button.SurfaceGui.Frame.Cost.HeadingLabel
ButtonInfo.Effect = {
	Generation = {
		IsVariable = true,
		Mul = function(amount: number)
			local boost = ButtonInfo.Formula:apply(Utils.Currencies:get("Guitars"))
			headingLabel.Text = "currently " .. boost .. "x 😭"
			return Balance.new():set("Nijika", boost)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `what is a guitar anymore... why do guitars boost nijikas 😭😭😭`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 75e6):set("Nijika", 6000)
end

ButtonInfo.Roots = {"B24"}

return ButtonInfo
