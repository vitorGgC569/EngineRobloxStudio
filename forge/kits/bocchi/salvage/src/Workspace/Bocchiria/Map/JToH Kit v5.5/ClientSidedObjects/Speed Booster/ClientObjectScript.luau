local ts=game:GetService'TweenService'
function tween(part,time,inf)
	local tweeninf=TweenInfo.new(
		time,
		Enum.EasingStyle.Linear,
		Enum.EasingDirection.Out
	)
	local tw=ts:Create(part,tweeninf,inf)
	tw:Play()
end
local val
local instant = script.Parent:FindFirstChild("Instant") and script.Parent.Instant.Value == true
return function()
	script.Parent.Touched:Connect(function(t)
		local h=t.Parent:FindFirstChild'Humanoid'
		if h and not h:FindFirstChild'SpeedBoost' then
			local v=Instance.new('NumberValue',h)
			v.Name='SpeedBoost'
			v.Value=script.Parent.BoostLength.Value
			tween(h,(instant and 0) or .5,{WalkSpeed=script.Parent.WalkSpeed.Value})
			repeat
				v.Value=v.Value-.1
				wait(.1)
			until not v or not v.Parent or v.Value<=0
			tween(h,(instant and 0) or .5,{WalkSpeed=16})
			for _,c in pairs(h:GetChildren()) do
				if c.Name=='SpeedBoost' then
					c:Destroy()
				end
			end
		else
			if h and h:FindFirstChild("SpeedBoost") then
				h.SpeedBoost.Value=script.Parent.BoostLength.Value
			end
		end
	end)
end