return function()
	local p = script.Parent
	local model = p.Parent
	local plr = game.Players.LocalPlayer
	local holesize = math.huge

	p.FrontSurface='Smooth'
	if p.Size.X<holesize then holesize=p.Size.X end
	if p.Size.Y<holesize then holesize=p.Size.Y end
	local bulletsize=holesize*.9
	if p.Size.Z<bulletsize then bulletsize=p.Size.Z end

	local h=Instance.new('Part')
	h.Name='Hole'
	h.CanCollide=false
	h.Color=Color3.new()
	h.Material='Neon'
	h.Shape='Cylinder'
	h.Size=Vector3.new(.1,holesize,holesize)
	h.CFrame=(p.CFrame*CFrame.new(0,0,-p.Size.Z/2))*CFrame.Angles(0,math.pi/2,0)
	h.CastShadow=false
	h.Transparency=p.Transparency

	if p.Name == "ButtonActivatedPlatform" or p:FindFirstChild("ButtonActivated") then
		local a = Instance.new("BoolValue",p)
		a.Name = "Activated"
		if p:FindFirstChild("Invert") then
			a.Value = true
		end
		p:GetPropertyChangedSignal("Transparency"):Connect(function()
			h.Transparency = p.Transparency
		end)
	end

	local w=Instance.new('WeldConstraint',p)
	w.Part0=p
	w.Part1=h
	h.Parent=p

	local presetBullet = model:FindFirstChild("Bullet")
	if presetBullet ~= nil then
		presetBullet.Parent = nil
	end

	while task.wait(model.Delay.Value) do
		local c=plr.Character
		if c and c.PrimaryPart then
			local pp=c.PrimaryPart
			if (pp.Position-p.Position).magnitude<model.Distance.Value and not (p:FindFirstChild("Activated") and p.Activated.Value == false) then
				local c=p.Fire:Clone()
				c.Name='SoundEffect'
				c.Parent=p
				c:Play()
				game.Debris:AddItem(c,2)
				local bullet
				if presetBullet ~= nil then
					bullet = presetBullet:Clone()
				else
					bullet = Instance.new("Part")
					bullet.CanCollide = false
					bullet.Color = p.Color
					bullet.Material = Enum.Material.Neon
					bullet.Shape = Enum.PartType.Ball
					bullet.Size = Vector3.new(bulletsize,bulletsize,bulletsize)
				end
				bullet.Name = 'Bullet'
				bullet.CFrame = p.CFrame
				local bv = Instance.new('BodyVelocity',bullet)
				bv.MaxForce = Vector3.new(math.huge,math.huge,math.huge)
				bv.Velocity = bullet.CFrame.lookVector*model.Speed.Value
				bullet.Parent = p
				bullet.Anchored = false
				game.Debris:AddItem(bullet,15)
				
				for _,bulletScript in pairs(bullet:GetDescendants()) do
					if bulletScript:IsA("ModuleScript") and bulletScript.Name == ("BulletScript") then
						task.spawn(function()
							require(bulletScript)()
						end)
					end
				end
				
				bullet.Touched:Connect(function(t)
					if t.Parent == nil then return end
					
					local otherplr = game:GetService("Players"):GetPlayerFromCharacter(t.Parent) ~= nil and not (t.Parent == plr.Character)
					if otherplr then return end

					local isplr = t.Parent:FindFirstChild'Humanoid' and t:IsDescendantOf(plr.Character)
					local yesplr = isplr and not (model:FindFirstChild("IgnorePlayers") and model.IgnorePlayers.Value)
					local yespart = (not isplr) and t.CanCollide and t~=p and t.Parent~=p and t:FindFirstChild("IgnoreBullets") == nil and not (model:FindFirstChild("IgnoreParts") and model.IgnoreParts.Value)

					if yesplr or yespart then
						task.wait()
						bullet:Destroy()
						if yesplr then
							game.ReplicatedStorage.DamageEvent:FireServer(model.Damage.Value)
						end
					end
				end)
			end
		end
	end
end
