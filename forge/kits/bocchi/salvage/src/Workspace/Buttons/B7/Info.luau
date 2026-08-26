local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.TheLowerGap

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #2"
ButtonInfo.MaxAmount = 1

ButtonInfo.Formula = Formula.new():div(200):add(200):log(20):pow(1.25):div(5):add(1) :: Formula.Formula
ButtonInfo.FormulaVariable = "bocchi"

local headingLabel = script.Parent.Button.SurfaceGui.Frame.Cost.HeadingLabel
ButtonInfo.Effect = {
	Generation = {
		IsVariable = true,
		Mul = function(amount: number)
			local boost = ButtonInfo.Formula:apply(Utils.Currencies:get("Bocchi"))
			headingLabel.Text = "CURRENTLY " .. boost .. "x"
			return Balance.new():set("Bocchi", boost)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `WE ARE BOOSTING BOCCHI BY BOCCHI. YOU DONT MESS WITH THE BOCCHER.`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 450)
end

return ButtonInfo
