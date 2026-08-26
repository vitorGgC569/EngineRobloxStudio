local model = script.Parent
local players = game:GetService("Players")
local tweenService = game:GetService("TweenService")
local coFolder = script.Parent:FindFirstAncestor("ClientSidedObjects") or script.Parent:FindFirstAncestor("ClientParts")
local buttonFolder = coFolder:FindFirstChild("Buttons")


local easingStyle = Enum.EasingStyle.Quad --FEEL FREE TO CHANGE THIS
local easingDirection = Enum.EasingDirection.Out --FEEL FREE TO CHANGE THIS


local function tween(part,twTime,inf)
	local tweeninf=TweenInfo.new(
		twTime,
		easingStyle,
		easingDirection
	)
	local tw=tweenService:Create(part,tweeninf,inf)
	tw:Play()
	tw.Completed:Connect(function()
		tw:Destroy()
	end)
end

local function teleport(part,newCF)
	if part.Anchored == true then return end
	
	if model:FindFirstChild("TransitionTime") and model.TransitionTime.Value > 0 then
		part.Anchored = true
		tween(part,model.TransitionTime.Value,{CFrame = newCF})
		task.wait(model.TransitionTime.Value)
		part.Anchored = false
	else
		part.CFrame = newCF
	end
	
	if model:FindFirstChild("KeepVelocity") and model.KeepVelocity.Value == false then
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
	end
end

return function()
	local destinations = {}
	local rb = model:FindFirstChild'RemoveButtons' and model.RemoveButtons.Value
	
	for _, tp in pairs(model:GetDescendants()) do
		if tp.Name == "Destination" then
			table.insert(destinations, tp)
		elseif tp.Name == "Teleporter" then
			if tp:FindFirstChild("ButtonActivated") then
				local a = Instance.new("BoolValue",tp)
				a.Name = "Activated"
				if tp:FindFirstChild("Invert") then
					a.Value = true
				end
			end
			
			tp.Touched:Connect(function(t)
				if tp:FindFirstChild"Activated" and not tp.Activated.Value then return end
				
				local dests = {}
				for _, d in pairs(destinations) do
					if not (d:FindFirstChild"Activated" and not d.Activated.Value) then
						table.insert(dests, d)
					end
				end
				if #dests <= 0 then return end
				local d = dests[math.random(1, #dests)]
				
				if model:FindFirstChild('TeleportPushboxes') and model.TeleportPushboxes.Value then
					if (t.Name == "Pushbox" or t:FindFirstChild("IsBox") ~= nil) then					
						d.TeleportSound:Play()
						teleport(t,d.CFrame * CFrame.new(0,5,0))
					end
				end
				
				if model:FindFirstChild('TeleportPlayers') and players:GetPlayerFromCharacter(t.Parent) == players.LocalPlayer then
					if rb then
						for _,btn in pairs(buttonFolder:GetDescendants()) do
							if btn:IsA("Model") and btn.Name == "Button" and btn:FindFirstChild("Pressed") then
								btn.Pressed.Value = false
							end
						end
					end
					
					d.TeleportSound:Play()
					teleport(t.Parent.PrimaryPart,d.CFrame * CFrame.new(0,5,0))
				end
			end)
		end
	end
end