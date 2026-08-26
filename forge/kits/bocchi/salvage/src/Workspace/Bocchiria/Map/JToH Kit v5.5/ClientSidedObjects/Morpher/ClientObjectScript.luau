-- Morpher by Ep_och (EloEppo)

--[[cleaned up a little in v5.5 + small new features
-inserting a "DontPlaySound" value in a button model will mute the press and tick sounds for that specific button
-each button now has an individual "ReturnSpeed" value
-parts can now morph into other shapes such as wedges, cylinders, or even mesh parts
-tweening styles are easier to find and edit in this script
]] 

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local durationGui = script:WaitForChild("DurationGui")
local pressSound = script:WaitForChild("Press")
local tickSound = script:WaitForChild("Tick")
local player = Players.LocalPlayer

local morpher = script.Parent
local morph = morpher:WaitForChild("Morph")

local DEFAULT_DURATION = 0
local DEFAULT_SPEED = .25

local TWEEN_STYLE = Enum.EasingStyle.Quad --feel free to edit this enum to change the easing style of the morpher
local TWEEN_DIRECTION = Enum.EasingDirection.Out --feel free to edit this enum to change the easing direction of the morpher

local renderStepConnection = nil

local function copyProperties(old,new)
	new.CanCollide = old.CanCollide
	new.Size = old.Size
	new.CFrame = old.CFrame
	new.Transparency = old.Transparency
	new.Color = old.Color
	new.Material = old.Material

	for _,v in pairs(old:GetChildren()) do
		local cl = v:Clone()
		cl.Parent = new
	end
end

local function getButtons()
	local buttons = {}

	for k, v in pairs(morpher:GetDescendants()) do
		if v.Name == "Button" then
			local button = v:FindFirstChild("Button")

			local newMorphs = {}
			for k, v in pairs(v:GetDescendants()) do
				if v.Name == "NewMorph" then
					table.insert(newMorphs, v)
				end
			end

			if button and #newMorphs > 0 then
				local duration = v:FindFirstChild("MorphDuration")
				local speed = v:FindFirstChild("MorphSpeed")
				local returnSpeed = v:FindFirstChild("ReturnSpeed")

				duration = duration and duration.Value or DEFAULT_DURATION
				speed = speed and speed.Value or DEFAULT_SPEED
				returnSpeed = returnSpeed and returnSpeed.Value or DEFAULT_SPEED
				buttons[button] = {NewMorphs = newMorphs, Duration = duration, Speed = speed, Return = returnSpeed}
			end
		end
	end
	return buttons
end


