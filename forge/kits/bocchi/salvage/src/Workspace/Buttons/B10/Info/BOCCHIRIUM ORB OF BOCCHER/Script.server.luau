script.Parent.Activated:Connect(function()
	local button = workspace.Buttons["B10"]
	button:SetAttribute("Duration", button:GetAttribute("Duration") + 30)
	script.Parent:Destroy()
end)