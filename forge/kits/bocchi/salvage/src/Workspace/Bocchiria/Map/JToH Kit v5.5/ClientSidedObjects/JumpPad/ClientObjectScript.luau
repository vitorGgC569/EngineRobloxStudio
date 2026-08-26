local debris = game:GetService("Debris")
local players = game:GetService("Players")
local ts = game:GetService("TweenService")

function tween(part,time,inf,es,ed)
	local tweeninf=TweenInfo.new(
		time,
		((es ~= nil and es) or Enum.EasingStyle.Linear),
		((ed ~= nil and ed) or Enum.EasingDirection.Out)
	)
	local tw=ts:Create(part,tweeninf,inf)
	tw:Play()
	tw.Completed:Connect(function()
		tw:Destroy()
	end)
end

function playSoundFromPart(part,sndname)
	local snd = script:FindFirstChild(sndname)
	if snd ~= nil then
		local sndc = snd:Clone()
		sndc.Parent = part
		sndc:Play()
		debris:AddItem(sndc,sndc.TimeLength+1)
	end
end

return function()
	local db = true
	local curColor = script.Parent.Color
	local supportPlayers = script.Parent:FindFirstChild("SupportPlayers") and script.Parent.SupportPlayers.Value
	local supportBoxes = script.Parent:FindFirstChild("SupportPushboxes") and script.Parent.SupportPushboxes.Value
	
	if script.Parent.Name == "ButtonActivatedPlatform" or script.Parent:FindFirstChild("ButtonActivated") then
		local act = Instance.new("BoolValue",script.Parent)
		act.Name = "Activated"
		if script.Parent:FindFirstChild("Invert") then
			act.Value = true
		end
	end
	
	local particleAtt = script.Parent:FindFirstChild("ParticleAtt")
	if particleAtt ~= nil then
		for _,particle in pairs(particleAtt:GetChildren()) do
			if particle:IsA("ParticleEmitter") then
				particle.Color = ColorSequence.new(script.Parent.Color)
			end
		end
	end
	
	local function evaluateToucher(touch)
		if not touch.Parent then return false end

		local yesplr = supportPlayers and players:GetPlayerFromCharacter(touch.Parent) == players.LocalPlayer
		local yesbox = supportBoxes and (touch.Name == "Pushbox" or touch:FindFirstChild("IsBox") ~= nil)

		return (yesplr or yesbox)
	end
	
	script.Parent.Touched:Connect(function(hit)
		if script.Parent:FindFirstChild("Activated") and not script.Parent.Activated.Value then return end
		
		if hit.Anchored == false and db == true and evaluateToucher(hit) == true then
			db = false
			task.delay(0.05,function()
				db = true
			end)
			
			playSoundFromPart(script.Parent,"Boing")
			if particleAtt ~= nil and particleAtt:FindFirstChild("BounceParticle") ~= nil then
				particleAtt.BounceParticle:Emit(1)
				local curH, curS, curV = curColor:ToHSV()
				script.Parent.Color = Color3.fromHSV(curH,math.clamp(curS+0.125,0,1),math.clamp(curV+0.25,0,1))
				tween(script.Parent,1,{Color=curColor})
			end
			
			local bv = Instance.new("BodyVelocity")
			bv.MaxForce = Vector3.new(0, math.huge, 0)
			bv.Velocity = Vector3.new(0, script.Parent.Power.Value, 0)
			bv.Parent = hit
			debris:AddItem(bv,0.15)
		end
	end)
end