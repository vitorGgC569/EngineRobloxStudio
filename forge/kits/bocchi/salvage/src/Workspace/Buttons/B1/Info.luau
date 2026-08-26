local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Balance = require(ReplicatedStorage.Balance)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.TheFirstDifficulty

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #1"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		IsVariable = true,
		Add = function()
			return Balance.new():set("Bocchi", Utils.DoubleBocchiPass.Enabled == true and 2 or 1)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `START MAKING {ButtonInfo.Effect.Generation.Add(1):toString()} EVERY SECOND`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 0)
end

return ButtonInfo
