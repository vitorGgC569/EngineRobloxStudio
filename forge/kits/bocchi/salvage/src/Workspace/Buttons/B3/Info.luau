local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Balance = require(ReplicatedStorage.Balance)
local Bocculty = require(ReplicatedStorage.Bocculty)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.TheFirstDifficulty

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #3"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			return Balance.new():set("Bocchi", 3)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `COME ON MORE BOCCHI GO GO GO GO X{ButtonInfo.Effect.Generation.Mul(1):toString()} GAIN`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 20)
end

return ButtonInfo
