local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Balance = require(ReplicatedStorage.Balance)
local Bocculty = require(ReplicatedStorage.Bocculty)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.TheLowerGap

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #4"
ButtonInfo.MaxAmount = 1

local headingLabel = script.Parent.Button.SurfaceGui.Frame.Cost.HeadingLabel
ButtonInfo.Effect = {
	Shrine = {
		Mul = function()
			return Balance.new():set("Guitars", 2)
		end,
	}
}

ButtonInfo.Descriptions = {
	Default = `Get TWICE AS MUCH GUITARS FROM BOCCHI SHRINE`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 4500)
end

return ButtonInfo
