--!strict
--[[
	Hud — everything the player reads, and nothing they can lie with.

	The interface has one job the game cannot do without: the charge number is
	the only thing in `brownout` that is *about to* happen. The lamps show the
	present state honestly, but a player standing in a lit ring cannot see that
	the drain has outrun the deliveries and the ring will be gone in forty
	seconds. That is what the gauge is for, and it is why the drain rate is on
	screen next to it rather than buried.

	Design rules this file follows, because agent-built Roblox UI has a
	recognisable look and all of it comes from ignoring them:

	  * Every colour and every gap comes from `UI.theme`. No literals.
	  * Nothing is on screen that is not currently actionable. The exposure bar
	    is invisible at zero; the drop hint is invisible with empty hands.
	  * Numbers that change fast are tweened, not assigned. A gauge that snaps
	    reads as a bug even when the value is right.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local UI = Forge.UI
local Ease = Forge.Core.Ease

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local T = UI.theme

local Hud = {}

--: The colours the game means, layered on top of the theme rather than
--: replacing it, so the widgets still match the panels they sit in.
local CHARGE_GOOD = Color3.fromRGB(120, 214, 255)
local CHARGE_LOW = Color3.fromRGB(236, 148, 72)
local CHARGE_CRIT = Color3.fromRGB(226, 72, 78)
local GRADE_COLOR = {
	Color3.fromRGB(118, 196, 132),
	Color3.fromRGB(122, 172, 246),
	Color3.fromRGB(232, 132, 224),
}

local function clockText(seconds: number): string
	local whole = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", whole // 60, whole % 60)
end

-- ================================== build ===================================

function Hud.build(screen: ScreenGui)
	local self = {
		screen = screen,
		--: The last state the server sent. The HUD reads from here and never
		--: keeps a second copy that could drift out of step with it.
		shift = { charge = 0, maxCharge = 100, phase = "night", clock = 0, radius = 0, night = 0, drain = 0 },
		you = { watts = 0, exposure = 0, maxExposure = 100, upgrades = {} },
		--: Set by the client bootstrap when a cell is within reach, so the
		--: prompt appears without the server being asked about every step.
		nearCell = nil :: any,
		shopOpen = false,
	}

	-- --------------------------------------------------------------- generator
	local gauge = UI.panel(screen, {
		name = "Gauge",
		size = UDim2.fromOffset(330, 96),
		pos = UDim2.new(0, T.space.lg, 0, T.space.lg),
		padding = T.space.md,
	})

	local gaugeTitle = UI.label(gauge, "GENERATOR", {
		size = T.text.xs,
		color = T.color.textDim,
		font = T.font.bold,
		frameSize = UDim2.new(1, 0, 0, 14),
	})
	gaugeTitle.Name = "Title"

	local chargeText = UI.label(gauge, "0%", {
		size = T.text.xl,
		font = T.font.bold,
		frameSize = UDim2.new(1, 0, 0, 32),
		pos = UDim2.fromOffset(0, 14),
	})

	local drainText = UI.label(gauge, "", {
		size = T.text.xs,
		color = T.color.textDim,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.new(1, 0, 0, 32),
		pos = UDim2.fromOffset(0, 16),
	})

	local chargeBar = UI.bar(gauge, {
		size = UDim2.new(1, 0, 0, 12),
		pos = UDim2.new(0, 0, 0, 52),
		color = CHARGE_GOOD,
	})

	local radiusText = UI.label(gauge, "", {
		size = T.text.xs,
		color = T.color.textDim,
		frameSize = UDim2.new(1, 0, 0, 14),
		pos = UDim2.fromOffset(0, 68),
	})

	-- ------------------------------------------------------------------- clock
	local clockPanel = UI.panel(screen, {
		name = "Clock",
		size = UDim2.fromOffset(150, 56),
		pos = UDim2.new(0.5, 0, 0, T.space.lg),
		anchor = Vector2.new(0.5, 0),
		padding = T.space.sm,
	})
	local phaseText = UI.label(clockPanel, "NIGHT 1", {
		size = T.text.xs,
		color = T.color.textDim,
		font = T.font.bold,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, 0, 0, 12),
	})
	local timeText = UI.label(clockPanel, "0:00", {
		size = T.text.lg,
		font = T.font.mono,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, 0, 0, 26),
		pos = UDim2.fromOffset(0, 14),
	})

	-- ------------------------------------------------------------------ wallet
	local wallet = UI.panel(screen, {
		name = "Wallet",
		size = UDim2.fromOffset(180, 46),
		pos = UDim2.new(0, T.space.lg, 1, -T.space.lg),
		anchor = Vector2.new(0, 1),
		padding = T.space.sm,
	})
	local wattsText = UI.label(wallet, "0 W", {
		size = T.text.lg,
		font = T.font.bold,
		color = T.color.gold,
		frameSize = UDim2.new(1, 0, 1, 0),
	})

	-- ---------------------------------------------------------------- exposure
	--[[
		Hidden at zero, and that is the whole design.

		A bar that is always on screen at full green teaches the player to stop
		looking at it, and the one moment it matters is the moment they have
		stopped. This one appears when the dark starts working on you.
	]]
	local exposurePanel = UI.panel(screen, {
		name = "Exposure",
		size = UDim2.fromOffset(220, 52),
		pos = UDim2.new(0.5, 0, 1, -110),
		anchor = Vector2.new(0.5, 1),
		padding = T.space.sm,
		visible = false,
	})
	local exposureLabel = UI.label(exposurePanel, "EXPOSURE", {
		size = T.text.xs,
		color = T.color.textDim,
		font = T.font.bold,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, 0, 0, 12),
	})
	local exposureBar = UI.bar(exposurePanel, {
		size = UDim2.new(1, 0, 0, 12),
		pos = UDim2.new(0, 0, 0, 18),
		color = T.color.danger,
	})

	-- ------------------------------------------------------------------ prompt
	--: One line, centred low, that always says the next thing to do. A player
	--: who has to work out what the game wants is a player who leaves.
	local promptLabel = UI.label(screen, "", {
		name = "Prompt",
		size = T.text.md,
		font = T.font.bold,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, 0, 0, 26),
		pos = UDim2.new(0, 0, 1, -66),
	})
	promptLabel.TextStrokeTransparency = 0.4
	promptLabel.TextStrokeColor3 = Color3.new(0, 0, 0)

	-- -------------------------------------------------------------------- shop
	local shop = UI.panel(screen, {
		name = "Shop",
		size = UDim2.fromOffset(340, 330),
		pos = UDim2.new(1, -T.space.lg, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		padding = T.space.md,
		visible = false,
	})
	UI.label(shop, "OUTFITTER", {
		size = T.text.xs,
		color = T.color.textDim,
		font = T.font.bold,
		frameSize = UDim2.new(1, 0, 0, 14),
	})
	local shopList = Instance.new("Frame")
	shopList.Name = "List"
	shopList.BackgroundTransparency = 1
	shopList.Size = UDim2.new(1, 0, 1, -22)
	shopList.Position = UDim2.fromOffset(0, 22)
	shopList.Parent = shop
	UI.list(shopList, { gap = T.space.sm })

	--: One row per upgrade, built once and updated in place. Rebuilding the
	--: list on every state push would destroy the button under the cursor mid
	--: click, which is a bug that only ever shows up when somebody is buying
	--: fast.
	local rows: { [string]: any } = {}
	for index, spec in Config.upgrades do
		local row = UI.panel(shopList, {
			name = spec.id,
			size = UDim2.new(1, 0, 0, 62),
			color = T.color.panelAlt,
			padding = T.space.sm,
			stroke = false,
		})
		row.LayoutOrder = index

		local title = UI.label(row, spec.label, {
			size = T.text.sm,
			font = T.font.bold,
			frameSize = UDim2.new(1, -70, 0, 16),
		})
		local level = UI.label(row, "", {
			size = T.text.xs,
			color = T.color.textDim,
			align = Enum.TextXAlignment.Right,
			frameSize = UDim2.new(1, 0, 0, 16),
		})
		UI.label(row, spec.detail, {
			size = T.text.xs,
			color = T.color.textDim,
			frameSize = UDim2.new(1, -70, 0, 14),
			pos = UDim2.fromOffset(0, 17),
		})
		local buy = UI.button(row, "", {
			size = UDim2.fromOffset(96, 24),
			pos = UDim2.new(1, 0, 1, 0),
			anchor = Vector2.new(1, 1),
			color = T.color.panel,
			onClick = function()
				if self.onBuy then
					self.onBuy(spec.id)
				end
			end,
		})

		rows[spec.id] = { title = title, level = level, buy = buy }
	end

	-- ----------------------------------------------------------------- vignette
	--[[
		A dark frame at the edges that closes in with exposure.

		Not `Feel.screenTint`, which is a full-screen wash: a wash hides the
		ground the player is running on at exactly the moment they most need to
		see it. A vignette darkens the periphery and leaves the centre readable,
		which is the difference between "I am in trouble" and "I cannot play".
	]]
	local vignette = Instance.new("Frame")
	vignette.Name = "Vignette"
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.BackgroundColor3 = Color3.fromRGB(90, 8, 12)
	vignette.BackgroundTransparency = 1
	vignette.BorderSizePixel = 0
	vignette.ZIndex = 0
	vignette.Parent = screen

	local vignetteGrad = Instance.new("UIGradient")
	vignetteGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.32, 0.85),
		NumberSequenceKeypoint.new(0.68, 0.85),
		NumberSequenceKeypoint.new(1, 0),
	})
	vignetteGrad.Parent = vignette

	-- ================================ updating ==============================

	local displayedCharge = 0

	function self.setShift(payload: any)
		for key, value in payload do
			self.shift[key] = value
		end
	end

	function self.setYou(payload: any)
		for key, value in payload do
			self.you[key] = value
		end
		--: `carrying` is absent rather than false when empty-handed, and a
		--: merge loop cannot copy an absent key. Cleared explicitly.
		self.you.carrying = payload.carrying
		self.refreshShop()
	end

	function self.refreshShop()
		for _, entry in self.you.upgrades or {} do
			local row = rows[entry.id]
			if not row then
				continue
			end
			row.level.Text = string.format("L%d/%d", entry.level, entry.max)
			if entry.cost then
				local affordable = (self.you.watts or 0) >= entry.cost
				row.buy.Text = string.format("%d W", entry.cost)
				row.buy.TextColor3 = if affordable then T.color.gold else T.color.textDim
			else
				row.buy.Text = "MAX"
				row.buy.TextColor3 = T.color.good
			end
		end
	end

	function self.toggleShop()
		self.shopOpen = not self.shopOpen
		shop.Visible = self.shopOpen
	end

	--[[
		The prompt, in priority order.

		Order is the design: a player carrying a cell needs to be told to run
		home even while standing next to another cell, because the thing in
		their hands is the thing that is about to be worth nothing if the lights
		go out.
	]]
	local function promptText(): (string, Color3)
		if self.you.carrying then
			local colour = GRADE_COLOR[self.you.carrying.grade] or T.color.text
			return string.format(
				"Carrying grade %d  ·  run it to the generator  ·  [Q] drop",
				self.you.carrying.grade), colour
		end
		if self.nearCell then
			local colour = GRADE_COLOR[self.nearCell.grade] or T.color.text
			return string.format("[E]  lift grade %d cell", self.nearCell.grade), colour
		end
		if self.shift.phase == "dawn" then
			return "Dawn. Spend your watts — [B]", T.color.good
		end
		local charge = self.shift.charge or 0
		if charge < 25 then
			return "The lights are going out. Find fuel.", CHARGE_CRIT
		end
		return "Head past the lamps for fuel  ·  [B] outfitter", T.color.textDim
	end

	function self.step(dt: number)
		local shift = self.shift
		local maxCharge = shift.maxCharge or 100
		local alpha = math.clamp((shift.charge or 0) / maxCharge, 0, 1)

		--: The number is eased rather than assigned, so a deposit reads as a
		--: surge rather than as a value that was suddenly different.
		displayedCharge = Ease.approach(displayedCharge, shift.charge or 0, 6, dt)
		chargeText.Text = string.format("%d%%", math.floor(displayedCharge + 0.5))

		local colour = CHARGE_GOOD
		if alpha < 0.18 then
			colour = CHARGE_CRIT
		elseif alpha < 0.42 then
			colour = CHARGE_LOW
		end
		chargeText.TextColor3 = colour
		chargeBar.fill.BackgroundColor3 = colour
		chargeBar:set(alpha)

		--: Drain shown as what it costs per second. A player who can read "-0.9
		--: %/s" against "58%" knows they have a minute, and that is the single
		--: most useful sentence the UI can say.
		drainText.Text = string.format("-%.2f %%/s", shift.drain or 0)
		radiusText.Text = string.format("light reaches %d studs", math.floor(shift.radius or 0))

		phaseText.Text = if shift.phase == "dawn"
			then "DAWN"
			else string.format("NIGHT %d", (shift.night or 0) + 1)
		timeText.Text = clockText(shift.clock or 0)
		timeText.TextColor3 = if shift.phase == "dawn" then T.color.good
			elseif (shift.clock or 0) < 60 then T.color.warning
			else T.color.text

		wattsText.Text = string.format("%d W", math.floor(self.you.watts or 0))

		local exposure = (self.you.exposure or 0) / (self.you.maxExposure or 100)
		exposurePanel.Visible = exposure > 0.02
		exposureBar:set(exposure)
		exposureLabel.TextColor3 = if exposure > 0.85 then CHARGE_CRIT else T.color.textDim

		--: The vignette leads the bar slightly — it starts closing before the
		--: damage lands, which is what makes it a warning rather than a report.
		vignette.BackgroundTransparency = 1 - math.clamp(exposure * 0.85, 0, 0.8)

		local text, promptColour = promptText()
		promptLabel.Text = text
		promptLabel.TextColor3 = promptColour
	end

	--: A deposit anywhere on the server: a brief flash in the gauge's colour.
	function self.surge(payload: any)
		local colour = GRADE_COLOR[payload.grade] or CHARGE_GOOD
		local flash = Instance.new("Frame")
		flash.Size = UDim2.fromScale(1, 1)
		flash.BackgroundColor3 = colour
		flash.BackgroundTransparency = 0.86
		flash.BorderSizePixel = 0
		flash.ZIndex = 0
		flash.Parent = screen
		TweenService:Create(flash, TweenInfo.new(0.45), { BackgroundTransparency = 1 }):Play()
		task.delay(0.5, function()
			flash:Destroy()
		end)
	end

	RunService.RenderStepped:Connect(function(dt)
		self.step(dt)
	end)

	return self
end

return Hud
