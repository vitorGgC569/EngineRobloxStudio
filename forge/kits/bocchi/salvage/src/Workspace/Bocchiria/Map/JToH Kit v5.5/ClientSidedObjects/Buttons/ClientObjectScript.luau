--yup i redid this entire script :D

--got rid of the inverted button feature because its useless and made this script much more complicated
--note that you can easily use button deactivators instead for the same effect

local tweenService = game:GetService("TweenService")
local debris = game:GetService("Debris")
local players = game:GetService("Players")
local runService = game:GetService("RunService")
local coFolder = script.Parent:FindFirstAncestor("ClientSidedObjects") or script.Parent:FindFirstAncestor("ClientParts")

local cache = {
	ButtonActivatedPlatforms = {},
	Buttons = {},
}

local simpleTransparencyTypes = { --things that can have their transparency tweened
	Decal = "Transparency",
	Texture = "Transparency",
	SelectionBox = "Transparency",
	SelectionSphere = "Transparency",
	Frame = "BackgroundTransparency",
	CanvasGroup = "GroupTransparency",
	TextLabel = "TextTransparency",
	ImageLabel = "ImageTransparency",
}

local otherTypes = { --these will just have their enabled property change instead of being tweened
	"Beam",
	"ParticleEmitter",
	"Fire",
	"Sparkles",
	"Smoke",
	"Trail",
	"UIStroke",
	"UIGradient",
}

local function tween(part,twTime,inf,es,ed)
	local tweeninf=TweenInfo.new(
		twTime,
		((es ~= nil and es) or Enum.EasingStyle.Linear),
		((ed ~= nil and ed) or Enum.EasingDirection.Out)
	)
	local tw=tweenService:Create(part,tweeninf,inf)
	tw:Play()
	tw.Completed:Connect(function()
		tw:Destroy()
	end)
end

local function configCheck(config, configValue)
	local foundValue = config:FindFirstChild(configValue)
	if foundValue == nil then return false end

	return (foundValue:IsA("ValueBase") and not (foundValue:IsA("BoolValue") and foundValue.Value == false))
end

local function roundColor(color)
	return Color3.fromRGB(math.floor(color.r*255 + 0.5),math.floor(color.g*255 + 0.5),math.floor(color.b*255 + 0.5))
end

local function attachTimer(targetButton, textLabel)
	local effectGui = players.LocalPlayer.PlayerGui:FindFirstChild("EffectGUI")
	if effectGui == nil then return end

	local screenTxt=textLabel:Clone()
	local c=targetButton.ButtonPart.Color
	if textLabel:FindFirstChild("DefaultColor") then --special default color
		screenTxt.TextColor3=c
		screenTxt.TextStrokeColor3=Color3.new(1-c.r,1-c.g,1-c.b)
	end
	screenTxt.TextStrokeTransparency=0
	screenTxt.Parent=effectGui.List

	local changeFunction
	changeFunction = textLabel.Changed:Connect(function()
		if not textLabel or not textLabel.Parent then
			screenTxt:Destroy() 
			changeFunction:disconnect()
			return 
		end
		screenTxt.Text=textLabel.Text
	end)
end

