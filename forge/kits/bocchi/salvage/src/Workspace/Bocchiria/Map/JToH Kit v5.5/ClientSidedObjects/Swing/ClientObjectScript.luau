local ts=game:GetService'TweenService'
local debris=game:GetService'Debris'
local userinput=game:GetService('UserInputService')

function playSoundFromPart(part,sndname)
	local snd = script:FindFirstChild(sndname)
	if snd ~= nil then
		local sndc = snd:Clone()
		sndc.Parent = part
		sndc:Play()
		debris:AddItem(sndc,sndc.TimeLength+1)
	end
end

local function configCheck(config, configValue)
	local foundValue = config:FindFirstChild(configValue)
	if foundValue == nil then return false end

	return (foundValue:IsA("ValueBase") and not (foundValue:IsA("BoolValue") and foundValue.Value == false))
end

return function()
	local Riding = false
	local val
	for _,d in pairs(script.Parent:GetChildren()) do
		if d:IsA'Decal' then
			d.Color3=script.Parent.Color
		end
	end
	local swing = script.Parent:WaitForChild("Swing")
	local top = script.Parent:WaitForChild("Top")
	
	local val
	if swing:FindFirstChild("ButtonActivated") ~= nil then
		val=Instance.new('BoolValue',swing)
		val.Name='Activated'
		if swing:FindFirstChild("Invert") then
			val.Value = true
		end
	end
	
	local allowJumpDismount = configCheck(script.Parent,"AllowJumpDismount")
	local keepVelocity = configCheck(script.Parent,"KeepVelocity")
	local rt = (configCheck(script.Parent,"RespawnTime") and script.Parent.RespawnTime.Value) or 1
	local ropeLength = (configCheck(script.Parent,"RopeLength") and script.Parent.RopeLength.Value) or 12
	
	local oldT = swing.Transparency
	local function fixOldTransparency() --fix for button activated swing transparency
		if swing:FindFirstChild("Invisible") or swing:FindFirstChild("IgnoreTransparency") or swing:FindFirstChild("IgnoreAll") then return end
		
		if val then
			if val.Value then
				oldT = (swing:FindFirstChild("SetTransparency") and swing.SetTransparency.Value) or 0
			else
				oldT = (swing:FindFirstChild("FullHide") and 1) or 0.6
			end
		end
	end
	
	local curTween = nil
	swing.ParticleEmitter.Color = ColorSequence.new(swing.Color)
	swing.Touched:Connect(function(part)
		if game.Players:GetPlayerFromCharacter(part.Parent) == game.Players.LocalPlayer and part.Parent:FindFirstChild("Humanoid") and not (val and not val.Value) then
			if Riding ~= true then
				Riding = true
				local autodisconnect
				local h=part.Parent.Humanoid
				local root = part.Parent:FindFirstChild("HumanoidRootPart")
				if root == nil then return end
				local savedLinearVelocity = root.AssemblyLinearVelocity
				local savedAngularVelocity = root.AssemblyAngularVelocity
				if allowJumpDismount then
					userinput.JumpRequest:Connect(function()
						autodisconnect=true
					end)
				end
				if curTween ~= nil then
					curTween:Cancel()
					swing.Transparency = oldT
				end
				playSoundFromPart(swing,"Grab")
				local Rope = Instance.new("RopeConstraint")
				local Bar = Instance.new("Part")
				local P1 = Instance.new("Attachment")
				local P2 = Instance.new("Attachment")
				local Weld = Instance.new("WeldConstraint")
				local dismountVal = Instance.new("BoolValue",h)
				dismountVal.Name = "SwingDismount"
				Bar.Size = Vector3.new(3,0.4,0.4)
				Bar.TopSurface='Smooth'
				Bar.BottomSurface='Smooth'
				Bar.CanCollide = false
				Bar.CFrame = root.CFrame * CFrame.new(0,2.6,0)
				Bar.CustomPhysicalProperties = PhysicalProperties.new(10,0,0)
				Bar.Color = swing.Color
				P1.Parent = top
				P2.Parent = Bar
				Rope.Length = ropeLength
				Rope.Visible = true
				Rope.Color = swing.BrickColor
				Rope.Attachment0 = P1
				Rope.Attachment1 = P2
				Rope.Parent = top
				Bar.Parent = script.Parent
				Weld.Part0 = root
				Weld.Part1 = Bar
				Weld.Parent = Bar
				swing.Transparency = 1
				if keepVelocity then
					root.AssemblyLinearVelocity = savedLinearVelocity
					root.AssemblyAngularVelocity = savedAngularVelocity
				end
				local pos=swing.Position.Y
				repeat task.wait() until autodisconnect or dismountVal.Value == true or part.Parent:WaitForChild("Humanoid").Health<=0
				Bar:Destroy()
				Rope:Destroy()
				Weld:Destroy()
				P1:Destroy()
				P2:Destroy()
				Bar.CanCollide=true
				if not (dismountVal.Value == true and dismountVal:FindFirstChild("NoJumpSignal")) then
					part.Parent:WaitForChild("Humanoid"):ChangeState'Jumping'
					playSoundFromPart(swing,"Jump")
				end
				dismountVal:Destroy()
				if rt == 0 then
					Riding=false
					fixOldTransparency()
					swing.Transparency = oldT
				else
					task.wait(rt)
					Riding=false
					fixOldTransparency()
					curTween = ts:Create(swing,TweenInfo.new(.5,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{Transparency=oldT})
					curTween:Play()
					swing.ParticleEmitter.Enabled = true
					task.wait(1)
					swing.ParticleEmitter.Enabled = false
				end
			end
		end
	end)
end