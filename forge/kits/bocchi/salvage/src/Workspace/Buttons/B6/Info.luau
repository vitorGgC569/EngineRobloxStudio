local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.TheLowerGap

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #1"
ButtonInfo.MaxAmount = 1

ButtonInfo.Formula = Formula.new():log(15):pow(1.1):div(3):add(1) :: Formula.Formula
ButtonInfo.FormulaVariable = "playtime"

local headingLabel = script.Parent.Button.SurfaceGui.Frame.Cost.HeadingLabel
ButtonInfo.Effect = {
	Generation = {
		IsVariable = true,
		Mul = function(amount: number)
			local boost = ButtonInfo.Formula:apply(Utils.Playtime)
			headingLabel.Text = "currently " .. boost .. "x"
			return Balance.new():set("Bocchi", boost)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `THIS IS AN XK-CLASS SCENARIO. WE ARE BOOSTING BOCCHIS BY HOW LONG WE ARE MAKING BOCCHIS.`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 200)
end

return ButtonInfo
