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

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #1"
ButtonInfo.MaxAmount = 1

ButtonInfo.Formula = Formula.new():log(10):pow(1.2):div(6):add(1) :: Formula.Formula
ButtonInfo.FormulaVariable = "bocchi"

local headingLabel = script.Parent.Button.SurfaceGui.Frame.Cost.HeadingLabel
ButtonInfo.Effect = {
	Shrine = {
		IsVariable = true,
		Mul = function()
			local boost = ButtonInfo.Formula:apply(Utils.Currencies:get("Bocchi"))
			headingLabel.Text = "currently " .. boost .. "x"
			return Balance.new():set("Guitars", boost)
		end,
	}
}

ButtonInfo.Descriptions = {
	Default = `bocchi deserves ONLY THE BEST. BOCCHIS BOOST GUITARS.`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 7000000)
end


return ButtonInfo