local function updatePlatforms(targetButton, bool)
	local alreadyActivated = false
	
	local changeValue = {}
	
	for _,btn in pairs(cache.Buttons) do
		if btn == targetButton or roundColor(btn.ButtonPart.Color) ~= roundColor(targetButton.ButtonPart.Color) then continue end
		local targetBtnTimer = (configCheck(targetButton.Configurations,"Timer") and targetButton.Configurations.Timer.Value > 0.01)
		local btnTimer = (configCheck(btn.Configurations,"Timer") and btn.Configurations.Timer.Value > 0.01)
		local timerInvolved = targetBtnTimer or btnTimer

		local pressed = btn:FindFirstChild("Pressed")
		if pressed ~= nil then
			if (timerInvolved and pressed.Value == true) or ((not timerInvolved) and pressed.Value == bool) then
				alreadyActivated = true
			elseif not timerInvolved then
				table.insert(changeValue, pressed)
			end
		end
	end

	if alreadyActivated == true then return end
	
	for _,pressed in pairs(changeValue) do
		pressed.Value = bool
	end

	local partsActivated = 0
	local partBuffer = 64

	for _,plat in pairs(cache.ButtonActivatedPlatforms) do
		local platBool = bool
		if plat:FindFirstChild("Invert") then
			platBool = not platBool
		end

		local currentColor = plat.Color
		local override = plat:FindFirstChild("ColorOverride")
		if override ~= nil then
			currentColor = override.Value
		end
		currentColor = roundColor(currentColor)
		if currentColor ~= roundColor(targetButton.ButtonPart.Color) then continue end

		local enabledTransparency = (plat:FindFirstChild("SetTransparency") and plat.SetTransparency.Value) or 0
		local disabledTransparency = (plat:FindFirstChild'FullHide' and 1 or .6)

		local newTransparency = (platBool == true and enabledTransparency) or disabledTransparency

		for _,desc in pairs(plat:GetDescendants()) do --rip "asfd", you may or may not be missed
			for objectType,property in pairs(simpleTransparencyTypes) do
				if desc:IsA(objectType) then
					local descEnabled = (desc:FindFirstChild("SetTransparency") and desc.SetTransparency.Value) or enabledTransparency
					local descDisabled = (desc:FindFirstChild'FullHide' and 1 or disabledTransparency)

					local descNew = (platBool == true and descEnabled) or descDisabled

					tween(desc,.3,{[property]=descNew})
				end
			end
			for _,objectType in pairs(otherTypes) do
				if desc:IsA(objectType) then
					desc.Enabled = platBool
				end
			end
			if desc.Name == "Activated" and desc:IsA("BoolValue") then
				desc.Value = platBool
			end
		end

		if not (plat:FindFirstChild("IgnoreCanCollide") or plat:FindFirstChild("IgnoreAll")) then
			plat.CanCollide = platBool
		end

		if not (plat:FindFirstChild("IgnoreTransparency") or plat:FindFirstChild("Invisible") or plat:FindFirstChild("IgnoreAll")) then
			tween(plat,.3,{Transparency=newTransparency})
		end

		partsActivated += 1
		if (partsActivated % partBuffer) == 0 then
			task.wait()
		end
	end
end

