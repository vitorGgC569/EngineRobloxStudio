--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local constants = require(ReplicatedStorage.constants)
local Lumin = require(ReplicatedStorage.Packages.framework)
local Packets = require(ReplicatedStorage.Packets)

local ButtonInteractionController = {}
ButtonInteractionController.__index = ButtonInteractionController

local WHITE = Color3.new(1, 1, 1)

local buyEffectsPerDifficulty = (function()
	local buyEffects = {} :: {[string]: {BuySound: number, BuyVFX: (Model) -> ()}}
	for i, module in pairs(ReplicatedStorage.BuyEffects:GetChildren()) do
		if (module:IsA("ModuleScript")) then
			buyEffects[module.Name] = require(module)
		end
	end
	return buyEffects
end)()

function ButtonInteractionController:Init()
	Packets.buttonBought.listen(function(data)
		local buyEffects = buyEffectsPerDifficulty[data.difficulty]
		if (buyEffects ~= nil) then
			local buySound = Instance.new("Sound")
			buySound.SoundId = "rbxassetid://" .. buyEffects.BuySound
			buySound.Parent = workspace.Buttons
			buySound:Play()
			buyEffects.BuyVFX(workspace.Buttons:FindFirstChild(data.button))
		end
	end)
	
	
	for i, button in pairs(constants.BUTTONS) do
		if (not button:IsA("Model")) then
			continue
		end
		local buttonPart = button:WaitForChild("Button")
		local highlight = Instance.new("Highlight")
		highlight.FillColor = WHITE
		highlight.FillTransparency = 0.95
		highlight.OutlineColor = WHITE
		highlight.Enabled = false
		highlight.Parent = buttonPart
		local clickDetector = Instance.new("ClickDetector")
		
		local function refreshClickDetector()
			clickDetector.MaxActivationDistance = button:GetAttribute("Buyable") and 32 or 2
		end
		button:GetAttributeChangedSignal("Buyable"):Connect(refreshClickDetector)
		refreshClickDetector()
		
		clickDetector.MouseHoverEnter:Connect(function()
			if (button:GetAttribute("Buyable") == true) then
				highlight.Enabled = true
			end
		end)
		clickDetector.MouseHoverLeave:Connect(function()
			highlight.Enabled = false
		end)
		clickDetector.MouseClick:Connect(function()
			if (button:GetAttribute("Buyable") == true) then
				local id = button.Name
				Packets.buyButton.send({ button = id })
			end
		end)
		
		clickDetector.Parent = buttonPart
	end
end


return ButtonInteractionController