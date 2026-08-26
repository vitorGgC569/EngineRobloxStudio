local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.Friendliness

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #1"
ButtonInfo.MaxAmount = 1

ButtonInfo.Formula = Formula.new():log(40):pow(1.05):div(5):add(1) :: Formula.Formula
ButtonInfo.FormulaVariable = "bocchi"

local headingLabel = script.Parent.Button.SurfaceGui.Frame.Cost.HeadingLabel
ButtonInfo.Effect = {
	Generation = {
		IsVariable = true,
		Mul = function(amount: number)
			local boost = ButtonInfo.Formula:apply(Utils.Currencies:get("Bocchi"))
			headingLabel.Text = "currently " .. boost .. "x"
			return Balance.new():set("Nijika", boost)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `a million bocchis... boost nijikas by bocchis... wait what`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 1000000)
end

ButtonInfo.Roots = {"B15"}

return ButtonInfo
