return function()
	script.Parent.Touched:Connect(function(t)
		local h=t.Parent:FindFirstChild'Humanoid'
		if h and h:FindFirstChild'JumpBoost' then
			h.JumpBoost:Destroy()
		end
	end)
end