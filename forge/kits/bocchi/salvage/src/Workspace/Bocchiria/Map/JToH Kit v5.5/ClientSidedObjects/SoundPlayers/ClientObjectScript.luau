local debris = game:GetService("Debris")
local players = game:GetService("Players")

local function playSound(snd,parent)
	local sndc = snd:Clone()
	sndc.Parent = parent
	sndc:Play()
	debris:AddItem(sndc,sndc.TimeLength+1)
end

local function configCheck(config, configValue)
	local foundValue = config:FindFirstChild(configValue)
	if foundValue == nil then return false end

	return (foundValue:IsA("ValueBase") and not (foundValue:IsA("BoolValue") and foundValue.Value == false))
end

local function evaluateToucher(part,touch)
	local config = part:FindFirstChild("Configurations")
	if config == nil then return end

	if not touch.Parent then return false end

	local correctColor = not (configCheck(config,"ColorSpecific") and touch.Color ~= part.Color)

	local yesplr = configCheck(config,"SupportPlayers") and players:GetPlayerFromCharacter(touch.Parent) == players.LocalPlayer
	local yesbox = configCheck(config,"SupportPushboxes") and (touch.Name == "Pushbox" or touch:FindFirstChild("IsBox") ~= nil) and correctColor
	local yesballoon = configCheck(config,"SupportBalloons") and touch.Name == "Part" and touch.Material == Enum.Material.Neon and touch:FindFirstChild("BodyVelocity") and correctColor --this bool is so long :(
	local yesturret = configCheck(config,"SupportTurrets") and touch.Name == "Bullet" and correctColor

	return (yesplr or yesbox or yesballoon or yesturret)
end

return function()
	for _,part in pairs(script.Parent:GetDescendants()) do
		local config = part:FindFirstChild("Configurations")
		local snd = part:FindFirstChildOfClass("Sound")
		
		if part:IsA("BasePart") and part.Name == "SoundPlayer" and config ~= nil and snd ~= nil then
			local db = false
			
			if snd.TimeLength > 6 then
				local warning = script.WarningGui:Clone()
				warning.Enabled = true
				warning.Parent = part
				db = true --break the sound player
			end

			if part:FindFirstChild("ButtonActivated") then
				local act = Instance.new("BoolValue",part)
				act.Name = "Activated"
				if part:FindFirstChild("Invert") then
					act.Value = true
				end
			end

			part.Touched:Connect(function(hit)
				if part:FindFirstChild("Activated") and not part.Activated.Value then return end

				if evaluateToucher(part,hit) == true and db == false then
					db = true

					local sndParent = (configCheck(config,"GlobalEmission") and script) or part
					playSound(snd, sndParent)

					if configCheck(config,"Cooldown") and not configCheck(config,"OneTimeUse") then
						task.delay(config.Cooldown.Value,function()
							db = false
						end)
					end
				end
			end)
		end
	end
end