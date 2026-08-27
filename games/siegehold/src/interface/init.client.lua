--!strict
--[[
	Interface — the whole UI, built from Forge's generalist widgets.

	Nothing here draws a Frame by hand. Every surface is `UI.panel`, every
	readout `UI.label`, every meter `UI.bar`, every icon a token through
	`VisualIcons`. That is a constraint on purpose: if the engine's widgets
	cannot express a real game's interface, the honest way to find out is to
	build one out of them and look at it -- not to add a thirteenth widget to
	the engine because this one screen wanted one.

	What a HUD has to do, in the order a player needs it
	---------------------------------------------------

	**Say what changed.** Every readout is driven by an attribute the server
	owns. The client keeps no copy: a client that does disagrees with the
	ledger the moment anything is spent, and it always disagrees in the
	player's favour on screen.

	**Say what is happening now, and nothing else.** Wave, integrity and cash
	are always up. Everything else is behind a rail button, because a HUD that
	shows everything shows nothing.

	**Survive the device it lands on.** Roblox owns the top-left corner and, on
	a phone, both bottom corners -- the menu button, the joystick, the jump
	button. So the bar is top-centre and the rail is centre-right, the two
	regions nothing else claims. Sizes come from `UI.theme.space`, and one
	`UIScale` driven by viewport width keeps a 1440p desktop and a 375pt phone
	both legible.

	Why the panels share one frame
	------------------------------

	One panel is open at a time and they occupy the same rectangle. Two open
	panels on a phone is two panels a thumb cannot reach past, and the dim
	behind an open one is how a player knows the world is still there and
	still running.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Wire = require(ReplicatedStorage.Shared.Wire)
local Tiers = require(ReplicatedStorage.Shared.Tiers)
local Catalogue = require(ReplicatedStorage.Shared.Catalogue)

local UI = Forge.UI
local Icons = Forge.UI.VisualIcons
local T = UI.theme

Wire.install()

local player = Players.LocalPlayer
local Interface = {}

-- ============================== groundwork ==================================
--[[
	`ignoreInset = false`, and no manual inset anywhere.

	`UI.mount` defaults to ignoring the inset, so the first version read
	`GuiService:GetGuiInset()` once at startup and added it by hand. That call
	returns **zero** until Roblox's own topbar has loaded, which on this client
	it had not -- so the bar was pinned eight pixels from the true top of the
	screen, directly under the Roblox menu and chat buttons. The desktop
	screenshot looked fine because Studio draws that chrome elsewhere.

	Letting Roblox own the inset is both simpler and correct on every device,
	including the ones whose inset changes after launch.
]]
local screen = UI.mount("Siegehold", { displayOrder = 10, ignoreInset = false })

--[[
	One scale for the whole interface, from the viewport width.

	Roblox does not scale GUI for you, so a bar sized in offsets is a
	comfortable 460px on a desktop and most of a phone's width. Driving a
	single `UIScale` preserves every widget's proportions and its relationship
	to the touch targets, which per-widget breakpoints do not.
]]
local scaler = Instance.new("UIScale")
scaler.Parent = screen

local function rescale()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	--[[
		Floors at 0.8, and that number is a touch target, not a taste.

		The scale multiplies everything under it, buttons included. Measured on
		a 1093px viewport the rail buttons came back 44x44 from a declared 52 --
		exactly Roblox's minimum -- and a narrower screen would have taken them
		below it. With RAIL_BUTTON at 56 and this floor at 0.8, the worst case
		is 44.8, so the smallest phone still gets a target a thumb can hit.
	]]
	scaler.Scale = math.clamp(camera.ViewportSize.X / 1280, 0.8, 1.15)
end
rescale()
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
end

local touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local function number(value: any): number
	return tonumber(value) or 0
end

local function money(value: number): string
	if value >= 1e6 then
		return string.format("%.1fM", value / 1e6)
	elseif value >= 1e3 then
		return string.format("%.1fK", value / 1e3)
	end
	return string.format("%d", math.floor(value))
end

--: Every readout binds to an attribute rather than polling. The label is the
--: state and the server is the truth; nothing here holds a copy.
local function bind(attribute: string, apply: (any) -> ())
	apply(player:GetAttribute(attribute))
	player:GetAttributeChangedSignal(attribute):Connect(function()
		apply(player:GetAttribute(attribute))
	end)
end

-- ================================ top bar ===================================
--[[
	One shelf, three readouts, in the order they are needed.

	Wave first because it is what is about to change; integrity in the middle
	because it is the stake and the widest element earns the centre; cash last
	because it is consulted, not watched.
]]
local bar = UI.panel(screen, {
	name = "TopBar",
	size = UDim2.fromOffset(452, 56),
	anchor = Vector2.new(0.5, 0),
	pos = UDim2.new(0.5, 0, 0, T.space.sm),
	radius = T.radius.lg,
	--: Wider than the flat panel needed: a drawn frame's border eats into the
	--: box, and at `md` the first readout was clipped by it -- "WAVE" rendered
	--: as "AVE".
	padding = T.space.lg,
	transparency = 0.06,
	--: The pack's own panel frame, nine-sliced to this width. Falls through to
	--: the flat fill above wherever the catalogue has no frame, so this is safe
	--: to ask for before anything has been published.
	skin = "panel",
})

local barRow = UI.list(bar, { horizontal = true, gap = T.space.lg,
	vAlign = Enum.VerticalAlignment.Center })
barRow.SortOrder = Enum.SortOrder.LayoutOrder

--: A readout is a quiet caption over a loud value. The caption is what stops
--: a bare number from being a riddle.
local function readout(parent: Instance, caption: string, width: number,
                       order: number): TextLabel
	local holder = UI.panel(parent, {
		name = caption,
		size = UDim2.fromOffset(width, 36),
		stroke = false,
		transparency = 1,
	})
	holder.LayoutOrder = order

	UI.label(holder, caption, {
		size = T.text.xs,
		color = T.color.textDim,
		font = T.font.bold,
		frameSize = UDim2.new(1, 0, 0, 12),
	})
	return UI.label(holder, "-", {
		name = "Value",
		size = T.text.lg,
		font = T.font.bold,
		frameSize = UDim2.new(1, 0, 0, 24),
		pos = UDim2.fromOffset(0, 12),
	})
end

local waveValue = readout(bar, "WAVE", 52, 1)
bind("wave", function(value)
	waveValue.Text = string.format("%d", math.max(number(value), 1))
end)

--: Integrity is a bar *and* a number. The bar is read at a glance, the number
--: when it matters, and neither substitutes for the other.
local integrityHolder = UI.panel(bar, {
	name = "Integrity", size = UDim2.fromOffset(196, 36),
	stroke = false, transparency = 1,
})
integrityHolder.LayoutOrder = 2
UI.label(integrityHolder, "INTEGRITY", {
	size = T.text.xs, color = T.color.textDim, font = T.font.bold,
	frameSize = UDim2.new(1, 0, 0, 12),
})
local integrityBar = UI.bar(integrityHolder, {
	size = UDim2.new(1, 0, 0, 16),
	pos = UDim2.fromOffset(0, 16),
	color = T.color.good,
})
local integrityText = UI.label(integrityHolder, "", {
	size = T.text.xs, font = T.font.bold, align = Enum.TextXAlignment.Right,
	frameSize = UDim2.new(1, -6, 0, 16), pos = UDim2.fromOffset(0, 16), z = 5,
})

bind("integrity", function(value)
	local alpha = math.clamp(number(value) / 100, 0, 1)
	integrityBar:set(alpha)
	integrityText.Text = string.format("%d%%", math.floor(alpha * 100))
	--: Colour carries the same information as the length, for everyone who
	--: cannot compare two lengths at a glance.
	integrityBar.fill.BackgroundColor3 = if alpha > 0.5 then T.color.good
		elseif alpha > 0.25 then T.color.warning
		else T.color.danger
end)

local cashHolder = UI.panel(bar, {
	name = "Cash", size = UDim2.fromOffset(116, 36),
	stroke = false, transparency = 1,
})
cashHolder.LayoutOrder = 3
UI.label(cashHolder, "CASH", {
	size = T.text.xs, color = T.color.textDim, font = T.font.bold,
	frameSize = UDim2.new(1, 0, 0, 12),
})
local coin = Instance.new("ImageLabel")
coin.Name = "Coin"
coin.BackgroundTransparency = 1
coin.Size = UDim2.fromOffset(18, 18)
coin.Position = UDim2.fromOffset(0, 15)
coin.ZIndex = 3
coin.Parent = cashHolder
--: `apply`, not `.Image = get(...)`. Most icon art is a sprite sheet, and a
--: caller that assigns only the id shows the whole sheet where it wanted one
--: glyph. The return says whether real art was found.
local hasCoin = Icons.apply(coin, "economy.coin")
coin.Visible = hasCoin

local cashValue = UI.label(cashHolder, "0", {
	size = T.text.lg, font = T.font.bold, color = T.color.gold,
	frameSize = UDim2.new(1, if hasCoin then -22 else 0, 0, 24),
	pos = UDim2.fromOffset(if hasCoin then 22 else 0, 12),
})
bind("cash", function(value)
	cashValue.Text = money(number(value))
end)

-- ================================ panels ====================================
--: Declared here because `showSheet` below closes over it and the panel itself
--: is built further down. A `local` written after the closure is a *different*
--: variable: the closure would read a global, find nil, and the guard would
--: silently never fire.
local result: Frame

--: The dim behind an open panel. Not decoration: it says the world is still
--: there and still running, and it catches the tap that closes.
local scrim = Instance.new("TextButton")
scrim.Name = "Scrim"
scrim.Size = UDim2.fromScale(1, 1)
scrim.BackgroundColor3 = Color3.new(0, 0, 0)
scrim.BackgroundTransparency = 0.45
scrim.BorderSizePixel = 0
scrim.Text = ""
scrim.AutoButtonColor = false
scrim.Visible = false
scrim.ZIndex = 20
scrim.Parent = screen

local sheet = UI.panel(screen, {
	name = "Sheet",
	size = UDim2.fromOffset(468, 300),
	anchor = Vector2.new(0.5, 0.5),
	pos = UDim2.fromScale(0.5, 0.5),
	radius = T.radius.lg,
	transparency = 0.02,
	visible = false,
	skin = "panel",
})
sheet.ZIndex = 21

local sheetTitle = UI.label(sheet, "", {
	name = "Title", size = T.text.lg, font = T.font.title,
	frameSize = UDim2.new(1, -96, 0, 30),
	pos = UDim2.fromOffset(T.space.lg, T.space.md), z = 22,
})

local body = UI.panel(sheet, {
	name = "Body",
	size = UDim2.new(1, -T.space.lg * 2, 1, -76),
	pos = UDim2.fromOffset(T.space.lg, 60),
	stroke = false, transparency = 1,
})
body.ZIndex = 22

local open: string? = nil

--: Set once the rail exists; `closeSheet` runs before it is built.
local setRailVisible: (boolean) -> () = function() end

local function closeSheet()
	open = nil
	sheet.Visible = false
	scrim.Visible = false
	setRailVisible(true)
end

local closeButton = UI.button(sheet, "", {
	name = "Close",
	size = UDim2.fromOffset(36, 36),
	anchor = Vector2.new(1, 0),
	pos = UDim2.new(1, -T.space.md, 0, T.space.md),
	radius = T.radius.sm,
	onClick = closeSheet,
})
closeButton.ZIndex = 23
do
	local glyph = Instance.new("ImageLabel")
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromOffset(18, 18)
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	glyph.ZIndex = 24
	glyph.Parent = closeButton
	--: The one place a missing icon must not leave an empty button. Falling
	--: back to a text cross keeps the close affordance whatever the catalogue
	--: happens to hold.
	if not Icons.apply(glyph, "action.close") then
		glyph:Destroy()
		closeButton.Text = "\u{00D7}"
		closeButton.TextSize = T.text.xl
	end
end

scrim.MouseButton1Click:Connect(closeSheet)

local function clearBody()
	for _, child in body:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

local builders: { [string]: (Instance) -> number } = {}

local function showSheet(key: string, title: string)
	--: And the reverse: no panel opens over a finished round. Both directions
	--: are needed or the same collision comes back from the other side.
	if result.Visible then
		return
	end
	open = key
	sheetTitle.Text = title
	clearBody()
	local build = builders[key]
	--: Each builder reports the height its content needs and the sheet takes
	--: it. A fixed sheet is either padded with dead space for the short panel
	--: or clipping the tall one, and both look like a mistake.
	local height = if build then build(body) else 180

	--[[
		Width from the viewport, not a constant.

		468 is comfortable on a desktop and wider than a phone. Measured at a
		455px viewport the sheet reached within 40px of both edges and the
		centre-right rail sat *underneath* it -- three buttons half-hidden
		behind a panel, both of them tappable. A desktop screenshot showed
		none of that.
	]]
	local camera = workspace.CurrentCamera
	local available = if camera then camera.ViewportSize.X else 1280
	local width = math.min(468, (available / math.max(scaler.Scale, 0.1)) - 48)
	sheet.Size = UDim2.fromOffset(math.max(width, 300),
		math.clamp(height + 76, 180, 440))

	--: And the rail goes away while a panel is up. It is redundant then -- the
	--: scrim and the close button both dismiss -- and hiding it removes the
	--: collision at every width instead of only the narrow ones.
	setRailVisible(false)
	sheet.Visible = true
	scrim.Visible = true
end

local function toggleSheet(key: string, title: string)
	if open == key then
		closeSheet()
		return
	end
	showSheet(key, title)
end

-- ================================ the rail ==================================
--[[
	Centre-right, because it is the only edge nothing else owns.

	Bottom-left is the joystick, bottom-right the jump button, top-left the
	Roblox menu. A rail in any of those is a rail a thumb fights with, and a
	desktop screenshot will never show you that.
]]
local RAIL_BUTTON = 56

local rail = UI.panel(screen, {
	name = "Rail",
	size = UDim2.fromOffset(RAIL_BUTTON, 4),
	anchor = Vector2.new(1, 0.5),
	pos = UDim2.new(1, -T.space.lg, 0.5, 0),
	stroke = false, transparency = 1,
})
rail.AutomaticSize = Enum.AutomaticSize.Y
UI.list(rail, { gap = T.space.sm, hAlign = Enum.HorizontalAlignment.Center })

local badges: { [string]: Frame } = {}

local function railButton(key: string, title: string, token: string,
                          fallback: string, order: number)
	--: Sized so it is still 44 after the smallest scale. See `rescale`.
	local button = UI.button(rail, "", {
		name = key,
		size = UDim2.fromOffset(RAIL_BUTTON, RAIL_BUTTON),
		radius = T.radius.md,
		skin = "button",
		onClick = function()
			toggleSheet(key, title)
		end,
	})
	button.LayoutOrder = order

	local glyph = Instance.new("ImageLabel")
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromOffset(26, 26)
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	glyph.ZIndex = 3
	glyph.Parent = button
	if not Icons.apply(glyph, token) then
		glyph:Destroy()
		button.Text = fallback
		button.TextSize = T.text.xs
	end

	--: A badge, hidden until something is waiting. A dot that is always there
	--: is a dot nobody looks at.
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Size = UDim2.fromOffset(12, 12)
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.new(1, -4, 0, 4)
	badge.BackgroundColor3 = T.color.danger
	badge.BorderSizePixel = 0
	badge.Visible = false
	badge.ZIndex = 4
	badge.Parent = button
	UI.corner(badge, T.radius.pill)
	badges[key] = badge

	return button
end

setRailVisible = function(visible: boolean)
	rail.Visible = visible
end

railButton("daily", "Daily Reward", "economy.gift", "DAY", 1)
railButton("shop", "Towers", "nav.shop", "TOWERS", 2)
railButton("progress", "Progression", "status.trophy", "TIER", 3)

bind("dailyReady", function(value)
	local badge = badges.daily
	if badge then
		badge.Visible = value == true
	end
end)

-- ============================== daily panel =================================
builders.daily = function(parent: Instance): number
	local ok, snapshot = pcall(function()
		return Forge.Net.request("dailyState")
	end)
	if not ok or type(snapshot) ~= "table" then
		local line = UI.label(parent, "The calendar could not be read.", {
			color = T.color.textDim, wrap = true,
			frameSize = UDim2.new(1, 0, 0, 40),
		})
		line.ZIndex = 23
		return 60
	end

	local streakLine = UI.label(parent, string.format(
		"Streak <b>%d</b>  ·  claim every day to keep it", snapshot.streak or 0), {
		size = T.text.sm, color = T.color.textDim,
		frameSize = UDim2.new(1, 0, 0, 20),
	})
	streakLine.ZIndex = 23

	--: A row of seven, so the shape of the week is visible and the jump on day
	--: seven is something a player can see coming. The same numbers in a list
	--: carry the information and none of the pull.
	local grid = UI.panel(parent, {
		size = UDim2.new(1, 0, 0, 92),
		pos = UDim2.fromOffset(0, 28),
		stroke = false, transparency = 1,
	})
	grid.ZIndex = 23
	UI.list(grid, { horizontal = true, gap = T.space.xs })

	local cycleLength = snapshot.cycleLength or 7
	for day = 1, cycleLength do
		local entry = (snapshot.cycle or {})[day] or {}
		local isNext = snapshot.available == true and day == snapshot.nextDay
		local claimed = snapshot.available ~= true and day == snapshot.nextDay

		local cell = UI.panel(grid, {
			name = "Day" .. day,
			size = UDim2.fromOffset(56, 88),
			radius = T.radius.sm,
			color = if isNext then T.color.panelAlt else T.color.panel,
			strokeColor = if isNext then T.color.gold else T.color.stroke,
			transparency = 0.05,
			skin = "slot",
			skinState = if isNext then "hover" else "normal",
		})
		cell.LayoutOrder = day
		cell.ZIndex = 23

		UI.label(cell, "DAY " .. day, {
			size = T.text.xs, align = Enum.TextXAlignment.Center,
			color = if isNext then T.color.gold else T.color.textDim,
			font = T.font.bold, frameSize = UDim2.new(1, 0, 0, 14),
			pos = UDim2.fromOffset(0, 10), z = 24,
		})
		UI.label(cell, money(entry.cash or 0), {
			size = T.text.md, align = Enum.TextXAlignment.Center,
			color = if isNext then T.color.text else T.color.textDim,
			font = T.font.bold, frameSize = UDim2.new(1, 0, 0, 22),
			pos = UDim2.fromOffset(0, 34), z = 24,
		})
		if claimed then
			UI.label(cell, "claimed", {
				size = T.text.xs, align = Enum.TextXAlignment.Center,
				color = T.color.good, frameSize = UDim2.new(1, 0, 0, 14),
				pos = UDim2.fromOffset(0, 62), z = 24,
			})
		end
	end

	local available = snapshot.available == true
	local claim: TextButton
	claim = UI.button(parent, if available
			then "Claim day " .. tostring(snapshot.nextDay)
			else "Come back tomorrow", {
		size = UDim2.new(1, 0, 0, 44),
		pos = UDim2.fromOffset(0, 134),
		color = if available then T.color.accent else T.color.panelAlt,
		textColor = if available then T.color.bg else T.color.textDim,
		textSize = T.text.md,
		skin = "button",
		onClick = function()
			if not available or not claim.Active then
				return
			end
			--: Dead the instant it is pressed. A claim button that stays live
			--: through the round trip is one that gets pressed four times, and
			--: only the server refusing the other three keeps that from being
			--: an exploit.
			claim.Active = false
			claim.Text = "Claiming\u{2026}"
			local sent, result = pcall(function()
				return Forge.Net.request("dailyClaim")
			end)
			if sent and type(result) == "table" and result.ok then
				--: Redrawn from the server's new answer rather than patched
				--: locally, so what the panel shows is what the server holds.
				showSheet("daily", "Daily Reward")
			else
				claim.Text = if type(result) == "table" and result.reason
					then tostring(result.reason)
					else "Could not claim"
				claim.Active = true
			end
		end,
	})
	claim.ZIndex = 23
	claim.Active = available

	--: Temporary: the label is present and invisible and three hypotheses
	--: about why were wrong. Reading the values the widget actually ended up
	--: with beats a fourth guess.
	local skin = claim:FindFirstChild("Skin")
	--: `print`, not `Debug.info`. `Debug.info` appends to an internal ring
	--: buffer and only `Debug.error` reaches Studio's output, so the probe was
	--: writing somewhere `log.tail` cannot see -- which is why three attempts
	--: to read it came back empty.
	task.defer(function()
		print(string.format(
			"claim: text=%q colour=%s size=%d z=%d bounds=%s vis=%s "
			.. "textT=%.2f skinZ=%s skinT=%.2f scale=%s",
			claim.Text, tostring(claim.TextColor3), claim.TextSize, claim.ZIndex,
			tostring(claim.TextBounds), tostring(claim.Visible),
			claim.TextTransparency,
			if skin then tostring(skin.ZIndex) else "-",
			if skin and skin:IsA("ImageLabel") then skin.ImageTransparency else -1,
			if skin and skin:IsA("ImageLabel") then tostring(skin.ScaleType) else "-"))
	end)

	return 190
end

-- =============================== shop panel =================================
builders.shop = function(parent: Instance): number
	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, 0, 1, -32)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = T.color.stroke
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ZIndex = 23
	scroll.Parent = parent
	UI.list(scroll, { gap = T.space.sm })

	local cash = number(player:GetAttribute("cash"))
	local shown = 0
	for _, entry in Catalogue do
		if entry.role ~= "melee" and entry.role ~= "ranged" then
			continue
		end
		shown += 1
		if shown > 10 then
			break
		end
		local cost = math.max(math.floor((entry.power or 10) * 5), 1)
		local affordable = cash >= cost

		local row = UI.panel(scroll, {
			size = UDim2.new(1, -8, 0, 52),
			radius = T.radius.sm,
			transparency = 0.06,
		})
		row.LayoutOrder = shown
		row.ZIndex = 23

		UI.label(row, entry.name, {
			size = T.text.sm, font = T.font.bold,
			frameSize = UDim2.new(1, -116, 0, 18),
			pos = UDim2.fromOffset(T.space.md, 8), z = 24,
		})
		UI.label(row, string.format("%s  ·  tier %d", entry.role, entry.tier or 1), {
			size = T.text.xs, color = T.color.textDim,
			frameSize = UDim2.new(1, -116, 0, 16),
			pos = UDim2.fromOffset(T.space.md, 26), z = 24,
		})
		--: Priced against the balance the player can see, and dimmed when they
		--: cannot afford it. A price with no balance beside it answers nothing.
		UI.label(row, money(cost), {
			size = T.text.md, font = T.font.bold,
			align = Enum.TextXAlignment.Right,
			color = if affordable then T.color.gold else T.color.textDim,
			frameSize = UDim2.new(0, 96, 1, 0),
			anchor = Vector2.new(1, 0),
			pos = UDim2.new(1, -T.space.md, 0, 0), z = 24,
		})
	end

	--: Said plainly rather than implied by an inert row. Towers are raised in
	--: the world, not bought from a menu, and a shop that looks buyable and is
	--: not is worse than one that explains itself.
	local note = UI.label(parent, "Towers are raised at the plinths in the world. "
		.. "This is what the wave budget can reach.", {
		size = T.text.xs, color = T.color.textDim, wrap = true,
		frameSize = UDim2.new(1, 0, 0, 28),
		anchor = Vector2.new(0, 1),
		pos = UDim2.new(0, 0, 1, 0),
	})
	note.ZIndex = 24

	return 340
end

-- ============================ progression panel =============================
builders.progress = function(parent: Instance): number
	local tierId = player:GetAttribute("tierId")
	local nextTier = player:GetAttribute("nextTier")
	local nextCost = number(player:GetAttribute("nextCost"))
	local cash = number(player:GetAttribute("cash"))

	local current = "Unranked"
	for _, tier in Tiers do
		if tier.id == tierId then
			current = tier.displayName
		end
	end

	local heading = UI.label(parent, current, {
		size = T.text.xl, font = T.font.title,
		frameSize = UDim2.new(1, 0, 0, 34),
	})
	heading.ZIndex = 23

	local sub = UI.label(parent, if nextTier
			then "Next: " .. tostring(nextTier)
			else "Highest tier reached", {
		size = T.text.sm, color = T.color.textDim,
		frameSize = UDim2.new(1, 0, 0, 20),
		pos = UDim2.fromOffset(0, 36),
	})
	sub.ZIndex = 23

	if nextCost > 0 then
		local meter = UI.bar(parent, {
			size = UDim2.new(1, 0, 0, 16),
			pos = UDim2.fromOffset(0, 64),
			color = T.color.gold,
		})
		meter:set(math.clamp(cash / nextCost, 0, 1))
		meter.holder.ZIndex = 23

		local amounts = UI.label(parent,
			string.format("%s / %s", money(cash), money(nextCost)), {
			size = T.text.sm, align = Enum.TextXAlignment.Right,
			frameSize = UDim2.new(1, 0, 0, 18),
			pos = UDim2.fromOffset(0, 86),
		})
		amounts.ZIndex = 23
	end

	--: The truth about how this game advances, stated. The server buys tiers
	--: the moment the balance covers them, so a button here would be a lie
	--: about who decides.
	local note = UI.label(parent, "Tiers are claimed automatically as soon as you "
		.. "can afford them. Income scales with the tier you hold.", {
		size = T.text.xs, color = T.color.textDim, wrap = true,
		frameSize = UDim2.new(1, 0, 0, 40),
		pos = UDim2.fromOffset(0, 114),
	})
	note.ZIndex = 23

	return 160
end

-- ============================== round result ================================
--: The one thing allowed to take the screen. A round ending is the only moment
--: the player is not doing something, and the only one worth interrupting.
result = UI.panel(screen, {
	name = "Result",
	size = UDim2.fromOffset(320, 120),
	anchor = Vector2.new(0.5, 0.5),
	pos = UDim2.fromScale(0.5, 0.42),
	radius = T.radius.lg,
	visible = false,
})
result.ZIndex = 30
local resultTitle = UI.label(result, "", {
	size = T.text.xl, font = T.font.title, align = Enum.TextXAlignment.Center,
	frameSize = UDim2.new(1, 0, 0, 40), pos = UDim2.fromOffset(0, 24), z = 31,
})
local resultLine = UI.label(result, "", {
	size = T.text.sm, color = T.color.textDim,
	align = Enum.TextXAlignment.Center,
	frameSize = UDim2.new(1, 0, 0, 20), pos = UDim2.fromOffset(0, 66), z = 31,
})

bind("sessionState", function(value)
	if value == nil then
		result.Visible = false
		return
	end
	local state = tostring(value)
	if state == "ACTIVE" then
		result.Visible = false
		return
	end
	local won = state == "WON"
	resultTitle.Text = if won then "Held" else "Overrun"
	resultTitle.TextColor3 = if won then T.color.good else T.color.danger
	resultLine.Text = string.format("Wave %d", number(player:GetAttribute("wave")))
	--[[
		The result takes the screen alone.

		It sat at ZIndex 30 over a sheet at 21 and simply won, so opening the
		daily panel after a lost round drew "Overrun" across the middle of it:
		the title unreadable, five of the seven day cells behind it, and both
		surfaces looking broken. Two things claiming the centre is not a
		layering problem to be solved with a bigger number -- one of them has
		to yield, and the round ending outranks a menu.
	]]
	closeSheet()
	result.Visible = true
end)

-- ================================ feedback ==================================
--: Server-sent, because "cash changed" and "you were paid for a seven-day
--: streak" want different presentation, and an attribute change cannot tell
--: them apart.
Forge.Net.on("notice", function(payload: any)
	if type(payload) ~= "table" or type(payload.text) ~= "string" then
		return
	end
	UI.toast(payload.text, {
		color = if payload.kind == "daily" then T.color.gold else T.color.text,
	})
end)

function Interface.describe(): { [string]: any }
	return {
		scale = scaler.Scale,
		touch = touch,
		openPanel = open,
		icons = Icons.describe(),
	}
end

Forge.Debug.probe("interface", Interface.describe)

--[[
	A way in from outside, for the look-and-critique pass.

	Driving this UI by synthetic mouse clicks does not work -- Studio refuses
	`SendMouseButtonEvent` without the RobloxScript capability -- and driving it
	by real OS clicks at screen coordinates works until anything moves, which
	cost three failed attempts to open one panel today.

	A BindableFunction the client owns is the honest alternative: it opens the
	same panel through the same `showSheet` a button press would, so what gets
	photographed is what a player would see.
]]
do
	local opener = Instance.new("BindableFunction")
	opener.Name = "SiegeholdUI"
	--: One argument, because that is what the bridge's `invoke_bindable`
	--: passes. `open:daily`, `close`, `describe`.
	opener.OnInvoke = function(command: any): any
		local text = tostring(command or "")
		local verb, rest = text:match("^(%a+):?(.*)$")
		if verb == "open" and rest ~= "" then
			--: The same titles the rail uses. Passing the key made the panel
			--: read "daily" in a screenshot, which is a defect in the probe
			--: rather than in the UI and would have been reported as the UI's.
			local titles = { daily = "Daily Reward", shop = "Towers",
				progress = "Progression" }
			showSheet(rest, titles[rest] or rest)
			return open
		elseif verb == "close" then
			closeSheet()
			return true
		elseif verb == "describe" then
			return Interface.describe()
		end
		return nil
	end
	opener.Parent = ReplicatedStorage
end

return Interface
