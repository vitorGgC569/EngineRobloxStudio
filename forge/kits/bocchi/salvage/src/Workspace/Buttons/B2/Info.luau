local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Balance = require(ReplicatedStorage.Balance)
local Bocculty = require(ReplicatedStorage.Bocculty)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.TheFirstDifficulty

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #2"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			return Balance.new():set("Bocchi", 2)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `you need more BOCCHI. x{ButtonInfo.Effect.Generation.Mul(1):toString()} gain.`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 8)
end

return ButtonInfo
