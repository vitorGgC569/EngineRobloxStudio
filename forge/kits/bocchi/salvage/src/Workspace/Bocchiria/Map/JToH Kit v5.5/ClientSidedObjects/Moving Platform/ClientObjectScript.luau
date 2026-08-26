--i accidentally lost the revamp of this script somehow ahahahahahahaahaha
--i'm in pain why do i have to do this again

return function()
	script.Parent.Platform.AlignPosition.Attachment1 = script.Parent.Positions.a1.Attachment
	script.Parent.Platform.AlignOrientation.Attachment1 = script.Parent.Positions.a1.Attachment
	script.Parent.Platform.Anchored = false
	if script.Parent:FindFirstChild("InvisiblePositions") and script.Parent.InvisiblePositions.Value then
		for _, p in pairs(script.Parent.Positions:GetChildren()) do
			if p:IsA"BasePart" then
				p.Transparency = 1
				p.CanCollide = false --this is probably completely useless
				p.Size = Vector3.new() --otherwise, funky hitboxes
			end
		end
	end
	while wait() do
		for i = 1, #script.Parent.Positions:GetChildren() do
			local nextpos = script.Parent.Positions['a' .. i]
			script.Parent.Platform.AlignPosition.Attachment1 = nextpos.Attachment
			script.Parent.Platform.AlignOrientation.Attachment1 = nextpos.Attachment
			wait(script.Parent:FindFirstChild("Delay") and script.Parent.Delay.Value or 5)
		end
	end
end