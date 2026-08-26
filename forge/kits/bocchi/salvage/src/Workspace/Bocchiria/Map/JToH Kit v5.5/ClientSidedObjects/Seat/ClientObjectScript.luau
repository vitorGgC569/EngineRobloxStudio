return function()
	local value
	if script.Parent.Name == "ButtonActivatedPlatform" or script.Parent:FindFirstChild("ButtonActivated") then
		value=Instance.new('BoolValue',script.Parent)
		value.Name='Activated'
		if script.Parent:FindFirstChild("Invert") then
			value.Value = true
		end
	end

	script.Parent.TopSurface = "Smooth"
	local UIS = game:GetService("UserInputService")
	local sitting = false
	local cansit = true
	local sit = 0
	local player = game.Players.LocalPlayer
	local seat = script.Parent
	local sc = (script.Parent:FindFirstChild("SitCooldown") and script.Parent.SitCooldown.Value) or 3
	local weld
	local function detectJump(char)
		local h = char:WaitForChild"Humanoid"
		UIS.JumpRequest:Connect(function()
			if sitting then
				local newsit = sit
				sitting = false
				if weld then
					weld:Destroy()
				end
				local hrp = h.Parent:FindFirstChild("HumanoidRootPart")
				hrp.CFrame = CFrame.new(hrp.Position)
				if h:GetState() ~= Enum.HumanoidStateType.Jumping then
					h:ChangeState(Enum.HumanoidStateType.Jumping)
					h.Parent:FindFirstChild("Left Leg").Massless = true
					h.Parent:FindFirstChild("Right Leg").Massless = true
				end
				task.wait(sc)
				if sit == newsit then
					cansit = true
					h.Parent:FindFirstChild("Left Leg").Massless = false
					h.Parent:FindFirstChild("Right Leg").Massless = false
				end
			end
		end)
		h.Died:Connect(function()
			local newsit = sit
			sitting = false
			if weld then
				weld:Destroy()
			end
			task.wait(sc)
			if sit == newsit then
				cansit = true
				h.Parent:FindFirstChild("Left Leg").Massless = false
				h.Parent:FindFirstChild("Right Leg").Massless = false
			end
		end)
	end
	if player.Character then
		detectJump(player.Character)
	end
	player.CharacterAdded:Connect(detectJump)
	seat.Touched:Connect(function(t)
		local h = t.Parent:FindFirstChild"Humanoid"
		local act=script.Parent:FindFirstChild("Activated")
		local hrp = t.Parent:FindFirstChild"HumanoidRootPart"
		if h and hrp and h.Health >= 0 and not sitting and cansit and h.Sit == false and game.Players:GetPlayerFromCharacter(t.Parent) == player then
			if (act and act.Value ~= false) or not act then
				sitting = true
				cansit = false
				sit = sit+1
				h.Sit = true
				hrp.CFrame = (seat.CFrame * CFrame.new(0,seat.Size.Y/2+1.5,0))
				weld = Instance.new("WeldConstraint")
				weld.Part0 = seat
				weld.Part1 = hrp
				weld.Parent = seat			
			end
		end
	end)
end