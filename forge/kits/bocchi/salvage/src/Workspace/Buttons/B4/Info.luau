local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Balance = require(ReplicatedStorage.Balance)
local Bocculty = require(ReplicatedStorage.Bocculty)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.TheFirstDifficulty

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #5"
ButtonInfo.MaxAmount = 1

ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			return Balance.new():set("Bocchi", 1.1)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `bocchi is NOT happy with you. x{ButtonInfo.Effect.Generation.Mul(1):toString()} gain.`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 20)
end

ButtonInfo.Roots = {"B3"}

return ButtonInfo
