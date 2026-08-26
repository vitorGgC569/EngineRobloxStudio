local ts = game:GetService("TweenService")


local easingStyle = Enum.EasingStyle.Linear --FEEL FREE TO EDIT THIS
local easingDirection = Enum.EasingDirection.Out --FEEL FREE TO EDIT THIS


local function roundColor(color: Color3): Color3
	return Color3.fromRGB(math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255))
end

local function configCheck(config, configValue)
	local foundValue = config:FindFirstChild(configValue)
	if foundValue == nil then return false end

	return (foundValue:IsA("ValueBase") and not (foundValue:IsA("BoolValue") and foundValue.Value == false))
end

local function tween(part,twTime,inf)
	local tweeninf=TweenInfo.new(
		twTime,
		easingStyle,
		easingDirection
	)
	local tw=ts:Create(part,tweeninf,inf)
	tw:Play()
	tw.Completed:Connect(function()
		tw:Destroy()
	end)
end

return function()
	local part = script.Parent
	local easingTime = (configCheck(script.Parent,"ChangeTime") and script.Parent.ChangeTime.Value) or 0
	local speed = (configCheck(script.Parent,"Speed") and script.Parent.Speed.Value) or 75
	local colorSpecific = configCheck(script.Parent,"ColorSpecific")
	part.FrontSurface = Enum.SurfaceType.Smooth
	
	if part.Name == "ButtonActivatedPlatform" or part:FindFirstChild("ButtonActivated") then
		local act = Instance.new("BoolValue",part)
		act.Name = "Activated"
		if part:FindFirstChild("Invert") then
			act.Value = true
		end
	end

	part.Touched:Connect(function(hit)
		if part:FindFirstChild("Activated") and not part.Activated.Value then return end
		
		local bodyVelocity = hit:FindFirstChildOfClass("BodyVelocity")
		
		if hit.Name == "Bullet" and bodyVelocity and not (colorSpecific and roundColor(hit.Color) ~= roundColor(part.Color)) then
			if easingTime <= 0 then
				bodyVelocity.Velocity = script.Parent.CFrame.LookVector * speed
			else
				tween(bodyVelocity,easingTime,{Velocity = script.Parent.CFrame.LookVector * speed})
			end
		end
	end)
end
