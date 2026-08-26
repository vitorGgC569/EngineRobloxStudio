return function()
	script.Parent.Touched:Connect(function(t)
		local h=t.Parent:FindFirstChild'Humanoid'
		if h and h:FindFirstChild'SpeedBoost' then
			h.SpeedBoost:Destroy()
		end
	end)
end