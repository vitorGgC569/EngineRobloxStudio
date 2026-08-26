return function()
	script.Parent.TopSurface = 'Studs'
	if script.Parent.Name == "ButtonActivatedPlatform" or script.Parent:FindFirstChild("ButtonActivated") then
		local a = Instance.new("BoolValue",script.Parent)
		a.Name = "Activated"
		if script.Parent:FindFirstChild("Invert") then
			a.Value = true
		end
	end
	local players = not script.Parent:FindFirstChild("IgnorePlayers")
	local boxes = not script.Parent:FindFirstChild("IgnoreBoxes")
	local speed = script.Parent:FindFirstChild("Speed") and script.Parent.Speed.Value or 40
	local maxForce = script.Parent:FindFirstChild("MaxForce") and script.Parent.MaxForce.Value or math.huge
	script.Parent.Touched:Connect(function(part)
		if script.Parent:FindFirstChild("Activated") and not script.Parent.Activated.Value then return end
		
		local torso = part.Parent:FindFirstChild("Torso") or part
		if (not torso:FindFirstChild("ElevatorVelocity") and (part.Parent:FindFirstChild("Humanoid") and players) or ((part.Name == "Pushbox" or part:FindFirstChild("IsBox") ~= nil) and boxes)) then
			local velocity = Instance.new("BodyVelocity", torso)
			velocity.Name = "ElevatorVelocity"
			local uv=script.Parent.CFrame.UpVector
			local maxf=Vector3.new(0,maxForce,0)
			if uv.X ~= 0 then maxf = Vector3.new(maxForce, maxf.Y, maxf.Z) end
			if uv.Z ~= 0 then maxf = Vector3.new(maxf.X, maxf.Y, maxForce) end
			
			velocity.MaxForce = maxf
			velocity.Velocity = script.Parent.CFrame.UpVector*speed
		end
	end)
	script.Parent.TouchEnded:Connect(function(part)
		local torso = part.Parent:FindFirstChild("Torso") or part
		if torso:FindFirstChild("ElevatorVelocity") and (part.Parent:FindFirstChild("Humanoid") and players) or ((part.Name == "Pushbox" or part:FindFirstChild("IsBox") ~= nil) and boxes) then torso.ElevatorVelocity:Destroy() end
	end)
end