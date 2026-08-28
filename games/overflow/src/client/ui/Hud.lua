--!strict
--[[
	Hud — everything the player reads.

	The queue strip is the game
	---------------------------

	Routing is only a skill if you can plan, and planning needs a future you can
	see. The strip along the top shows the next four crates in the order they
	will arrive, in their chute's colour. Everything else here is a readout;
	that strip is a control surface the player thinks with.

	Rules this file follows, each because the engine's own trap list records
	what happens otherwise
	----------------------

	  * **A child draws above its parent, always.** `ZIndexBehavior.Sibling`
	    orders siblings only, so nothing decorative is parented into a widget
	    whose own content has to stay on top.
	  * **A `UIListLayout` lays out every visible `GuiObject` under it** and has
	    no ignore flag, so the two panels that use one contain rows and nothing
	    else. Titles live outside the laid-out frame.
	  * **Hidden means `Visible = false`, never "moved off-screen".** The
	    playtest gate reports an off-screen element as an error, and it is
	    right to: an element parked at -400 is one resize away from being the
	    interface.
	  * **Every button clears 44 pixels on its short edge**, which is Roblox's
	    own minimum for a thumb.
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

--: Every kind's colour, read once from the same config the server sorts by, so
--: the strip and the chute can never disagree about what violet means.
local KIND_COLOR: { [string]: Color3 } = {}
local KIND_LABEL: { [string]: string } = {}
local KIND_ORDER: { string } = {}
for _, spec in Config.chutes do
	if type(spec) == "table" and spec.id then
		KIND_COLOR[spec.id] = Color3.fromRGB(spec.color[1], spec.color[2], spec.color[3])
		KIND_LABEL[spec.id] = spec.label
		table.insert(KIND_ORDER, spec.id)
	end
end

local GOOD = Color3.fromRGB(126, 214, 138)
local BAD = Color3.fromRGB(226, 88, 92)

function Hud.build(screen: ScreenGui)
	local self = {
		screen = screen,
		shift = {
			phase = "running", score = 0, best = 0, strikes = 0, allowedStrikes = 3,
			streak = 0, multiplier = 1, speed = 0, ramp = 0, queue = {}, breather = 0,
		},
		you = { coins = 0, upgrades = {} },
		openPanel = nil :: string?,
	}

	-- ------------------------------------------------------------------ score
	local scorePanel = UI.panel(screen, {
		name = "Score",
		size = UDim2.fromOffset(230, 92),
		pos = UDim2.new(0, T.space.lg, 0, T.space.lg),
		padding = T.space.md,
	})
	UI.label(scorePanel, "SCORE", {
		size = T.text.xs, color = T.color.textDim, font = T.font.bold,
		frameSize = UDim2.new(1, 0, 0, 14),
	})
	local scoreText = UI.label(scorePanel, "0", {
		size = T.text.xl, font = T.font.bold,
		frameSize = UDim2.new(1, 0, 0, 34), pos = UDim2.fromOffset(0, 14),
	})
	local multText = UI.label(scorePanel, "", {
		size = T.text.md, font = T.font.bold, color = T.color.gold,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.new(1, 0, 0, 34), pos = UDim2.fromOffset(0, 16),
	})
	local bestText = UI.label(scorePanel, "best 0", {
		size = T.text.xs, color = T.color.textDim,
		frameSize = UDim2.new(1, 0, 0, 14), pos = UDim2.fromOffset(0, 50),
	})

	-- ----------------------------------------------------------------- queue
	--[[
		The strip. Left is next.

		Sized generously: these are the four things the player is reading while
		running, and a chip they have to squint at is a chip they ignore.
	]]
	local queuePanel = UI.panel(screen, {
		name = "Queue",
		size = UDim2.fromOffset(330, 86),
		pos = UDim2.new(0.5, 0, 0, T.space.lg),
		anchor = Vector2.new(0.5, 0),
		padding = T.space.sm,
	})
	UI.label(queuePanel, "INCOMING", {
		size = T.text.xs, color = T.color.textDim, font = T.font.bold,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, 0, 0, 13),
	})

	local chips: { Frame } = {}
	local chipLabels: { TextLabel } = {}
	for i = 1, Config.line.previewCount do
		local chip = Instance.new("Frame")
		chip.Name = "Chip" .. i
		chip.Size = UDim2.fromOffset(70, 46)
		chip.Position = UDim2.fromOffset((i - 1) * 78, 17)
		chip.BackgroundColor3 = T.color.panelAlt
		chip.BorderSizePixel = 0
		chip.Parent = queuePanel
		UI.corner(chip, T.radius.sm)
		--: The nearest crate is the one being decided now, so it is the one
		--: that gets the stroke. A strip where every chip looks the same is a
		--: strip nobody reads left to right.
		local edge = UI.stroke(chip, T.color.stroke, if i == 1 then 2 else 1, if i == 1 then 0 else 0.5)
		edge.Name = "Edge"

		local text = UI.label(chip, "", {
			size = T.text.sm, font = T.font.bold,
			align = Enum.TextXAlignment.Center,
			frameSize = UDim2.fromScale(1, 1),
		})
		chips[i] = chip
		chipLabels[i] = text
	end

	-- ---------------------------------------------------------------- strikes
	--[[
		Under the score, not in the top-right corner.

		The top-right is Roblox's own: the player list lives there and cannot be
		moved, so a panel placed at that anchor is a panel half-covered by
		someone else's interface. The first screenshot of this HUD had "LINE
		HEALTH" reading through the leaderboard.
	]]
	local strikePanel = UI.panel(screen, {
		name = "Strikes",
		size = UDim2.fromOffset(230, 62),
		pos = UDim2.new(0, T.space.lg, 0, T.space.lg + 100),
		padding = T.space.sm,
	})
	UI.label(strikePanel, "LINE HEALTH", {
		size = T.text.xs, color = T.color.textDim, font = T.font.bold,
		frameSize = UDim2.new(1, 0, 0, 13),
	})
	local pips: { Frame } = {}
	for i = 1, 6 do
		local pip = Instance.new("Frame")
		pip.Name = "Pip" .. i
		pip.Size = UDim2.fromOffset(22, 12)
		pip.Position = UDim2.fromOffset((i - 1) * 27, 20)
		pip.BackgroundColor3 = GOOD
		pip.BorderSizePixel = 0
		pip.Visible = false
		pip.Parent = strikePanel
		UI.corner(pip, 3)
		pips[i] = pip
	end
	local speedText = UI.label(strikePanel, "", {
		size = T.text.xs, color = T.color.textDim,
		frameSize = UDim2.new(1, 0, 0, 13), pos = UDim2.fromOffset(0, 36),
	})

	-- ---------------------------------------------------------------- legend
	--[[
		Which chute takes what, in the chutes' left-to-right order.

		The world already says this — the levers are coloured and labelled — and
		it is repeated here because a player looking at the queue strip should
		not have to look away from it to remember what violet was.
	]]
	local legend = UI.panel(screen, {
		name = "Legend",
		size = UDim2.fromOffset(400, 44),
		pos = UDim2.new(0.5, 0, 1, -T.space.lg),
		anchor = Vector2.new(0.5, 1),
		padding = T.space.sm,
	})
	for i, kind in KIND_ORDER do
		local swatch = Instance.new("Frame")
		swatch.Name = "Swatch" .. kind
		swatch.Size = UDim2.fromOffset(14, 14)
		swatch.Position = UDim2.fromOffset((i - 1) * 96, 7)
		swatch.BackgroundColor3 = KIND_COLOR[kind]
		swatch.BorderSizePixel = 0
		swatch.Parent = legend
		UI.corner(swatch, 3)
		UI.label(legend, KIND_LABEL[kind], {
			size = T.text.xs, color = KIND_COLOR[kind], font = T.font.bold,
			frameSize = UDim2.fromOffset(72, 14),
			pos = UDim2.fromOffset((i - 1) * 96 + 20, 7),
		})
	end

	-- ---------------------------------------------------------------- wallet
	local wallet = UI.panel(screen, {
		name = "Wallet",
		size = UDim2.fromOffset(160, 46),
		pos = UDim2.new(0, T.space.lg, 1, -T.space.lg),
		anchor = Vector2.new(0, 1),
		padding = T.space.sm,
	})
	local coinText = UI.label(wallet, "0", {
		size = T.text.lg, font = T.font.bold, color = T.color.gold,
		frameSize = UDim2.new(1, 0, 1, 0),
	})

	-- ----------------------------------------------------------------- prompt
	local prompt = UI.label(screen, "", {
		name = "Prompt",
		size = T.text.md, font = T.font.bold,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, 0, 0, 24),
		pos = UDim2.new(0, 0, 1, -76),
	})
	prompt.TextStrokeTransparency = 0.35
	prompt.TextStrokeColor3 = Color3.new(0, 0, 0)

	-- ------------------------------------------------------------------- shop
	--[[
		The upgrade panel.

		Its rows live in their own frame with the layout on it, and the title
		sits outside that frame — because a `UIListLayout` lays out every
		visible child under it and a title placed inside would take the first
		row at full width.
	]]
	local shop = UI.panel(screen, {
		name = "ShopPanel",
		size = UDim2.fromOffset(320, 300),
		pos = UDim2.new(1, -T.space.lg, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		padding = T.space.md,
		visible = false,
	})
	UI.label(shop, "WORKSHOP", {
		size = T.text.xs, color = T.color.textDim, font = T.font.bold,
		frameSize = UDim2.new(1, 0, 0, 14),
	})
	local shopList = Instance.new("Frame")
	shopList.Name = "Rows"
	shopList.BackgroundTransparency = 1
	shopList.Size = UDim2.new(1, 0, 1, -22)
	shopList.Position = UDim2.fromOffset(0, 22)
	shopList.Parent = shop
	UI.list(shopList, { gap = T.space.sm })

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

		UI.label(row, spec.label, {
			size = T.text.sm, font = T.font.bold,
			frameSize = UDim2.new(1, -104, 0, 16),
		})
		local level = UI.label(row, "", {
			size = T.text.xs, color = T.color.textDim,
			align = Enum.TextXAlignment.Right,
			frameSize = UDim2.new(1, 0, 0, 16),
		})
		UI.label(row, spec.detail, {
			size = T.text.xs, color = T.color.textDim,
			frameSize = UDim2.new(1, -104, 0, 14), pos = UDim2.fromOffset(0, 17),
		})
		--: 96 x 44. The height is Roblox's own minimum for a touch target and
		--: the reason this row is 62 tall rather than 52.
		local buy = UI.button(row, "-", {
			size = UDim2.fromOffset(96, 44),
			pos = UDim2.new(1, 0, 1, 0),
			anchor = Vector2.new(1, 1),
			color = T.color.panel,
			onClick = function()
				if self.onBuy then
					self.onBuy(spec.id)
				end
			end,
		})
		rows[spec.id] = { level = level, buy = buy }
	end

	-- ----------------------------------------------------------------- ledger
	--: The end-of-shift board. Same shape as the shop and deliberately not the
	--: same panel: one is a decision and the other is a result.
	local ledger = UI.panel(screen, {
		name = "LedgerPanel",
		size = UDim2.fromOffset(300, 190),
		pos = UDim2.new(0.5, 0, 0.5, 0),
		anchor = Vector2.new(0.5, 0.5),
		padding = T.space.lg,
		visible = false,
	})
	UI.label(ledger, "SHIFT OVER", {
		size = T.text.lg, font = T.font.bold, color = T.color.gold,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, 0, 0, 26),
	})
	local ledgerScore = UI.label(ledger, "0", {
		size = T.text.xl, font = T.font.bold,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, 0, 0, 40), pos = UDim2.fromOffset(0, 32),
	})
	local ledgerLine = UI.label(ledger, "", {
		size = T.text.sm, color = T.color.textDim,
		align = Enum.TextXAlignment.Center, wrap = true,
		frameSize = UDim2.new(1, 0, 0, 44), pos = UDim2.fromOffset(0, 76),
	})
	local ledgerNext = UI.label(ledger, "", {
		size = T.text.sm, font = T.font.bold, color = GOOD,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, 0, 0, 22), pos = UDim2.fromOffset(0, 122),
	})

	-- ================================ updating ==============================
	local shownScore = 0

	function self.setShift(payload: any)
		for key, value in payload do
			self.shift[key] = value
		end
		self.shift.queue = payload.queue or {}
		ledger.Visible = self.shift.phase ~= "running"
	end

	function self.setYou(payload: any)
		for key, value in payload do
			self.you[key] = value
		end
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
				row.buy.Text = tostring(entry.cost)
				row.buy.TextColor3 = if (self.you.coins or 0) >= entry.cost
					then T.color.gold else T.color.textDim
			else
				row.buy.Text = "MAX"
				row.buy.TextColor3 = GOOD
			end
		end
	end

	--: One opener for every panel, so the client has a single entry point a
	--: test can invoke and a key can call.
	function self.setPanel(name: string?)
		self.openPanel = if self.openPanel == name then nil else name
		shop.Visible = self.openPanel == "shop"
		--: The ledger is owned by the shift, not by the player: it shows when
		--: the line is stopped and a request to open it only forces it early.
		if name == "ledger" then
			ledger.Visible = self.openPanel == "ledger" or self.shift.phase ~= "running"
		end
	end

	function self.step(dt: number)
		local s = self.shift

		shownScore = Ease.approach(shownScore, s.score or 0, 8, dt)
		scoreText.Text = string.format("%d", math.floor(shownScore + 0.5))
		bestText.Text = string.format("best %d", math.floor(s.best or 0))

		local mult = s.multiplier or 1
		multText.Text = if mult > 1 then string.format("x%d", mult) else ""

		--: Pips: one per allowed strike, filled from the left as they are used.
		local allowed = math.clamp(s.allowedStrikes or 3, 1, #pips)
		for i, pip in pips do
			pip.Visible = i <= allowed
			local spent = i <= (s.strikes or 0)
			pip.BackgroundColor3 = if spent then Color3.fromRGB(58, 54, 62) else GOOD
		end

		speedText.Text = string.format("belt %.0f studs/s", s.speed or 0)

		for i, chip in chips do
			local kind = (s.queue or {})[i]
			local label = chipLabels[i]
			if kind then
				chip.BackgroundColor3 = KIND_COLOR[kind] or T.color.panelAlt
				label.Text = KIND_LABEL[kind] or "?"
				--: Dark text on a saturated chip. The theme's own text colour
				--: is near-white and would vanish on amber.
				label.TextColor3 = Color3.fromRGB(22, 20, 26)
			else
				chip.BackgroundColor3 = T.color.panelAlt
				label.Text = "--"
				label.TextColor3 = T.color.textDim
			end
		end

		coinText.Text = string.format("%d", math.floor(self.you.coins or 0))

		if s.phase ~= "running" then
			ledgerScore.Text = string.format("%d", math.floor(s.score or 0))
			ledgerLine.Text = string.format("%d sorted  ·  best %d",
				math.floor(s.sorts or 0), math.floor(s.best or 0))
			ledgerNext.Text = string.format("next shift in %d", math.max(0, math.ceil(s.breather or 0)))
			prompt.Text = "Spend at the workshop — press B"
			prompt.TextColor3 = T.color.gold
		elseif (s.strikes or 0) >= allowed - 1 and allowed > 1 then
			prompt.Text = "One more and the shift ends."
			prompt.TextColor3 = BAD
		else
			prompt.Text = "Stand at a lever and press E as its crate arrives"
			prompt.TextColor3 = T.color.textDim
		end
	end

	--: A sort or a strike: a brief wash in the right colour.
	function self.flash(result: string, kind: string?)
		local colour = if result == "sorted" then (KIND_COLOR[kind or ""] or GOOD) else BAD
		local wash = Instance.new("Frame")
		wash.Name = "Flash"
		wash.Size = UDim2.fromScale(1, 1)
		wash.BackgroundColor3 = colour
		wash.BackgroundTransparency = if result == "sorted" then 0.9 else 0.78
		wash.BorderSizePixel = 0
		wash.ZIndex = 0
		wash.Parent = screen
		TweenService:Create(wash, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
		task.delay(0.4, function()
			wash:Destroy()
		end)
	end

	RunService.RenderStepped:Connect(function(dt)
		self.step(dt)
	end)

	return self
end

return Hud
