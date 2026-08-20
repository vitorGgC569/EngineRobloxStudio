--!strict
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local AtmosphereMood = {}
AtmosphereMood.__index = AtmosphereMood

function AtmosphereMood.new(player: Player)
	local self = setmetatable({}, AtmosphereMood)
	self.player = player
	self:bindLowHealthEffect()
	return self
end

function AtmosphereMood:bindLowHealthEffect()
	local function onCharacter(character: Model)
		local hum = character:WaitForChild("Humanoid") :: Humanoid
		local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")

		hum.HealthChanged:Connect(function(health)
			if cc then
				local ratio = health / hum.MaxHealth
				if ratio < 0.3 then
					-- Low Health Red Pulsing Vignette
					cc.TintColor = Color3.fromRGB(255, 180, 180)
				else
					cc.TintColor = Color3.fromRGB(220, 235, 255)
				end
			end
		end)
	end

	if self.player.Character then
		onCharacter(self.player.Character)
	end
	self.player.CharacterAdded:Connect(onCharacter)
end

return AtmosphereMood
