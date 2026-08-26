local ts = game:GetService("TweenService")
local players = game:GetService("Players")

function tween(part,time,inf,es,ed)
	local tweeninf=TweenInfo.new(
		time,
		((es ~= nil and es) or Enum.EasingStyle.Quad),
		((ed ~= nil and ed) or Enum.EasingDirection.Out)
	)
	local tw=ts:Create(part,tweeninf,inf)
	tw:Play()
end


return function()
	local ready = true
	local oldT = script.Parent.Transparency
	local sbColor
	local sB = script.Parent:FindFirstChild("SelectionBox")
	if sB ~= nil then
		sbColor = sB.Color3
	end
	script.Parent.Touched:Connect(function(t)
		local yesplr=script.Parent.SupportPlayers.Value and players:GetPlayerFromCharacter(t.Parent)==players.LocalPlayer
		local yesbox=script.Parent.SupportPushboxes.Value and (t.Name == "Pushbox" or t:FindFirstChild("IsBox") ~= nil)
		local yesbal=script.Parent.SupportBalloons.Value and 
			t.Name == "Part" and t.Material == Enum.Material.Neon and t:FindFirstChild("BodyVelocity")
		local yestur = script.Parent.SupportTurrets.Value and t.Name == "Bullet"
		
		if (yesplr or yesbox or yesbal or yestur) and ready == true then
			ready = false
			tween(script.Parent,script.Parent.FadeTime.Value,{Transparency=1})
			task.wait(script.Parent.FadeTime.Value)
			script.Parent.CanCollide = false
			if sB ~= nil then
				sB.Color3 = Color3.fromRGB(255,0,0)
			end
			task.wait(script.Parent.RespawnTime.Value)
			script.Parent.CanCollide = true
			script.Parent.Transparency = oldT
			if sB ~= nil then
				sB.Color3 = sbColor
			end
			ready = true
		end
	end)
end