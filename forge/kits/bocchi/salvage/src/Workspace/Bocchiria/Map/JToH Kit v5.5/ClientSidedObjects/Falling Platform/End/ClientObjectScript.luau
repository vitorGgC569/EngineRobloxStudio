return function()
	script.Parent.CanCollide = false
	bounce = false
	
	script.Parent.Touched:Connect(function(hit)
		if hit == script.Parent.Parent.Platform then
			if bounce ~= true then
				bounce = true
				script.Parent.Parent.Platform.CanCollide = false
				script.Parent.Parent.Platform.Transparency = 0.8
				
				local oldforce = script.Parent.Parent.Platform.BodyPosition.MaxForce
				local oldp = script.Parent.Parent.Platform.BodyPosition.P
				
				script.Parent.Parent.Platform.BodyPosition.MaxForce = Vector3.new(math.huge, 5000, math.huge)
				script.Parent.Parent.Platform.BodyPosition.P = 2000
				
				wait(1.5)
				
				script.Parent.Parent.Platform.CanCollide = true
				script.Parent.Parent.Platform.Transparency = 0
				
				script.Parent.Parent.Platform.BodyPosition.MaxForce = oldforce
				script.Parent.Parent.Platform.BodyPosition.P = oldp
				bounce = false
			end
		end
	end)
end