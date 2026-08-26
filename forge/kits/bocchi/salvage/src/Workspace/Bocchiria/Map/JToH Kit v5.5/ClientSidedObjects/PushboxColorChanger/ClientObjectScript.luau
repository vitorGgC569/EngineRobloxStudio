return function()
	script.Parent.Touched:Connect(function(t)
		if t.Name == "Pushbox" or t:FindFirstChild("IsBox") ~= nil then
			t.Color = script.Parent.Color
		end
	end)
end