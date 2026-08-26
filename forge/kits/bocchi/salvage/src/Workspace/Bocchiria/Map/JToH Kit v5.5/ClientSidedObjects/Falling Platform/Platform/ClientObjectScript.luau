local goldenmass = 4.8 -- this is the mass in cubic studs
local setmaxforce = true

return function()
	local totalvolume = (script.Parent.Size.X * script.Parent.Size.Y * script.Parent.Size.Z)
	
	for _, v in pairs(script.Parent:GetConnectedParts()) do
		if v ~= script.Parent then
			v.Massless = true
		end
	end
	
	script.Parent.CustomPhysicalProperties = PhysicalProperties.new(
		(1/totalvolume) * goldenmass,
		0.3, 0, --friction and elasticity
		1, 100 --friction and elasticity weights
	)
	script.Parent.BodyPosition.Position = script.Parent.Position
	script.Parent.BodyPosition.MaxForce = setmaxforce and Vector3.new(50000, 1000, 50000) or script.Parent.BodyPosition.MaxForce
	script.Parent.BodyPosition.P = setmaxforce and 2000 or script.Parent.BodyPosition.P
	script.Parent.Position = script.Parent.Position - (script.Parent.CFrame.UpVector * 2)
	
	script.Parent.Anchored = false
	
	spawn(function()
		local oldforce = script.Parent.BodyPosition.MaxForce
		local oldp = script.Parent.BodyPosition.P
		
		script.Parent.BodyPosition.MaxForce = Vector3.new(math.huge, 5000, math.huge)
		script.Parent.BodyPosition.P = 2000
		wait(0.5)
		script.Parent.BodyPosition.MaxForce = oldforce
		script.Parent.BodyPosition.P = oldp
	end)
end