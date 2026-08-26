return function()
	if script.Parent.Name == "ButtonActivatedPlatform" or script.Parent:FindFirstChild("ButtonActivated") then
		local act = Instance.new("BoolValue",script.Parent)
		act.Name = "Activated"
		if script.Parent:FindFirstChild("Invert") then
			act.Value = true
		end
	end
	
	script.Parent.Touched:Connect(function(hit)
		if game.Players:GetPlayerFromCharacter(hit.Parent) == game.Players.LocalPlayer then
			local humanoid = hit.Parent:FindFirstChild("Humanoid")
			local activated = script.Parent:FindFirstChild("Activated")
			if humanoid and ((activated and activated.Value ~= false) or not activated) then
				humanoid.Sit = true
			end
		end
	end)
end