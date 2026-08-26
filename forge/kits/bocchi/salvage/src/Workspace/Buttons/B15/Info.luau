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

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #2"
ButtonInfo.MaxAmount = 1

ButtonInfo.Formula = Formula.new():log(25):pow(1.1):div(3):add(1) :: Formula.Formula
ButtonInfo.FormulaVariable = "nijika"

local headingLabel = script.Parent.Button.SurfaceGui.Frame.Cost.HeadingLabel
ButtonInfo.Effect = {
	Generation = {
		IsVariable = true,
		Mul = function(amount: number)
			local boost = ButtonInfo.Formula:apply(Utils.Currencies:get("Nijika"))
			headingLabel.Text = "currently " .. boost .. "x"
			return Balance.new():set("Bocchi", boost)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `You need to watch out... i heard nijika was a huge boccher...... nijikas boost bocchis...`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Nijika", 20)
end

return ButtonInfo