return function()
	local buttons = getButtons()
	local currentButton = nil

	local defaultMorph = morph:Clone()
	defaultMorph.Transparency = 1
	defaultMorph.CanCollide = false
	defaultMorph.Anchored = true
	defaultMorph.Parent = morpher
	defaultMorph:ClearAllChildren()

	local cloneMorphs = {}

	for k, v in pairs(buttons) do
		k.Touched:Connect(function(touch)
			local yesplr=k.Parent.SupportPlayers.Value and Players:GetPlayerFromCharacter(touch.Parent)==player
			local yesbox=k.Parent.SupportPushboxes.Value and (touch.Name == "Pushbox" or touch:FindFirstChild("IsBox") ~= nil)
			local yesbal=k.Parent.SupportBalloons.Value and 
				touch.Name == "Part" and touch.Material == Enum.Material.Neon and touch:FindFirstChild("BodyVelocity") 
			local yestur = k.Parent.SupportTurrets.Value and touch.Name == "Bullet"

			if (yesplr or yesbox or yesbal or yestur) and k ~= currentButton then

				if k.Parent:FindFirstChild("DontPlaySound") == nil and k:FindFirstChild("DontPlaySound") == nil then
					local pressSound = pressSound:Clone()
					pressSound.Parent = k
					pressSound:Play()
					Debris:AddItem(pressSound, 5)
				end

				local info = TweenInfo.new(v.Speed, TWEEN_STYLE, TWEEN_DIRECTION)

				for _,newMorph in pairs(v.NewMorphs) do
					if newMorph == v.NewMorphs[1] then
						TweenService:Create(k, info, {Color = newMorph.Color}):Play()
						if morph.ClassName ~= newMorph.ClassName then
							local copy = newMorph:Clone()
							copyProperties(morph,copy)
							copy.Parent = morpher
							copy.Name = "Morph"
							morph:Destroy()
							morph = copy
						end
						TweenService:Create(morph, info, {Color = newMorph.Color, Size = newMorph.Size, CFrame = newMorph.CFrame}):Play()
						morph.Material = newMorph.Material

						for _, cloneMorph in pairs(cloneMorphs) do
							task.spawn(function()
								TweenService:Create(cloneMorph, info, {Color = newMorph.Color, Size = newMorph.Size, CFrame = newMorph.CFrame}):Play()
								task.wait(v.Speed)
								cloneMorph:Destroy()
							end)
						end
					else			
						local cloneMorph = newMorph:Clone()
						cloneMorph.Parent = morpher
						copyProperties(morph,cloneMorph)
						cloneMorph.Material = newMorph.Material

						TweenService:Create(cloneMorph, info, {Color = newMorph.Color, Size = newMorph.Size, CFrame = newMorph.CFrame}):Play()

						table.insert(cloneMorphs, cloneMorph)
					end
				end

				if currentButton then
					local durationGui = currentButton:FindFirstChild("DurationGui")
					if durationGui then
						durationGui:Destroy()
					end
					TweenService:Create(currentButton, info, {Color = Color3.new(0, 0, 0)}):Play()
				end

				currentButton = k
				if renderStepConnection ~= nil then
					renderStepConnection:Disconnect()
				end

				if v.Duration > 0 then
					local durationGui = durationGui:Clone()
					durationGui.Enabled = true
					durationGui.Parent = k
					
					durationGui.TextLabel.Changed:Connect(function(property)
						if property == "Text" and (k.Parent:FindFirstChild("DontPlaySound") == nil and k:FindFirstChild("DontPlaySound") == nil) then
							tickSound:Play()
						end
					end)

					local tickSound = tickSound:Clone()
					tickSound.Parent = k
					if k.Parent:FindFirstChild("DontPlaySound") == nil and k:FindFirstChild("DontPlaySound") == nil then
						tickSound:Play()
					end

					local epoch = os.clock() -- No, it's not named after me

					renderStepConnection = RunService.RenderStepped:Connect(function()
						local elapsed = os.clock() - epoch
						local remaining = math.ceil(v.Duration - elapsed)

						if elapsed >= v.Duration then
							durationGui:Destroy()

							Debris:AddItem(tickSound, 5)	

							local info = TweenInfo.new(v.Return, TWEEN_STYLE, TWEEN_DIRECTION)

							TweenService:Create(k, info, {Color = Color3.new(0, 0, 0)}):Play()
							TweenService:Create(morph, info, {Color = defaultMorph.Color, Size = defaultMorph.Size, CFrame = defaultMorph.CFrame}):Play()
							morph.Material = defaultMorph.Material

							for _, cloneMorph in pairs(cloneMorphs) do
								task.spawn(function()
									TweenService:Create(cloneMorph, info, {Color = defaultMorph.Color, Size = defaultMorph.Size, CFrame = defaultMorph.CFrame}):Play()
									task.wait(v.Return)
									cloneMorph:Destroy()
								end)
							end

							if currentButton then
								TweenService:Create(currentButton, info, {Color = Color3.new(0, 0, 0)}):Play()
							end

							currentButton = nil
							renderStepConnection:Disconnect()
						else
							durationGui.TextLabel.Text = remaining
						end
					end)
				end
			end
		end)
	end
end