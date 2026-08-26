local players = game:GetService("Players")
local rs = game:GetService("ReplicatedStorage")
local tweenService = game:GetService("TweenService")
local players = game:GetService("Players")

local zonePriorities = {}

function tween(part,twtime,inf,es,ed)
	local tweeninf=TweenInfo.new(
		twtime,
		((es ~= nil and es) or Enum.EasingStyle.Linear),
		((ed ~= nil and ed) or Enum.EasingDirection.Out)
	)
	local tw=tweenService:Create(part,tweeninf,inf)
	tw:Play()
	tw.Completed:Connect(function()
		tw:Destroy()
	end)
end

local function roundColor(color: Color3): Color3
	return Color3.fromRGB(math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255))
end

local function configCheck(config, configValue)
	local foundValue = config:FindFirstChild(configValue)
	if foundValue == nil then return false end

	return (foundValue:IsA("ValueBase") and not (foundValue:IsA("BoolValue") and foundValue.Value == false))
end

local function evaluateToucher(part,touch)
	local configFolder = part:FindFirstChild("Configurations")
	if configFolder == nil then return end

	if not touch.Parent then return false end

	local yesplr = (configCheck(configFolder,"SupportPlayers") and players:GetPlayerFromCharacter(touch.Parent) == players.LocalPlayer)

	local colorSpecific = not (configCheck(configFolder,"ColorSpecific") and (roundColor(touch.Color) ~= roundColor(part.Color)))
	local yesbox = (configCheck(configFolder,"SupportPushboxes") and (touch.Name == "Pushbox" or touch:FindFirstChild("IsBox") ~= nil) and colorSpecific)

	return (yesplr or yesbox)
end


return function()
	local path = rs:WaitForChild("Background Music"):WaitForChild("BackgroundMusicZones")

	for _,part in pairs(script.Parent:GetDescendants()) do
		local configFolder = part:FindFirstChild("Configurations")
		
		if part:IsA("BasePart") and part.Name == "MusicZoneEditor" and configFolder ~= nil then
			local cooldown = (configCheck(configFolder,"Cooldown") and configFolder.Cooldown.Value) or 1
			local volume = (configCheck(configFolder,"Volume") and configFolder.Volume.Value) or 0.5
			local priority = (configCheck(configFolder,"Priority") and configFolder.Priority.Value) or 1
			local speed = (configCheck(configFolder,"Speed") and configFolder.Speed.Value) or 1

			local db = false
			
			if part:FindFirstChild("ButtonActivated") then
				local act = Instance.new("BoolValue",part)
				act.Name = "Activated"
				if part:FindFirstChild("Invert") then
					act.Value = true
				end
			end
			
			part.Touched:Connect(function(t)
				if evaluateToucher(part,t) and db == false and not (part:FindFirstChild("Activated") and not part.Activated.Value) then
					local zone = path:FindFirstChild(configFolder.ZoneName.Value)
					if zone ~= nil then
						db = true

						zone.Priority.Value = priority
						for _,snd in pairs(zone.Music:GetChildren()) do
							if snd:IsA("Sound") then
								if configCheck(configFolder,"ChangeTimePosition") then
									snd.TimePosition = configFolder.ChangeTimePosition.TimePosition.Value
								end
								if speed ~= snd.PlaybackSpeed then
									tween(snd,.5,{PlaybackSpeed = speed})
								end
								snd:SetAttribute("OriginalVolume",volume)
							end
						end

						if not configCheck(configFolder,"OneTimeUse") then
							task.delay(cooldown,function()
								db = false
							end)
						end
					end
				end
			end)
		end
	end
end