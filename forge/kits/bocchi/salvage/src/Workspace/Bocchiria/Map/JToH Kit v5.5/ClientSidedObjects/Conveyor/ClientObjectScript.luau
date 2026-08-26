return function()
	script.Parent.FrontSurface = "Studs"

	if script.Parent.Anchored then
		script.Parent.Velocity = script.Parent.CFrame.LookVector * script.Parent.Speed.Value
	else
		local connection
		connection = game:GetService("RunService").Heartbeat:Connect(function()
			if script.Parent == nil or not script.Parent:IsDescendantOf(workspace) or not script.Parent:FindFirstChild("Speed") then connection:Disconnect() end
			script.Parent.Velocity = script.Parent.CFrame.LookVector * script.Parent.Speed.Value
		end)
	end
end