local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local constants = require(ReplicatedStorage.constants)

return {
	BuySound = 135905058425248,
	BuyVFX = function(buttonModel: Model)
		local electricVFX = constants.ASSETS.VFX.Strikes:Clone()
		electricVFX.Enabled = false
		electricVFX.Parent = buttonModel.Button
		electricVFX:Emit(5)
		Debris:AddItem(electricVFX)
	end
}