local function evaluateToucher(targetButton, touch)
	if not touch.Parent then return false end
	
	local config = targetButton.Configurations

	local yesplr = (configCheck(config,"SupportPlayers") and players:GetPlayerFromCharacter(touch.Parent) == players.LocalPlayer)
	local colorSpecific = not (configCheck(config,"ColorSpecific") and (roundColor(touch.Color) ~= roundColor(targetButton.ButtonPart.Color)))
	local yesbox = (configCheck(config,"SupportPushboxes") and (touch.Name == "Pushbox" or touch:FindFirstChild("IsBox") ~= nil) and colorSpecific)
	local yesballoon = (configCheck(config,"SupportBalloons") and touch.Name == "Part" and touch.Material == Enum.Material.Neon and touch:FindFirstChild("BodyVelocity") and colorSpecific) --this bool is so long :(
	local yesturret = (configCheck(config,"SupportTurrets") and touch.Name == "Bullet" and colorSpecific)

	return (yesplr or yesbox or yesballoon or yesturret)
end


return function()
	for _,plat in pairs(coFolder:GetDescendants()) do --add any platforms existing before this script runs
		if plat:IsA("BasePart") and (plat.Name == "ButtonActivatedPlatform" or plat:FindFirstChild("ButtonActivated") ~= nil) then
			table.insert(cache.ButtonActivatedPlatforms,plat)
		end
	end
	
	coFolder.DescendantAdded:Connect(function(plat) --add any newly added button platforms
		if plat:IsA("BasePart") and (plat.Name == "ButtonActivatedPlatform" or plat:FindFirstChild("ButtonActivated") ~= nil) then
			table.insert(cache.ButtonActivatedPlatforms,plat)
		end
	end)
	
	coFolder.DescendantRemoving:Connect(function(plat)
		local index = table.find(cache.ButtonActivatedPlatforms,plat)
		if index ~= nil then
			table.remove(cache.ButtonActivatedPlatforms,index)
		end
	end)

	for _,btn in pairs(script.Parent:GetDescendants()) do
		if btn:IsA("Model") and btn.Name == "Button" then
			local buttonPart = btn:FindFirstChild("ButtonPart")
			local pressVal = btn:FindFirstChild("Pressed")
			local config = btn:FindFirstChild("Configurations")

			if buttonPart == nil or pressVal == nil or config == nil then continue end
			
			table.insert(cache.Buttons,btn)

			local sound = buttonPart:FindFirstChild("Press")
			local totalPresses = 0
			local debounce = false
			local originalCF = buttonPart.CFrame
			local pressOffset = (configCheck(config, "ButtonPressOffset") == true and config.ButtonPressOffset.Value) or .75
			local pressedCF = originalCF * CFrame.new(0,-pressOffset,0)
			
			if buttonPart:FindFirstChild("ButtonActivated")  then
				local act = Instance.new("BoolValue", buttonPart)
				act.Name = "Activated"
				act.Value = buttonPart:FindFirstChild("Invert")
			end
			
			updatePlatforms(btn,false)
			pressVal:GetPropertyChangedSignal("Value"):Connect(function()
				totalPresses += 1
				
				buttonPart.Material = (pressVal.Value == true and 'Neon') or 'Metal'
				if buttonPart.Anchored == true then
					tween(buttonPart,1,{CFrame = (pressVal.Value == true and pressedCF) or originalCF})
				end
				if pressVal.Value == true and sound and sound:IsA("Sound") then sound:Play() end
				
				updatePlatforms(btn, pressVal.Value)
			end)

			buttonPart.Touched:Connect(function(t)
				if evaluateToucher(btn,t) == true and pressVal.Value == false and debounce == false then
					if buttonPart:FindFirstChild("Activated") and not buttonPart.Activated.Value then return end
					pressVal.Value = true
					debounce = true
					task.delay(.15,function()
						debounce = false
					end)
					
					task.wait() --wait for the press value function
					if pressVal.Value == false then return end

					local useTimer = (configCheck(config,"Timer") == true and config.Timer.Value > 0.01)
					local useTimerText = (configCheck(config,"TimerText") == true and string.len(config.TimerText.Value) > 0)

					if useTimer then
						if btn:FindFirstChild("TimerLabel") == nil then return end
						
						local originalTotal = totalPresses

						local surfaceGui = Instance.new("SurfaceGui",buttonPart)
						surfaceGui.Face = Enum.NormalId.Top
						surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
						surfaceGui.PixelsPerStud = 25
						
						local label = btn.TimerLabel:Clone()
						label.Parent = surfaceGui
						if label:FindFirstChild("DefaultColor") and label.DefaultColor.Value then --special default color
							local c = buttonPart.Color
							label.TextColor3=Color3.new(1-c.r,1-c.g,1-c.b)
						end

						if useTimerText then
							label.Text = string.gsub(config.TimerText.Value,"`",config.Timer.Value) --any of these "`" characters will be reformatted as the timer value
						else
							label.Text = config.Timer.Value
						end
						surfaceGui.Parent=buttonPart
						if configCheck(config,"HideGUI") == true then
							surfaceGui.Enabled = false
						else
							attachTimer(btn,label)
						end
						
						local decimalPlaces = 0
						local placeValue = config.Timer:FindFirstChild("DecimalPlaces")
						if placeValue ~= nil and placeValue.Value > 0 then
							decimalPlaces = placeValue.Value
						end
						
						local startClock = os.clock()
						local heartbeatConnect
						heartbeatConnect = runService.Heartbeat:Connect(function()
							if (not script.Parent) or (not label) then heartbeatConnect:Disconnect() return end
							if totalPresses ~= originalTotal then heartbeatConnect:Disconnect() return end
							
							local actualTime = config.Timer.Value - (os.clock() - startClock)
							local displayTime = math.ceil(actualTime * (10^decimalPlaces)) / (10^decimalPlaces)
							
							if actualTime <= 0 then heartbeatConnect:Disconnect() return end
							
							if useTimerText then
								label.Text = string.gsub(config.TimerText.Value, "`", displayTime)
							else
								label.Text = displayTime
							end
						end)
						
						repeat task.wait() until not (heartbeatConnect and heartbeatConnect.Connected)
						
						surfaceGui:Destroy()
						if totalPresses==originalTotal then pressVal.Value=false end
					end
				end
			end)
		elseif btn:IsA("BasePart") and btn.Name == "ButtonDeactivator" then --yeah the button deactivator script is in here now lol
			local debounce = false
			
			if btn:FindFirstChild("ButtonActivated")  then
				local act = Instance.new("BoolValue", btn)
				act.Name = "Activated"
				act.Value = btn:FindFirstChild("Invert")
			end
			
			btn.Touched:Connect(function(t)
				if btn:FindFirstChild("Activated") and not btn.Activated.Value then return end
				
				local yesplr = configCheck(btn,"SupportPlayers") and players:GetPlayerFromCharacter(t.Parent) == players.LocalPlayer
				local yesbox = configCheck(btn,"SupportPushboxes") and (t.Name == "Pushbox" or t:FindFirstChild("IsBox") ~= nil)
				if (yesplr or yesbox) and debounce == false then
					debounce = true
					local colorSpecific = configCheck(btn,"ColorSpecific")
					for _,cacheBtn in pairs(cache.Buttons) do
						if not (colorSpecific and cacheBtn.ButtonPart.Color ~= btn.Color) then
							cacheBtn.Pressed.Value = false
						end
					end
					task.delay(.25,function()
						debounce = false
					end)
				end
			end)
 		end
	end
end