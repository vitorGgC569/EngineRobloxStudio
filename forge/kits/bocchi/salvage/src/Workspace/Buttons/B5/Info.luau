local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Balance = require(ReplicatedStorage.Balance)
local Bocculty = require(ReplicatedStorage.Bocculty)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.TheFirstDifficulty

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #4"
ButtonInfo.MaxAmount = 3

ButtonInfo.Effect = {
	Generation = {
		Add = function(amount: number)
			return Balance.new():set("Bocchi", amount * 2)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `+{ButtonInfo.Effect.Generation.Add(1):toString()} TO THE PRODUCTION RATE OF BOCCHIS BEFORE MULTIPLICATION. WE NEED MORE BOCCHIS.`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", nextAmount * 50)
end

ButtonInfo.Roots = {"B2"}

return ButtonInfo
