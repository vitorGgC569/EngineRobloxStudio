local Players = game:GetService("Players")
local player = Players.LocalPlayer

local pushBoxSpawnButton = script.Parent
local button = pushBoxSpawnButton:WaitForChild("Button")
local pushBox = pushBoxSpawnButton:WaitForChild("Pushbox")

local currentBox = nil

local function configCheck(config, configValue)
	local foundValue = config:FindFirstChild(configValue)
	if foundValue == nil then return false end

	return (foundValue:IsA("ValueBase") and not (foundValue:IsA("BoolValue") and foundValue.Value == false))
end

local function spawnBox()
	if currentBox then
		currentBox:Destroy()
	end
	local box = pushBox:Clone()
	box.Parent = pushBoxSpawnButton
	currentBox = box
	if box:IsA("BasePart") then
		box.Anchored = false
	else
		for _,b in pairs(box:GetDescendants()) do
			if b:IsA("BasePart") and b:FindFirstChild("BoxAnchor") == nil  then
				b.Anchored = false
			end
		end
	end
	for _,bc in pairs(box:GetDescendants()) do
		if bc:IsA("ModuleScript") and bc.Name == ("PushboxScript") then
			spawn(function()
				require(bc)()
			end)
		end
	end
end

return function()
	local db = false
	button.Touched:Connect(function(touch)
		local cooldown = (configCheck(script.Parent,"Cooldown") and script.Parent.Cooldown.Value) or 0.5
		
		local colorSpecific = configCheck(script.Parent,"ButtonColorSpecific")
		local correctColor = not (colorSpecific and touch.Color ~= button.Color)
		
		local yesPlr = configCheck(script.Parent,"ButtonSupportPlayers") and Players:GetPlayerFromCharacter(touch.Parent) == player
		local yesBox = configCheck(script.Parent,"ButtonSupportPushboxes") and (touch.Name == "Pushbox" or touch:FindFirstChild("IsBox") ~= nil) and correctColor
		local yesBalloon = configCheck(script.Parent,"ButtonSupportBalloons") and touch.Name == "Part" and touch.Material == Enum.Material.Neon and touch:FindFirstChild("BodyVelocity") and correctColor
		local yesTurret = configCheck(script.Parent,"ButtonSupportTurrets") and touch.Name == "Bullet" and correctColor
		
		if (yesPlr or yesBox or yesBalloon or yesTurret) and db == false then
			spawnBox()
			db = true
			task.wait(cooldown)
			db = false
		end
	end)
	pushBox.Parent = nil
	if not configCheck(script.Parent,"DontSpawnFirst") then spawnBox() end
end