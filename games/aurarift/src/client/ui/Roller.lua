--!strict
--[[
	Roller — the summon loop's controls and its reveal.

	The bottom cluster is three rungs and a button: pity progress, the batch
	chips, then the summon itself. The reveal is not a number changing --
	Wire.lua says why it travels as its own message -- so it is a takeover:
	a single card for one summon, a staggered grid for a batch, and a banner
	that reports somebody else's divine draw wherever the player is looking.

	Things that are built once and things that are built per reveal
	----------------------------------------------------------------
	Everything is built once, at mount. A reveal is a set of property writes
	over pre-built widgets, never a rebuild -- a widget destroyed and
	rebuilt mid-animation is how a reveal drops a frame exactly when the
	player is watching it.

	The debounce is a serial number, not a timer. A second summon while the
	first card is still up must not be dismissed by the first card's
	expiry, so every reveal takes the next serial and every delayed callback
	checks whether it still owns the screen.

	The cluster faces north, so the two things this file must never do are
	park anything off-screen (a gate reports it, and it is right to) and
	put text under a skinned face without checking where the face ends.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local UI = Forge.UI
local Icons = UI.ItchIcons

local Theme = require(script.Parent.Theme)

local Roller = {}

local function textOf(value: any, fallback: string): string
	if type(value) == "string" and value ~= "" then
		return value
	end
	if type(value) == "number" then
		return tostring(value)
	end
	return fallback
end

--: A drawn icon, or nothing. Same contract as the HUD's: a missing token
--: costs the picture, never the readout.
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

function Roller.mount(parent: Instance, scope: any)
	local state: any = {}

	-- ============================================================== cluster
	local cluster = Instance.new("Frame")
	cluster.Name = "Summon"
	cluster.AnchorPoint = Vector2.new(0.5, 1)
	cluster.Position = UDim2.new(0.5, 0, 1, -16)
	cluster.Size = UDim2.fromOffset(560, 136)
	cluster.BackgroundTransparency = 1
	cluster.BorderSizePixel = 0
	cluster.ZIndex = 10
	cluster.Parent = parent

	local pityText = UI.label(cluster, "PITY 0/40", {
		name = "Pity",
		font = Theme.font.bold,
		size = Theme.text.xs,
		color = Theme.color.textDim,
		align = Enum.TextXAlignment.Right,
		pos = UDim2.fromOffset(131, 0),
		frameSize = UDim2.fromOffset(90, 12),
	})
	local pityBar = UI.bar(cluster, {
		name = "PityBar",
		size = UDim2.fromOffset(200, 10),
		pos = UDim2.fromOffset(229, 1),
		color = Theme.color.gold,
		radius = 5,
	})
	pityBar:setInstant(0)

	--: Which upgrade a control belongs to. Read from state one level deep,
	--: so a StateSync that has not arrived yet reads as "not owned" rather
	--: than erroring.
	local function owns(upgradeId: string): boolean
		local upgrades = state.upgrades
		if type(upgrades) ~= "table" then
			return false
		end
		return (tonumber(upgrades[upgradeId]) or 0) >= 1
	end

	--: A chip is a button with a veil, not a coloured button.
	--
	--: UI.button tweens BackgroundColor3 back to whatever it captured at
	--: creation on every hover exit, so a button recoloured at runtime has a
	--: hover state that undoes it. The veil takes the colour and the button
	--: underneath keeps its tween to itself. The veil is inset one pixel so
	--: the button's own stroke still draws around it.
	local function chip(name: string, text: string, x: number, width: number,
	                    onClick: () -> ()): any
		local button = UI.button(cluster, "", {
			name = name,
			size = UDim2.fromOffset(width, 44),
			pos = UDim2.fromOffset(x, 20),
			color = Theme.color.panelAlt,
			strokeColor = Theme.color.stroke,
			onClick = onClick,
		})
		local veil = Instance.new("Frame")
		veil.Name = "Veil"
		veil.Size = UDim2.new(1, -2, 1, -2)
		veil.Position = UDim2.fromOffset(1, 1)
		veil.BackgroundColor3 = Theme.color.panelAlt
		veil.BackgroundTransparency = 0.1
		veil.BorderSizePixel = 0
		veil.ZIndex = 1
		veil.Parent = button
		UI.corner(veil, Theme.radius.sm)
		local label = UI.label(button, text, {
			name = "Chip",
			font = Theme.font.bold,
			size = Theme.text.sm,
			align = Enum.TextXAlignment.Center,
			frameSize = UDim2.fromScale(1, 1),
		})
		local sub = UI.label(button, "", {
			name = "Sub",
			font = Theme.font.bold,
			size = Theme.text.xs,
			color = Theme.color.textDim,
			align = Enum.TextXAlignment.Center,
			pos = UDim2.new(0, 0, 1, -14),
			frameSize = UDim2.new(1, 0, 0, 12),
		})
		return { button = button, veil = veil, label = label, sub = sub }
	end

	local five = chip("BatchFive", "x5", 152, 70, function()
		if owns("batch5") then
			scope.send("Roll", { count = 5 })
		end
	end)
	local twenty = chip("BatchTwenty", "x20", 230, 80, function()
		if owns("batch20") then
			scope.send("Roll", { count = 20 })
		end
	end)
	local auto = chip("Auto", "AUTO", 318, 90, function()
		if owns("autoroll") then
			scope.send("SetAuto", { on = state.autoRoll ~= true })
		end
	end)

	local function setChip(control: any, locked: boolean, active: boolean, primary: string)
		control.label.Text = primary
		control.label.TextColor3 = if active then Theme.color.bg
			elseif locked then Theme.color.textDim
			else Theme.color.text
		control.veil.BackgroundColor3 = if active then Theme.color.gold
			elseif locked then Theme.color.sunken
			else Theme.color.panelAlt
		control.veil.BackgroundTransparency = if locked then 0.45 else 0.1
		control.sub.Text = if locked then "LOCKED" elseif active then "ON" else ""
	end

	-- --------------------------------------------------------------- roll
	local roll = UI.button(cluster, "ROLL", {
		name = "Roll",
		size = UDim2.fromOffset(220, 64),
		pos = UDim2.fromOffset(89, 72),
		color = Theme.color.accent,
		textColor = Theme.color.bg,
		textSize = 26,
		skin = "button",
		onClick = function()
			scope.send("Roll", { count = 1 })
		end,
	})
	--: The cost rides under the word, inside the button. A stroke on it,
	--: because the skin is catalogue art this file has never seen and a
	--: light face would swallow light text.
	local rollSub = UI.label(roll, "", {
		name = "Cost",
		font = Theme.font.bold,
		size = Theme.text.sm,
		color = Theme.color.text,
		align = Enum.TextXAlignment.Center,
		pos = UDim2.new(0, 0, 1, -18),
		frameSize = UDim2.new(1, 0, 0, 14),
	})
	rollSub.TextStrokeColor3 = Theme.color.bg
	rollSub.TextStrokeTransparency = 0.25

	local gemButton = UI.button(cluster, "GEM 25", {
		name = "GemRoll",
		size = UDim2.fromOffset(150, 44),
		pos = UDim2.fromOffset(321, 82),
		color = Theme.color.panelAlt,
		textColor = Theme.color.gem,
		strokeColor = Theme.color.gem,
		onClick = function()
			scope.send("GemRoll", { count = 1 })
		end,
	})
	local gemIcon = icon(cluster, "economy.gem", 16, UDim2.fromOffset(333, 96), Theme.color.gem)

	-- =============================================================== reveal
	local overlay = Instance.new("TextButton")
	overlay.Name = "Reveal"
	overlay.Text = ""
	overlay.AutoButtonColor = false
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.Visible = false
	overlay.ZIndex = 100
	overlay.Parent = parent

	-- --------------------------------------------------------- single
	local singleHolder = Instance.new("Frame")
	singleHolder.Name = "Single"
	singleHolder.AnchorPoint = Vector2.new(0.5, 0.5)
	singleHolder.Position = UDim2.new(0.5, 0, 0.5, 0)
	singleHolder.Size = UDim2.fromOffset(260, 340)
	singleHolder.BackgroundTransparency = 1
	singleHolder.Visible = false
	singleHolder.ZIndex = 101
	singleHolder.Parent = parent

	local card = UI.panel(singleHolder, {
		name = "Card",
		size = UDim2.fromScale(1, 1),
		color = Theme.color.panel,
		stroke = false,
	})
	local cardStroke = UI.stroke(card, Theme.color.gold, 3, 0.15)

	local rarityLabel = UI.label(card, "COMMON", {
		name = "Rarity",
		font = Theme.font.bold,
		size = Theme.text.md,
		color = Theme.color.textDim,
		align = Enum.TextXAlignment.Center,
		pos = UDim2.fromOffset(0, 12),
		frameSize = UDim2.new(1, 0, 0, 20),
	})

	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.AnchorPoint = Vector2.new(0.5, 0)
	ring.Position = UDim2.new(0.5, 0, 0, 44)
	ring.Size = UDim2.fromOffset(118, 118)
	ring.BackgroundTransparency = 1
	ring.ZIndex = 2
	ring.Parent = card
	UI.corner(ring, Theme.radius.pill)
	local ringStroke = UI.stroke(ring, Theme.color.gold, 3, 0.15)

	local core = Instance.new("Frame")
	core.Name = "Core"
	core.AnchorPoint = Vector2.new(0.5, 0.5)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.Size = UDim2.fromOffset(70, 70)
	core.BackgroundColor3 = Theme.color.gold
	core.BorderSizePixel = 0
	core.ZIndex = 2
	core.Parent = ring
	UI.corner(core, Theme.radius.pill)
	UI.stroke(core, Color3.new(1, 1, 1), 2, 0.55)
	local coreGrad = Instance.new("UIGradient")
	coreGrad.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(96, 90, 104))
	coreGrad.Rotation = 90
	coreGrad.Parent = core

	local nameLabel = UI.label(card, "", {
		name = "CardName",
		font = Theme.font.title,
		size = 24,
		color = Theme.color.text,
		align = Enum.TextXAlignment.Center,
		wrap = true,
		pos = UDim2.fromOffset(20, 176),
		frameSize = UDim2.new(1, -40, 0, 56),
	})

	local tag = UI.panel(card, {
		name = "Tag",
		size = UDim2.fromOffset(120, 26),
		pos = UDim2.new(0.5, 0, 0, 240),
		anchor = Vector2.new(0.5, 0),
		color = Theme.color.gold,
		transparency = 0.1,
		radius = Theme.radius.pill,
		stroke = false,
	})
	local tagText = UI.label(tag, "", {
		name = "TagText",
		font = Theme.font.bold,
		size = Theme.text.sm,
		color = Theme.color.bg,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.fromScale(1, 1),
	})

	UI.label(card, "tap to continue", {
		name = "Footer",
		size = Theme.text.xs,
		color = Theme.color.textDim,
		align = Enum.TextXAlignment.Center,
		pos = UDim2.new(0, 0, 1, -22),
		frameSize = UDim2.new(1, 0, 0, 14),
	})

	-- --------------------------------------------------------- batch
	local batchHolder = Instance.new("Frame")
	batchHolder.Name = "Batch"
	batchHolder.AnchorPoint = Vector2.new(0.5, 0.5)
	batchHolder.Position = UDim2.new(0.5, 0, 0.5, 0)
	batchHolder.Size = UDim2.fromOffset(460, 440)
	batchHolder.BackgroundTransparency = 1
	batchHolder.Visible = false
	batchHolder.ZIndex = 101
	batchHolder.Parent = parent

	local batchTitle = UI.label(batchHolder, "x5 SUMMON", {
		name = "Title",
		font = Theme.font.title,
		size = Theme.text.lg,
		color = Theme.color.text,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, 0, 0, 26),
	})

	--: Twenty slots pre-built, five across. A batch of five lights the
	--: first row only; the stride is fixed so a card never moves once the
	--: grid starts filling.
	local minis: { any } = {}
	for index = 1, 20 do
		local column = (index - 1) % 5
		local row = math.floor((index - 1) / 5)
		local mini = UI.panel(batchHolder, {
			name = "Mini" .. index,
			size = UDim2.fromOffset(80, 92),
			pos = UDim2.fromOffset(14 + column * 88, 34 + row * 100),
			color = Theme.color.panelAlt,
			transparency = 0.1,
			stroke = false,
			visible = false,
		})
		table.insert(minis, {
			panel = mini,
			stroke = UI.stroke(mini, Theme.color.stroke, 2, 0.15),
			name = UI.label(mini, "", {
				name = "Name",
				font = Theme.font.bold,
				size = Theme.text.xs,
				color = Theme.color.text,
				align = Enum.TextXAlignment.Center,
				wrap = true,
				pos = UDim2.fromOffset(4, 8),
				frameSize = UDim2.new(1, -8, 0, 42),
			}),
			rarity = UI.label(mini, "", {
				name = "Rarity",
				font = Theme.font.bold,
				size = Theme.text.xs,
				color = Theme.color.textDim,
				align = Enum.TextXAlignment.Center,
				pos = UDim2.new(0, 3, 1, -40),
				frameSize = UDim2.new(1, -6, 0, 12),
			}),
			bar = (function()
				local bar = Instance.new("Frame")
				bar.Name = "Bar"
				bar.AnchorPoint = Vector2.new(0.5, 0)
				bar.Position = UDim2.new(0.5, 0, 1, -24)
				bar.Size = UDim2.new(1, -14, 0, 4)
				bar.BackgroundColor3 = Theme.color.gold
				bar.BorderSizePixel = 0
				bar.ZIndex = 2
				bar.Parent = mini
				UI.corner(bar, 2)
				return bar
			end)(),
			isNew = (function()
				local dot = Instance.new("Frame")
				dot.Name = "New"
				dot.AnchorPoint = Vector2.new(1, 0)
				dot.Position = UDim2.new(1, 3, 0, -3)
				dot.Size = UDim2.fromOffset(12, 12)
				dot.BackgroundColor3 = Theme.color.gold
				dot.BorderSizePixel = 0
				dot.Visible = false
				dot.ZIndex = 3
				dot.Parent = mini
				UI.corner(dot, Theme.radius.pill)
				return dot
			end)(),
		})
	end

	-- ------------------------------------------------------ reveal control
	local serial = 0

	local function bump(): number
		serial += 1
		return serial
	end

	local function hideReveal()
		bump()
		singleHolder.Visible = false
		batchHolder.Visible = false
		local out = TweenService:Create(overlay, TweenInfo.new(0.15), { BackgroundTransparency = 1 })
		out:Play()
		task.delay(0.16, function()
			if overlay.BackgroundTransparency >= 0.99 then
				overlay.Visible = false
			end
		end)
	end

	local function showSingle(result: any)
		local tint = Theme.rarityColor(result.rarity)
		rarityLabel.Text = Theme.rarityName(result.rarity)
		rarityLabel.TextColor3 = tint
		cardStroke.Color = tint
		ringStroke.Color = tint
		core.BackgroundColor3 = tint
		nameLabel.Text = textOf(result.name, "Unknown Aura")
		if result.isNew == true then
			tag.BackgroundColor3 = Theme.color.gold
			tagText.Text = "NEW!"
			tagText.TextColor3 = Theme.color.bg
		else
			tag.BackgroundColor3 = Theme.color.panelAlt
			tagText.Text = string.format("x%d OWNED", (tonumber(result.dupes) or 0) + 1)
			tagText.TextColor3 = Theme.color.textDim
		end
		--: The entrance: a short scale landing, the same move the tidebound
		--: catch card makes. 245 to 260 is small enough that the fixed
		--: children never visibly overflow the still-growing frame.
		singleHolder.Size = UDim2.fromOffset(245, 325)
		singleHolder.Visible = true
		TweenService:Create(singleHolder, TweenInfo.new(
			0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = UDim2.fromOffset(260, 340) }):Play()
		local mine = bump()
		task.delay(2.2, function()
			if serial == mine then
				hideReveal()
			end
		end)
	end

	local function showBatch(results: any, batch: number)
		batchTitle.Text = string.format("x%d SUMMON", batch)
		local count = math.min(#results, 20)
		for index, mini in ipairs(minis) do
			mini.panel.Visible = false
			local result = results[index]
			if index <= count and result ~= nil then
				local tint = Theme.rarityColor(result.rarity)
				mini.name.Text = textOf(result.name, "Unknown")
				mini.rarity.Text = Theme.rarityName(result.rarity)
				mini.rarity.TextColor3 = tint
				mini.stroke.Color = tint
				mini.bar.BackgroundColor3 = tint
				mini.isNew.Visible = result.isNew == true
			end
		end
		batchHolder.Visible = true
		local mine = bump()
		for index = 1, count do
			local mini = minis[index]
			task.delay((index - 1) * 0.06, function()
				if serial ~= mine or not overlay.Visible then
					return
				end
				mini.panel.Visible = true
				mini.panel.Size = UDim2.fromOffset(72, 84)
				TweenService:Create(mini.panel, TweenInfo.new(
					0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
					{ Size = UDim2.fromOffset(80, 92) }):Play()
			end)
		end
		task.delay(count * 0.06 + 2.4, function()
			if serial == mine then
				hideReveal()
			end
		end)
	end

	-- ============================================================== banner
	local banner = UI.panel(parent, {
		name = "Announce",
		size = UDim2.fromOffset(420, 48),
		pos = UDim2.new(0.5, 0, 0, -60),
		anchor = Vector2.new(0.5, 0),
		color = Theme.color.panelAlt,
		stroke = false,
		visible = false,
	})
	banner.ZIndex = 110
	local bannerStroke = UI.stroke(banner, Theme.color.gold, 2, 0.25)
	local bannerLabel = UI.label(banner, "", {
		name = "Text",
		font = Theme.font.bold,
		size = Theme.text.sm,
		color = Theme.color.text,
		align = Enum.TextXAlignment.Center,
		pos = UDim2.fromOffset(12, 0),
		frameSize = UDim2.new(1, -24, 1, 0),
	})

	local announceSerial = 0

	local function announce(payload: any)
		if type(payload) ~= "table" then
			return
		end
		local who = textOf(payload.name, "Someone")
		local text: string
		local tint: Color3
		if payload.ascend == true then
			text = string.format("%s ascended to Life %d! (+%d Essence)", who,
				tonumber(payload.life) or 1, tonumber(payload.essenceGain) or 0)
			tint = Theme.color.violet
		else
			text = string.format("%s summoned %s!", who, textOf(payload.cardName, "an aura"))
			tint = Theme.rarityColor(tonumber(payload.rarity))
		end
		bannerLabel.Text = text
		bannerLabel.TextColor3 = tint
		bannerStroke.Color = tint
		announceSerial += 1
		local mine = announceSerial
		banner.Visible = true
		banner.Position = UDim2.new(0.5, 0, 0, -60)
		TweenService:Create(banner, TweenInfo.new(
			0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.new(0.5, 0, 0, 10) }):Play()
		task.delay(3.5, function()
			if announceSerial ~= mine then
				return
			end
			TweenService:Create(banner, TweenInfo.new(
				0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Position = UDim2.new(0.5, 0, 0, -60) }):Play()
			task.delay(0.24, function()
				if announceSerial == mine then
					banner.Visible = false
				end
			end)
		end)
	end

	-- ============================================================== rolled
	local function rolled(payload: any)
		if type(payload) ~= "table" or type(payload.results) ~= "table" or #payload.results == 0 then
			return
		end
		hideReveal()
		overlay.Visible = true
		if overlay.BackgroundTransparency >= 0.99 then
			overlay.BackgroundTransparency = 1
		end
		TweenService:Create(overlay, TweenInfo.new(0.15), { BackgroundTransparency = 0.35 }):Play()

		local batch = tonumber(payload.batch) or 1
		if batch > 1 then
			showBatch(payload.results, batch)
		else
			showSingle(payload.results[1])
		end
	end

	-- ============================================================== update
	local function update(next: any)
		if type(next) ~= "table" then
			return
		end
		for key, value in next do
			state[key] = value
		end

		local pity = tonumber(state.pity) or 0
		local pityMax = tonumber(state.pityMax) or 40
		pityText.Text = string.format("PITY %d/%d", pity, pityMax)
		pityText.TextColor3 = if pityMax - pity <= 5 then Theme.color.gold else Theme.color.textDim
		pityBar:set(if pityMax > 0 then pity / pityMax else 0)

		local batches = state.batches
		setChip(five, not owns("batch5"),
			type(batches) == "table" and batches.five == true, "x5")
		setChip(twenty, not owns("batch20"),
			type(batches) == "table" and batches.twenty == true, "x20")
		local autoOn = state.autoRoll == true
		setChip(auto, not owns("autoroll"), autoOn, "AUTO")

		rollSub.Text = if state.free == true then "FREE"
			else textOf(state.nextCostText, "?") .. " RIFT"
		rollSub.TextColor3 = if state.free == true then Theme.color.gold else Theme.color.text

		local gems = tonumber(state.gems) or 0
		local gemCost = tonumber(state.gemCost) or 25
		gemButton.Text = string.format("GEM %d", gemCost)
		local affordable = gems >= gemCost
		gemButton.BackgroundTransparency = if affordable then 0 else 0.45
		gemButton.TextColor3 = if affordable then Theme.color.gem else Theme.color.textDim
		if gemIcon then
			gemIcon.ImageTransparency = if affordable then 0 else 0.45
		end
	end

	overlay.MouseButton1Click:Connect(function()
		if overlay.Visible then
			hideReveal()
		end
	end)

	return {
		update = update,
		rolled = rolled,
		announce = announce,
	}
end

return Roller
