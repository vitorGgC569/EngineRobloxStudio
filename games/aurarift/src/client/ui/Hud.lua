--!strict
--[[
	Hud — what the player reads, and the two buttons that are not the summon.

	Left card: what you have -- Rift, Gems, and the rate the Rift arrives at.
	Right card: what it is worth -- Power, best Floor -- and the door into
	the aura index. Beside it, the daily gift, pulsing only while it is owed.

	Built once, updated in place. Rebuilding a widget on every StateSync is
	how an interface flickers on every tick of an income loop, and the income
	loop here ticks more than once a second.

	The parent, not a ScreenGui. The client bootstrap owns the one screen;
	this module mounts into a container that already exists, so every panel
	shares one inset, one display order and one cleanup point.

	Every interactive element clears 44 pixels on its short edge -- Roblox's
	own minimum for a thumb -- and nothing is ever parked off-screen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local UI = Forge.UI
local Icons = UI.ItchIcons

local Theme = require(script.Parent.Theme)

local Hud = {}

--: A drawn icon, or nothing. The catalogue is published art, not a
--: guarantee: a token that does not resolve removes the picture and leaves
--: the readout, which is the acceptable failure -- a blank square is not.
local function icon(parent: Instance, token: string, size: number, pos: UDim2,
                    color: Color3): ImageLabel?
	local image = Instance.new("ImageLabel")
	image.Name = "Icon"
	image.BackgroundTransparency = 1
	image.Size = UDim2.fromOffset(size, size)
	image.Position = pos
	image.ImageColor3 = color
	image.ScaleType = Enum.ScaleType.Fit
	image.ZIndex = 3
	image.Parent = parent
	if not Icons.apply(image, token) then
		image:Destroy()
		return nil
	end
	return image
end

function Hud.mount(parent: Instance, scope: any)
	local state: any = {}

	-- ------------------------------------------------------------- economy
	local riftCard = UI.panel(parent, {
		name = "RiftCard",
		size = UDim2.fromOffset(240, 72),
		pos = UDim2.fromOffset(16, 12),
		color = Theme.color.panel,
	})
	riftCard.ZIndex = 10

	UI.label(riftCard, "AURA RIFT", {
		name = "Title",
		font = Theme.font.title,
		size = Theme.text.xs,
		color = Theme.color.gold,
		pos = UDim2.fromOffset(12, 6),
		frameSize = UDim2.new(1, -24, 0, 14),
	})
	local rateText = UI.label(riftCard, "+0/s", {
		name = "Rate",
		font = Theme.font.bold,
		size = Theme.text.xs,
		color = Theme.color.textDim,
		align = Enum.TextXAlignment.Right,
		pos = UDim2.fromOffset(12, 6),
		frameSize = UDim2.new(1, -24, 0, 14),
	})
	icon(riftCard, "economy.coin", 18, UDim2.fromOffset(12, 24), Theme.color.gold)
	local riftText = UI.label(riftCard, "0", {
		name = "Rift",
		font = Theme.font.bold,
		size = Theme.text.lg,
		color = Theme.color.gold,
		pos = UDim2.fromOffset(34, 22),
		frameSize = UDim2.new(1, -46, 0, 26),
	})
	icon(riftCard, "economy.gem", 14, UDim2.fromOffset(12, 52), Theme.color.gem)
	local gemsText = UI.label(riftCard, "0", {
		name = "Gems",
		font = Theme.font.bold,
		size = Theme.text.sm,
		color = Theme.color.gem,
		pos = UDim2.fromOffset(32, 50),
		frameSize = UDim2.new(1, -44, 0, 18),
	})

	-- -------------------------------------------------------------- power
	local powerCard = UI.panel(parent, {
		name = "PowerCard",
		size = UDim2.fromOffset(250, 72),
		pos = UDim2.new(1, -72, 0, 12),
		anchor = Vector2.new(1, 0),
		color = Theme.color.panel,
	})
	powerCard.ZIndex = 10

	icon(powerCard, "combat.sword", 18, UDim2.fromOffset(12, 22), Theme.color.text)
	local powerText = UI.label(powerCard, "0", {
		name = "Power",
		font = Theme.font.bold,
		size = Theme.text.md,
		color = Theme.color.text,
		pos = UDim2.fromOffset(34, 20),
		frameSize = UDim2.new(0, 100, 0, 22),
	})
	icon(powerCard, "nav.map", 14, UDim2.fromOffset(12, 48), Theme.color.gold)
	local floorText = UI.label(powerCard, "FLOOR 0", {
		name = "Floor",
		size = Theme.text.sm,
		color = Theme.color.textDim,
		pos = UDim2.fromOffset(32, 46),
		frameSize = UDim2.new(0, 102, 0, 18),
	})
	UI.button(powerCard, "AURAS", {
		name = "Auras",
		size = UDim2.fromOffset(96, 44),
		pos = UDim2.fromOffset(142, 14),
		color = Theme.color.panelAlt,
		strokeColor = Theme.color.accent,
		textColor = Theme.color.text,
		onClick = function()
			scope.open("index")
		end,
	})

	-- -------------------------------------------------------------- daily
	local daily = UI.button(parent, "", {
		name = "Daily",
		size = UDim2.fromOffset(48, 48),
		pos = UDim2.new(1, -16, 0, 12),
		anchor = Vector2.new(1, 0),
		color = Theme.color.panelAlt,
		strokeColor = Theme.color.gold,
		radius = Theme.radius.md,
		onClick = function()
			local dailyState = state.daily
			if type(dailyState) == "table" and dailyState.canClaim == true then
				scope.send("ClaimDaily", {})
			end
		end,
	})
	daily.ZIndex = 10

	--: The pulse is a second, ring-shaped stroke over the button's own. It
	--: runs only while a claim is actually owed -- a gift that beats forever
	--: is a gift the eye learns to ignore.
	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.BackgroundTransparency = 1
	glow.Size = UDim2.new(1, -4, 1, -4)
	glow.Position = UDim2.fromOffset(2, 2)
	glow.ZIndex = 1
	glow.Parent = daily
	UI.corner(glow, Theme.radius.md)
	local glowStroke = UI.stroke(glow, Theme.color.gold, 2, 0.9)

	icon(daily, "economy.chest", 26, UDim2.new(0.5, -13, 0.5, -13), Theme.color.gold)

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.new(1, 6, 0, -6)
	badge.Size = UDim2.fromOffset(16, 16)
	badge.BackgroundColor3 = Theme.color.danger
	badge.BorderSizePixel = 0
	badge.Visible = false
	badge.ZIndex = 3
	badge.Parent = daily
	UI.corner(badge, Theme.radius.pill)
	UI.label(badge, "!", {
		name = "Mark",
		font = Theme.font.bold,
		size = Theme.text.xs,
		color = Color3.new(1, 1, 1),
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.fromScale(1, 1),
	})

	local pulse: Tween? = nil

	local function setDaily(canClaim: boolean)
		badge.Visible = canClaim
		daily.BackgroundTransparency = if canClaim then 0 else 0.55
		if canClaim then
			if pulse == nil then
				glowStroke.Transparency = 0.9
				pulse = TweenService:Create(glowStroke, TweenInfo.new(
					1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
					{ Transparency = 0.15 })
				pulse:Play()
			end
		else
			if pulse then
				pulse:Cancel()
				pulse = nil
			end
			glowStroke.Transparency = 0.9
		end
	end

	-- -------------------------------------------------------------- update
	local function update(next: any)
		if type(next) ~= "table" then
			return
		end
		for key, value in next do
			state[key] = value
		end

		riftText.Text = if type(state.rift) == "string" then state.rift else "0"
		rateText.Text = "+" .. (if type(state.rate) == "string" then state.rate else "0") .. "/s"
		gemsText.Text = tostring(state.gems or 0)
		powerText.Text = if type(state.powerText) == "string" then state.powerText else "0"
		floorText.Text = "FLOOR " .. tostring(state.floor or 0)

		local dailyState = state.daily
		setDaily(type(dailyState) == "table" and dailyState.canClaim == true)
	end

	return {
		update = update,
	}
end

return Hud
