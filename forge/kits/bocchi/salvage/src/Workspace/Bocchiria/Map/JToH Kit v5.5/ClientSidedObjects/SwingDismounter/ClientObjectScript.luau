local players = game:GetService("Players")

return function()
	script.Parent.Touched:Connect(function(t)
		if players:GetPlayerFromCharacter(t.Parent) == players.LocalPlayer and t.Parent:FindFirstChild("Humanoid") ~= nil then
			local swingDismount = t.Parent.Humanoid:FindFirstChild("SwingDismount")
			if swingDismount then
				
				if script.Parent:FindFirstChild("NoJump") and script.Parent.NoJump.Value then
					local noJumpSignal = Instance.new("BoolValue", swingDismount)
					noJumpSignal.Name = "NoJumpSignal"
				end
				
				swingDismount.Value = true
			end
		end
	end)
end