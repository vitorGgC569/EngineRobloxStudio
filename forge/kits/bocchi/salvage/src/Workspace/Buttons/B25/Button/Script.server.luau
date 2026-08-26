local TweenService = game:GetService("TweenService")

local function rainbowEffect(basePart, dur)
	local t1 = TweenService:Create(basePart, TweenInfo.new(dur), {
		Color = Color3.new(1, 0, 0),
	})
	local t2 = TweenService:Create(basePart, TweenInfo.new(dur), {
		Color = Color3.new(1, 1, 0),
	})
	local t3 = TweenService:Create(basePart, TweenInfo.new(dur), {
		Color = Color3.new(0, 1, 0),
	})
	local t4 = TweenService:Create(basePart, TweenInfo.new(dur), {
		Color = Color3.new(0, 1, 1),
	})
	local t5 = TweenService:Create(basePart, TweenInfo.new(dur), {
		Color = Color3.new(0, 0, 1),
	})
	local t6 = TweenService:Create(basePart, TweenInfo.new(dur), {
		Color = Color3.new(1, 0, 1),
	})
	local c1 = t1.Completed:Connect(function()
		return t2:Play()
	end)
	local c2 = t2.Completed:Connect(function()
		return t3:Play()
	end)
	local c3 = t3.Completed:Connect(function()
		return t4:Play()
	end)
	local c4 = t4.Completed:Connect(function()
		return t5:Play()
	end)
	local c5 = t5.Completed:Connect(function()
		return t6:Play()
	end)
	local c6 = t6.Completed:Connect(function()
		return t1:Play()
	end)
	t1:Play()
	local endRainbow = function()
		c1:Disconnect()
		c2:Disconnect()
		c3:Disconnect()
		c4:Disconnect()
		c5:Disconnect()
		c6:Disconnect()
	end
	basePart.Destroying:Once(function()
		return endRainbow()
	end)
	return endRainbow
end

rainbowEffect(script.Parent.Ring, 2)
rainbowEffect(script.Parent.Line, 2)