--!strict
--[[
	Interface — the HUD, the shop, and a tutorial that can actually be finished.

	Built from Forge's widgets and nothing else, skinned from the published CC0
	catalogue where it has art and falling back to flat panels where it does
	not.

	The tutorial is the reason this file is worth reading
	----------------------------------------------------

	The game this is modelled on has a "Complete the Tutorial" badge held by
	**0.0% of players** -- listed as *Impossible*, 2,533 earners against six
	million who got the welcome badge. Whatever it asks for, essentially nobody
	finishes it.

	So this one is built to be finishable, and the rules are:

	  * **Every step is something the player was going to do anyway.** Plant,
	    chop, carve, sell. No step exists to teach the interface; the interface
	    gets taught by running the loop once.
	  * **Steps complete from server state, not from clicks.** A step is done
	    when the yard says it is done, so a player who worked it out early, or
	    did it before the prompt appeared, is already past it.
	  * **It never blocks.** No modal, no forced camera, nothing disabled. It
	    is a line of text that changes.
	  * **It can be dismissed and stays dismissed.** A tutorial you cannot turn
	    off is a tutorial people quit over.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Wire = require(ReplicatedStorage.Shared.Wire)
local Trees = require(ReplicatedStorage.Shared.Trees)

local UI = Forge.UI
local Icons = Forge.UI.VisualIcons
local Feel = Forge.Feel
local Net = Forge.Net
local T = UI.theme

Wire.install()

local player = Players.LocalPlayer
local Interface = {}

-- ============================== groundwork ==================================
--: `ignoreInset = false` so Roblox owns the top inset. Reading `GetGuiInset()`
--: at startup returns zero before the topbar loads, and a HUD pinned with that
--: number sits under the Roblox menu on a real device.
--: Camera weight, for the axe. Mounted once here rather than per hit.
Feel.mount()

local screen = UI.mount("CarveWood", { displayOrder = 10, ignoreInset = false })

local scaler = Instance.new("UIScale")
scaler.Parent = screen

local function rescale()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	--: Floors at 0.8 because the scale multiplies buttons too: a 56px control
	--: at 0.8 is 44.8, just clear of Roblox's touch minimum.
	scaler.Scale = math.clamp(camera.ViewportSize.X / 1280, 0.8, 1.15)
end
rescale()
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
end

--[[
	A touch target, in the units a control is actually written in.

	`UIScale` multiplies everything under it, so a control authored at 44 is
	38 on a phone at the 0.86 the viewport asks for -- and the gate caught
	exactly that: a Skip button set to 44 because 44 is the minimum, measuring
	38 on screen. The scale floor is 0.8, so 44 on screen means 55 here.

	Writing it as arithmetic rather than as a magic 56 is the difference
	between a number that survives someone changing the floor and one that
	quietly stops being true.
]]
local MIN_TOUCH = 44
local SCALE_FLOOR = 0.8
local function touch(size: number): number
	return math.max(size, math.ceil(MIN_TOUCH / SCALE_FLOOR))
end

local function money(value: number): string
	if value >= 1e9 then return string.format("%.1fB", value / 1e9) end
	if value >= 1e6 then return string.format("%.1fM", value / 1e6) end
	if value >= 1e3 then return string.format("%.1fK", value / 1e3) end
	return string.format("%d", math.floor(value))
end

local function number(value: any): number
	return tonumber(value) or 0
end

local function bind(attribute: string, apply: (any) -> ())
	apply(player:GetAttribute(attribute))
	player:GetAttributeChangedSignal(attribute):Connect(function()
		apply(player:GetAttribute(attribute))
	end)
end

-- ================================ top bar ===================================
--: Three readouts in the order the loop uses them: what you have to carve,
--: what you have to sell, and what you have earned.
local bar = UI.panel(screen, {
	name = "TopBar",
	size = UDim2.fromOffset(400, 56),
	anchor = Vector2.new(0.5, 0),
	pos = UDim2.new(0.5, 0, 0, T.space.sm),
	radius = T.radius.lg,
	padding = T.space.lg,
	transparency = 0.06,
	skin = "panel",
})
local barRow = UI.list(bar, { horizontal = true, gap = T.space.lg,
	vAlign = Enum.VerticalAlignment.Center })
barRow.SortOrder = Enum.SortOrder.LayoutOrder

local function readout(caption: string, width: number, order: number,
                       colour: Color3, token: string): TextLabel
	local holder = UI.panel(bar, {
		name = caption, size = UDim2.fromOffset(width, 36),
		stroke = false, transparency = 1,
	})
	holder.LayoutOrder = order
	UI.label(holder, caption, {
		size = T.text.xs, color = T.color.textDim, font = T.font.bold,
		frameSize = UDim2.new(1, 0, 0, 12),
	})
	local inset = 0
	local glyph = Instance.new("ImageLabel")
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromOffset(18, 18)
	glyph.Position = UDim2.fromOffset(0, 15)
	glyph.ZIndex = 3
	glyph.Parent = holder
	if Icons.apply(glyph, token) then
		inset = 22
	else
		glyph:Destroy()
	end
	--[[
		A dash, not a zero, until the server has said anything.

		The server publishes these attributes only after the profile loads,
		which waits up to twelve seconds. For that whole window the HUD read
		`CASH 0` to a player who had 25 -- a confident wrong number, which is
		worse than an obviously absent one, and it is what the first
		screenshots of this game show.
	]]
	return UI.label(holder, "\u{2014}", {
		name = "Value", size = T.text.lg, font = T.font.bold, color = colour,
		frameSize = UDim2.new(1, -inset, 0, 24),
		pos = UDim2.fromOffset(inset, 12),
	})
end

local logsValue = readout("LOGS", 84, 1, T.color.text, "economy.chest")
local carvedValue = readout("CARVED", 96, 2, T.color.accent, "action.edit")
local cashValue = readout("CASH", 116, 3, T.color.gold, "economy.coin")

--: `v` is nil until the first publish. `number(v)` would turn that into 0,
--: so the dash has to survive the binding as well as the construction.
local function show(label: TextLabel)
	return function(v: any)
		label.Text = if v == nil then "\u{2014}" else money(number(v))
	end
end
bind("logs", show(logsValue))
bind("carved", show(carvedValue))
bind("cash", show(cashValue))

-- ================================= panels ===================================
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
	size = UDim2.fromOffset(468, 320),
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
local rail: any = nil

local function closeSheet()
	open = nil
	sheet.Visible = false
	scrim.Visible = false
	if rail then
		rail.Visible = true
	end
end

local closeButton = UI.button(sheet, "", {
	name = "Close",
	size = UDim2.fromOffset(touch(36), touch(36)),
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
	open = key
	sheetTitle.Text = title
	clearBody()
	local height = if builders[key] then builders[key](body) else 200
	local camera = workspace.CurrentCamera
	local available = if camera then camera.ViewportSize.X else 1280
	--: Width from the viewport. A fixed 468 leaves a phone with a panel
	--: touching both edges and sitting on top of the rail.
	local width = math.min(468, (available / math.max(scaler.Scale, 0.1)) - 48)
	sheet.Size = UDim2.fromOffset(math.max(width, 300),
		math.clamp(height + 76, 200, 460))
	--: The rail goes away while a panel is up. It is redundant then, and on a
	--: narrow screen the two overlap.
	if rail then
		rail.Visible = false
	end
	sheet.Visible = true
	scrim.Visible = true
end

local function toggleSheet(key: string, title: string)
	if open == key then
		closeSheet()
	else
		showSheet(key, title)
	end
end

local function refreshOpen()
	if open then
		showSheet(open, sheetTitle.Text)
	end
end

-- ================================= the rail =================================
--: Centre-right: the only edge Roblox does not claim. Bottom-left is the
--: joystick, bottom-right the jump button, top-left the menu.
local RAIL_BUTTON = touch(56)

rail = UI.panel(screen, {
	name = "Rail",
	size = UDim2.fromOffset(RAIL_BUTTON, 4),
	anchor = Vector2.new(1, 0.5),
	pos = UDim2.new(1, -T.space.lg, 0.5, 0),
	stroke = false, transparency = 1,
})
rail.AutomaticSize = Enum.AutomaticSize.Y
UI.list(rail, { gap = T.space.sm, hAlign = Enum.HorizontalAlignment.Center })

--[[
	A rail button is an icon *and* a word.

	It was an icon alone, and the first screenshot of this game shows three
	unreadable blue-grey squares stacked down the right edge -- the catalogue's
	art for "inventory", "shop" and "group" at 26 pixels, where the difference
	between them is a few pixels of silhouette. Nothing about that is fixable
	by choosing better art: 26 pixels is not enough to name a thing.

	The word also gives the control an accessible label. Three buttons whose
	`Text` was `""` is what the playtest gate meant by "3 text elements are
	empty", and it was right: a screen reader, and a player, both got nothing.
]]
local function railButton(key: string, title: string, token: string,
                          fallback: string, order: number)
	local button = UI.button(rail, fallback, {
		name = key,
		size = UDim2.fromOffset(RAIL_BUTTON, RAIL_BUTTON + 16),
		radius = T.radius.md,
		skin = "button",
		textSize = T.text.xs,
		onClick = function()
			toggleSheet(key, title)
		end,
	})
	button.LayoutOrder = order
	--: The caption sits at the foot of the button and the icon above it, so
	--: they share the face instead of overlapping in the middle.
	button.TextYAlignment = Enum.TextYAlignment.Bottom
	local pad = Instance.new("UIPadding")
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = button

	local glyph = Instance.new("ImageLabel")
	glyph.Name = "Glyph"
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromOffset(28, 28)
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.38)
	--: A child always draws above its parent regardless of ZIndex, so this
	--: only has to clear the skin, which is the button's *sibling*.
	glyph.ZIndex = 3
	glyph.Parent = button
	if not Icons.apply(glyph, token) then
		--: No art for this token. The word alone is still a usable button --
		--: which is the whole reason it is there.
		glyph:Destroy()
		button.TextYAlignment = Enum.TextYAlignment.Center
		pad:Destroy()
	end
	return button
end

railButton("seeds", "Seeds", "nav.inventory", "SEEDS", 1)
railButton("store", "Your shop", "economy.chest", "SHOP", 2)
railButton("shop", "Upgrades", "nav.shop", "BUILD", 3)
railButton("crew", "Crew", "social.group", "CREW", 4)

--[[
	Walking up to the shop hut opens the same panel the rail does.

	The titles live here rather than travelling with the message: the server
	says *which* panel, and what that panel is called is the client's business.
	A server that sends display strings is a server you have to redeploy to fix
	a typo.
]]
local PANEL_TITLES = { seeds = "Seeds", store = "Your shop",
	shop = "Upgrades", crew = "Crew" }
Net.on("openPanel", function(payload: any)
	local key = tostring((payload or {}).panel)
	local title = PANEL_TITLES[key]
	if title then
		showSheet(key, title)
	end
end)

-- =============================== the ladder =================================
--[[
	Rarity has a colour, and it is the same colour everywhere.

	A seed in the pack, a seed in your stock and a carving on a shelf are the
	same thing at three moments, and a player has to recognise it instantly in
	all three. One table, read by every panel.
]]
local RARITY = {
	Common = Color3.fromRGB(168, 170, 176),
	Uncommon = Color3.fromRGB(122, 196, 118),
	Rare = Color3.fromRGB(96, 158, 226),
	Epic = Color3.fromRGB(174, 122, 226),
	Legendary = Color3.fromRGB(238, 176, 74),
	Mythic = Color3.fromRGB(232, 104, 152),
	Celestial = Color3.fromRGB(140, 226, 244),
}

local QUALITY_COLOUR = {
	rough = Color3.fromRGB(150, 140, 126),
	fine = Color3.fromRGB(214, 202, 176),
	master = Color3.fromRGB(238, 186, 92),
	flawless = Color3.fromRGB(150, 226, 244),
}

--: One request per panel open. Three sections each asking the server for the
--: same snapshot is three round trips for one answer.
local function yardNow(): any?
	local ok, snap = pcall(function()
		return Net.request("yard")
	end)
	return if ok and type(snap) == "table" then snap else nil
end

local function loading(parent: Instance): number
	local line = UI.label(parent, "Your yard is still loading.", {
		color = T.color.textDim, frameSize = UDim2.new(1, 0, 0, 30) })
	line.ZIndex = 23
	return 60
end

local function scroller(parent: Instance, top: number): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, 0, 1, -top)
	scroll.Position = UDim2.fromOffset(0, top)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = T.color.stroke
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.ZIndex = 23
	scroll.Parent = parent
	UI.list(scroll, { gap = T.space.xs })
	return scroll
end

-- ================================ seed panel ================================
local selected: string = "pine"

builders.seeds = function(parent: Instance): number
	local snap = yardNow()
	if not snap then
		return loading(parent)
	end

	--: The pack, first and largest. Rolling is the loop; the stock below it is
	--: the consequence.
	local pack = UI.panel(parent, {
		size = UDim2.new(1, 0, 0, 62), radius = T.radius.sm, transparency = 0.04,
		color = T.color.panelAlt,
	})
	pack.ZIndex = 23
	UI.label(pack, "Seed pack", {
		size = T.text.sm, font = T.font.bold,
		frameSize = UDim2.new(1, -150, 0, 18),
		pos = UDim2.fromOffset(T.space.md, 10), z = 24,
	})
	UI.label(pack, string.format(
		"One seed, Common to Celestial. %d essence banked.",
		number(snap.essence)), {
		size = T.text.xs, color = T.color.textDim, wrap = true,
		frameSize = UDim2.new(1, -150, 0, 24),
		pos = UDim2.fromOffset(T.space.md, 30), z = 24,
	})
	local roll = UI.button(pack, money(number(snap.packCost)), {
		size = UDim2.fromOffset(112, touch(36)),
		anchor = Vector2.new(1, 0.5),
		pos = UDim2.new(1, -T.space.md, 0.5, 0),
		color = T.color.gold, textColor = T.color.bg,
		skin = "button",
		onClick = function()
			pcall(function() Net.request("rollSeed") end)
			refreshOpen()
		end,
	})
	roll.ZIndex = 24

	local scroll = scroller(parent, 74)

	--: Ordered by rarity so the ladder is visible even when most of it is
	--: empty. A player who has never rolled a Celestial should still be able to
	--: see that one exists.
	local order = {}
	for id, entry in snap.seeds do
		table.insert(order, { id = id, entry = entry })
	end
	table.sort(order, function(a, b)
		if a.entry.tier ~= b.entry.tier then
			return a.entry.tier < b.entry.tier
		end
		return a.entry.seconds < b.entry.seconds
	end)

	for index, row in order do
		local entry = row.entry
		local held = number(entry.held)
		local chosen = row.id == selected
		local tint = RARITY[entry.rarity] or T.color.textDim

		local line = UI.panel(scroll, {
			size = UDim2.new(1, -8, 0, touch(50)),
			radius = T.radius.sm, transparency = if held > 0 then 0.04 else 0.4,
			color = if chosen then T.color.panelAlt else T.color.panel,
			strokeColor = if chosen then tint else T.color.stroke,
		})
		line.LayoutOrder = index
		line.ZIndex = 23

		--: A rarity chip rather than the whole row: colouring the surface fights
		--: the text on it, and this game has seven of them.
		local chip = UI.panel(line, {
			size = UDim2.fromOffset(4, touch(50) - 14),
			pos = UDim2.fromOffset(6, 7), radius = T.radius.sm,
			color = tint, stroke = false, transparency = 0,
		})
		chip.ZIndex = 24

		UI.label(line, entry.name, {
			size = T.text.sm, font = T.font.bold,
			color = if held > 0 then T.color.text else T.color.textDim,
			frameSize = UDim2.new(1, -170, 0, 18),
			pos = UDim2.fromOffset(20, 7), z = 24,
		})
		UI.label(line, string.format("%s \u{00B7} %ds \u{00B7} %d swings \u{00B7} %d each",
			entry.rarity, number(entry.seconds), number(entry.hits),
			number(entry.value)), {
			size = T.text.xs, color = T.color.textDim,
			frameSize = UDim2.new(1, -170, 0, 16),
			pos = UDim2.fromOffset(20, 26), z = 24,
		})

		if held > 0 then
			local pick = UI.button(line, string.format("x%d", held), {
				size = UDim2.fromOffset(84, touch(32)),
				anchor = Vector2.new(1, 0.5),
				pos = UDim2.new(1, -T.space.md, 0.5, 0),
				color = if chosen then T.color.accent else T.color.panelAlt,
				textColor = if chosen then T.color.bg else T.color.text,
				skin = "button",
				onClick = function()
					selected = row.id
					refreshOpen()
				end,
			})
			pick.ZIndex = 24
		else
			--: No seeds of this kind: offer the essence trade rather than an
			--: empty gap. A row that only ever says "you have none" teaches
			--: nothing.
			local cost = number(entry.essence)
			local affordable = number(snap.essence) >= cost
			--: Spelled out rather than a star glyph. \u{2726} is not in the
			--: default font and rendered as an empty box beside every price.
			local trade = UI.button(line, string.format("%d ess", cost), {
				size = UDim2.fromOffset(84, touch(32)),
				anchor = Vector2.new(1, 0.5),
				pos = UDim2.new(1, -T.space.md, 0.5, 0),
				color = if affordable then T.color.panelAlt else T.color.panel,
				textColor = if affordable then T.color.text else T.color.textDim,
				skin = "button",
				onClick = function()
					pcall(function()
						Net.request("convert", { species = row.id })
					end)
					refreshOpen()
				end,
			})
			trade.ZIndex = 24
		end
	end
	return 320
end

-- ============================== the shop floor ==============================
--: Which piece the player is holding, chosen here and spent on a shelf.
local heldCarving: number = 1

builders.store = function(parent: Instance): number
	local snap = yardNow()
	if not snap then
		return loading(parent)
	end

	local floors = number(snap.floors)
	local perFloor = math.max(number(snap.standsPerFloor), 1)
	local head = UI.label(parent, string.format(
		"%d floor%s, %d shelves \u{00B7} %d taken so far",
		floors, if floors == 1 then "" else "s",
		number(snap.standCount), number(snap.takings)), {
		size = T.text.xs, color = T.color.textDim,
		frameSize = UDim2.new(1, 0, 0, 18),
	})
	head.ZIndex = 23

	local scroll = scroller(parent, 26)
	local order = 0
	local carvings = snap.carvings

	if #carvings > 0 then
		order += 1
		local title = UI.label(scroll, "In your pack \u{2014} tap one, then a shelf", {
			size = T.text.xs, font = T.font.bold, color = T.color.textDim,
			frameSize = UDim2.new(1, 0, 0, 16),
		})
		title.LayoutOrder = order
		title.ZIndex = 23
	end

	--: Two taps rather than a drag. A drag inside a scrolling list fights the
	--: scroll on a phone, and this list is always scrolling.
	for index, carving in carvings do
		if index > 12 then
			break
		end
		order += 1
		local chosen = index == heldCarving
		local row = UI.panel(scroll, {
			size = UDim2.new(1, -8, 0, touch(44)), radius = T.radius.sm,
			transparency = 0.04,
			color = if chosen then T.color.panelAlt else T.color.panel,
			strokeColor = if chosen then T.color.gold else T.color.stroke,
		})
		row.LayoutOrder = order
		row.ZIndex = 23
		UI.label(row, string.format("%s %s", carving.qualityName, carving.name), {
			size = T.text.sm, font = T.font.bold,
			color = QUALITY_COLOUR[carving.quality] or T.color.text,
			frameSize = UDim2.new(1, -120, 0, 18),
			pos = UDim2.fromOffset(T.space.md, 12), z = 24,
		})
		local pick = UI.button(row, money(number(carving.value)), {
			size = UDim2.fromOffset(92, touch(30)),
			anchor = Vector2.new(1, 0.5),
			pos = UDim2.new(1, -T.space.md, 0.5, 0),
			color = if chosen then T.color.gold else T.color.panelAlt,
			textColor = if chosen then T.color.bg else T.color.text,
			skin = "button",
			onClick = function()
				heldCarving = index
				refreshOpen()
			end,
		})
		pick.ZIndex = 24
	end

	order += 1
	local shelfTitle = UI.label(scroll, "Shelves", {
		size = T.text.xs, font = T.font.bold, color = T.color.textDim,
		frameSize = UDim2.new(1, 0, 0, 16),
	})
	shelfTitle.LayoutOrder = order
	shelfTitle.ZIndex = 23

	for index = 1, number(snap.standCount) do
		local stand = snap.stands[index]
		order += 1
		local floor = math.floor((index - 1) / perFloor) + 1
		local row = UI.panel(scroll, {
			size = UDim2.new(1, -8, 0, touch(46)), radius = T.radius.sm,
			transparency = if stand then 0.04 else 0.35,
		})
		row.LayoutOrder = order
		row.ZIndex = 23

		if stand then
			UI.label(row, string.format("%s %s", stand.qualityName, stand.name), {
				size = T.text.sm, font = T.font.bold,
				color = QUALITY_COLOUR[stand.quality] or T.color.text,
				frameSize = UDim2.new(1, -190, 0, 18),
				pos = UDim2.fromOffset(T.space.md, 5), z = 24,
			})
			--: Asking against fair, because "is 140 a lot" is not a question a
			--: player can answer without the second number.
			UI.label(row, string.format("floor %d \u{00B7} asking %d \u{00B7} worth %d",
				floor, number(stand.price), number(stand.fair)), {
				size = T.text.xs, color = T.color.textDim,
				frameSize = UDim2.new(1, -190, 0, 16),
				pos = UDim2.fromOffset(T.space.md, 24), z = 24,
			})
			--: Percent of fair value, not a flat number, so the step is the
			--: same decision on a Pine and on a Starheart.
			local steps: { { delta: number, glyph: string, offset: number } } = {
				{ delta = -12, glyph = "\u{2212}", offset = 0 },
				{ delta = 12, glyph = "+", offset = 40 },
			}
			for _, step in steps do
				local delta = step.delta
				local btn = UI.button(row, step.glyph, {
					size = UDim2.fromOffset(touch(32), touch(32)),
					anchor = Vector2.new(1, 0.5),
					pos = UDim2.new(1, -T.space.md - step.offset, 0.5, 0),
					color = T.color.panelAlt, skin = "button",
					onClick = function()
						pcall(function()
							Net.request("setPrice", { stand = index,
								price = number(stand.price)
									+ math.floor(number(stand.fair) * delta / 100) })
						end)
						refreshOpen()
					end,
				})
				btn.ZIndex = 24
			end
			local take = UI.button(row, "Take", {
				size = UDim2.fromOffset(touch(48), touch(32)),
				anchor = Vector2.new(1, 0.5),
				pos = UDim2.new(1, -T.space.md - 86, 0.5, 0),
				color = T.color.panel, skin = "button",
				onClick = function()
					pcall(function()
						Net.request("unstock", { stand = index })
					end)
					refreshOpen()
				end,
			})
			take.ZIndex = 24
		else
			UI.label(row, string.format("Shelf %d \u{00B7} floor %d \u{2014} empty",
				index, floor), {
				size = T.text.sm, color = T.color.textDim,
				frameSize = UDim2.new(1, -120, 0, 18),
				pos = UDim2.fromOffset(T.space.md, 13), z = 24,
			})
			local ready = #carvings > 0
			local put = UI.button(row, "Display", {
				size = UDim2.fromOffset(96, touch(32)),
				anchor = Vector2.new(1, 0.5),
				pos = UDim2.new(1, -T.space.md, 0.5, 0),
				color = if ready then T.color.accent else T.color.panel,
				textColor = if ready then T.color.bg else T.color.textDim,
				skin = "button",
				onClick = function()
					local carving = carvings[heldCarving]
					if not carving then
						return
					end
					pcall(function()
						Net.request("stock", { stand = index,
							carving = heldCarving, price = number(carving.value) })
					end)
					heldCarving = 1
					refreshOpen()
				end,
			})
			put.ZIndex = 24
		end
	end
	return 340
end

-- =============================== upgrade rows ===============================
local function upgradeRow(parent: Instance, order: number, name: string,
                          detail: string, cost: any, remote: string,
                          payload: { [string]: any }?)
	local row = UI.panel(parent, {
		size = UDim2.new(1, -8, 0, 54), radius = T.radius.sm, transparency = 0.06,
	})
	row.LayoutOrder = order
	row.ZIndex = 23
	UI.label(row, name, {
		size = T.text.sm, font = T.font.bold,
		frameSize = UDim2.new(1, -130, 0, 18),
		pos = UDim2.fromOffset(T.space.md, 8), z = 24,
	})
	UI.label(row, detail, {
		size = T.text.xs, color = T.color.textDim, wrap = true,
		frameSize = UDim2.new(1, -130, 0, 22),
		pos = UDim2.fromOffset(T.space.md, 26), z = 24,
	})
	local price = tonumber(cost)
	local buy = UI.button(row, if price then money(price) else "maxed", {
		size = UDim2.fromOffset(96, touch(34)),
		anchor = Vector2.new(1, 0.5),
		pos = UDim2.new(1, -T.space.md, 0.5, 0),
		color = if price then T.color.accent else T.color.panelAlt,
		textColor = if price then T.color.bg else T.color.textDim,
		skin = "button",
		onClick = function()
			if price then
				pcall(function()
					Net.request(remote, payload)
				end)
				refreshOpen()
			end
		end,
	})
	buy.ZIndex = 24
	buy.Active = price ~= nil
end

builders.shop = function(parent: Instance): number
	local snap = yardNow()
	if not snap then
		return loading(parent)
	end
	local scroll = scroller(parent, 0)

	upgradeRow(scroll, 1, string.format("Another plot  (%d)", number(snap.slots)),
		"One more tree growing at a time.", snap.plotCost, "buyPlot")
	upgradeRow(scroll, 2, string.format("Sharper axe  (lvl %d)", number(snap.axe)),
		string.format("Fewer swings to fell, and a wider carving zone. "
			.. "Bites %.1f per swing.", 1 + (number(snap.axe) - 1) * 0.6),
		snap.axeCost, "buyAxe")

	--[[
		The shop's own tree, below the yard's.

		Each row reads its level, cost and whether it is reachable straight from
		`UpgradeTree` -- so `floors` staying hidden until the counter is bought
		is enforced by the module rather than by a condition written twice.
	]]
	local nodes: { { id: string, name: string, blurb: string } } = {
		{ id = "counter", name = "Wider counter",
		  blurb = "One more shelf on every floor." },
		{ id = "floors", name = "Another floor",
		  blurb = "Stack the shop higher. Every floor is a full set of shelves." },
		{ id = "signage", name = "Bigger sign",
		  blurb = "More customers walk in." },
		{ id = "decor", name = "Better fittings",
		  blurb = "Customers pay a little over the odds." },
	}
	local order = 2
	for _, node in nodes do
		local entry = snap.upgrades[node.id]
		if entry and entry.visible then
			order += 1
			upgradeRow(scroll, order,
				string.format("%s  (%d/%d)", node.name, number(entry.level),
					number(entry.max)),
				node.blurb,
				if number(entry.level) < number(entry.max) then entry.cost else nil,
				"buyUpgrade", { node = node.id })
		end
	end
	return 320
end

builders.crew = function(parent: Instance): number
	local ok, snap = pcall(function()
		return Net.request("yard")
	end)
	if not ok or type(snap) ~= "table" then
		return 60
	end
	local crew = number(snap.crew)
	local blurb = UI.label(parent, string.format(
		"%d carver%s at the bench. They carve your logs while you plant and "
		.. "chop \u{2014} they never touch the trees.",
		crew, if crew == 1 then "" else "s"), {
		size = T.text.sm, color = T.color.textDim, wrap = true,
		frameSize = UDim2.new(1, 0, 0, 52),
	})
	blurb.ZIndex = 23

	local list = UI.panel(parent, {
		size = UDim2.new(1, 0, 1, -60), pos = UDim2.fromOffset(0, 58),
		stroke = false, transparency = 1 })
	list.ZIndex = 23
	UI.list(list, { gap = T.space.sm })
	upgradeRow(list, 1, string.format("Hire a carver  (%d)", crew),
		"Each one carves a piece every two seconds.", snap.crewCost, "hire")
	return 130
end

-- ================================ tutorial ==================================
--: Four steps, each of them the loop's own verbs, each completed by reading
--: the yard rather than by watching for a click. A step that waits for a click
--: can be missed; a step that reads state cannot.
local tutorialSteps = {
	{ text = "Open Seeds, pick a Pine, then walk to a plot and plant it.",
	  done = function(snap: any): boolean
		if number(snap.chopped) > 0 or number(snap.logCount) > 0
				or number(snap.carvedCount) > 0 then
			return true
		end
		for _, plot in snap.plots or {} do
			if plot.species then
				return true
			end
		end
		return false
	  end },
	{ text = "Wait for it to grow, then chop it for logs.",
	  done = function(snap: any): boolean
		return number(snap.chopped) > 0
	  end },
	{ text = "Take the logs to the workbench and carve them.",
	  done = function(snap: any): boolean
		return number(snap.carvedCount) > 0 or number(snap.sold) > 0
	  end },
	{ text = "Sell your carvings at the counter. That is the whole loop.",
	  done = function(snap: any): boolean
		return number(snap.sold) > 0
	  end },
}

local tutorial = UI.panel(screen, {
	name = "Tutorial",
	size = UDim2.fromOffset(340, 78),
	anchor = Vector2.new(0, 1),
	pos = UDim2.new(0, T.space.lg, 1, -T.space.lg),
	radius = T.radius.md,
	transparency = 0.08,
	skin = "panel",
})
tutorial.ZIndex = 6
tutorial.Visible = false

local tutorialStep = UI.label(tutorial, "", {
	size = T.text.xs, color = T.color.gold, font = T.font.bold,
	frameSize = UDim2.new(1, -60, 0, 14),
	pos = UDim2.fromOffset(T.space.md, T.space.sm), z = 7,
})
local tutorialText = UI.label(tutorial, "", {
	size = T.text.sm, wrap = true,
	frameSize = UDim2.new(1, -T.space.md * 2 - 24, 0, 42),
	pos = UDim2.fromOffset(T.space.md, 26), z = 7,
})

local dismissed = false
local skip = UI.button(tutorial, "\u{00D7}", {
	name = "Skip",
	--: 44 square, because that is the smallest thing a thumb reliably hits
	--: and this one was 26. The glyph inside stays small; the *target* is
	--: what has to be 44, and those are not the same measurement.
	size = UDim2.fromOffset(touch(44), touch(44)),
	anchor = Vector2.new(1, 0),
	pos = UDim2.new(1, -T.space.sm, 0, T.space.sm),
	radius = T.radius.sm,
	textSize = T.text.md,
	onClick = function()
		--: Dismissible, and it stays dismissed. A tutorial you cannot turn off
		--: is a tutorial people leave over.
		dismissed = true
		tutorial.Visible = false
	end,
})
skip.ZIndex = 8

local function refreshTutorial(snap: any)
	if dismissed or type(snap) ~= "table" then
		return
	end
	for index, step in tutorialSteps do
		if not step.done(snap) then
			tutorial.Visible = true
			tutorialStep.Text = string.format("STEP %d OF %d", index, #tutorialSteps)
			tutorialText.Text = step.text
			return
		end
	end
	--: Finished, said once, then gone. Reachable is the whole point: the
	--: original's equivalent badge is held by 0.0% of its players.
	tutorial.Visible = false
	dismissed = true
	UI.toast("Tutorial complete \u{2014} the yard is yours", { color = T.color.good })
end

-- ================================= feedback =================================
Net.on("notice", function(payload: any)
	if type(payload) ~= "table" or type(payload.text) ~= "string" then
		return
	end
	UI.toast(payload.text, {
		color = if payload.kind == "refused" then T.color.danger
			elseif payload.kind == "good" then T.color.gold
			else T.color.text,
	})
end)

-- ================================ the bench =================================
--[[
	The carving bar.

	The server owns the score: it recomputes where the marker was from when the
	message arrived. This draws the same marker from the same numbers so that
	what the player aims at is what gets measured -- `centre`, `halfWidth` and
	`sweep` come down with the session and the animation is local, because a
	marker replicated sixty times a second is a marker that stutters.

	It sits low and centre, over the hotbar rather than the world: the bench is
	a moment, not a screen, and it has to be gone the instant it ends.
]]
local bench = UI.panel(screen, {
	name = "Bench",
	size = UDim2.fromOffset(420, 108),
	anchor = Vector2.new(0.5, 1),
	pos = UDim2.new(0.5, 0, 1, -T.space.xl),
	radius = T.radius.md,
	skin = "panel",
})
bench.Visible = false
bench.ZIndex = 30

local benchTitle = UI.label(bench, "", {
	name = "Title", size = T.text.sm, font = T.font.bold,
	frameSize = UDim2.new(1, -T.space.md * 2, 0, 20),
	pos = UDim2.fromOffset(T.space.md, 10), z = 31,
})

--: The bar, the zone, and the marker. Three plain frames rather than art: the
--: player is looking at a moving pixel and anything else on it is noise.
local track = UI.panel(bench, {
	name = "Track",
	size = UDim2.new(1, -T.space.md * 2, 0, 22),
	pos = UDim2.fromOffset(T.space.md, 36),
	radius = T.radius.sm, color = T.color.bg, transparency = 0.1,
})
track.ZIndex = 31
track.ClipsDescendants = true

local zone = UI.panel(track, {
	name = "Zone", size = UDim2.fromScale(0.2, 1),
	radius = T.radius.sm, color = T.color.accent, transparency = 0.45,
	stroke = false,
})
zone.ZIndex = 32

local sweet = UI.panel(track, {
	name = "Sweet", size = UDim2.fromScale(0.06, 1),
	radius = T.radius.sm, color = T.color.gold, transparency = 0.25,
	stroke = false,
})
sweet.ZIndex = 33

local marker = UI.panel(track, {
	name = "Marker", size = UDim2.new(0, 4, 1, 0),
	radius = T.radius.sm, color = T.color.text, transparency = 0, stroke = false,
})
marker.ZIndex = 34

local strikeButton = UI.button(bench, "Carve", {
	name = "Strike",
	size = UDim2.new(1, -T.space.md * 2, 0, touch(34)),
	pos = UDim2.fromOffset(T.space.md, 66),
	color = T.color.gold, textColor = T.color.bg,
	skin = "button",
	onClick = function()
		pcall(function()
			Net.request("carveStrike")
		end)
	end,
})
strikeButton.ZIndex = 31

local session: any = nil
local strokeStartedAt = 0

local function hideBench()
	session = nil
	bench.Visible = false
end

--[[
	A swing landing.

	The prompt in front of the player already counts the remaining swings down,
	so this is not information -- it is weight. Without it an axe hit is a
	number changing on a label, and the difference between that and a game is
	entirely in the quarter-second after the press.
]]
Net.on("struck", function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	if payload.felled then
		Feel.shake(0.4)
	else
		Feel.punch(0.14)
	end
end)

Net.on("carveState", function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	if payload.finished then
		local grade = tostring(payload.grade or "rough")
		benchTitle.Text = string.upper(grade)
		--: Held for a beat so the grade is readable, then gone. A panel that
		--: vanishes on the same frame as the last press never gets read.
		task.delay(0.9, function()
			if not session then
				hideBench()
			end
		end)
		session = nil
		return
	end

	session = payload
	strokeStartedAt = os.clock()
	bench.Visible = true
	local half = tonumber(payload.halfWidth) or 0.1
	local centre = tonumber(payload.centre) or 0.5
	benchTitle.Text = string.format("Stroke %d of %d",
		number(payload.stroke), number(payload.strokes))
	zone.Size = UDim2.fromScale(half * 2, 1)
	zone.Position = UDim2.fromScale(centre - half, 0)
	sweet.Size = UDim2.fromScale(half * 0.36, 1)
	sweet.Position = UDim2.fromScale(centre - half * 0.18, 0)
end)

RunService.RenderStepped:Connect(function()
	if not session then
		return
	end
	local sweep = tonumber(session.sweep) or 1.45
	local phase = ((os.clock() - strokeStartedAt) % sweep) / sweep
	local at = if phase <= 0.5 then phase * 2 else (1 - phase) * 2
	marker.Position = UDim2.new(at, -2, 0, 0)
end)

--: The keyboard, because a timing minigame played with a mouse pointer is a
--: timing minigame played badly.
UserInputService.InputBegan:Connect(function(input: InputObject, typing: boolean)
	if typing or not session then
		return
	end
	if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.E then
		pcall(function()
			Net.request("carveStrike")
		end)
	end
end)

-- =============================== the customer ===============================
--[[
	Somebody is standing at a shelf with an offer and a clock.

	Deliberately not a toast. A toast is something you read after the fact, and
	this is a decision with a deadline -- so it has two buttons, a countdown and
	a position that does not move.
]]
local offerCard = UI.panel(screen, {
	name = "Offer",
	size = UDim2.fromOffset(310, 132),
	anchor = Vector2.new(1, 0),
	pos = UDim2.new(1, -T.space.lg, 0, 96),
	radius = T.radius.md,
	skin = "panel",
})
offerCard.Visible = false
offerCard.ZIndex = 30

local offerWho = UI.label(offerCard, "", {
	name = "Who", size = T.text.xs, color = T.color.textDim,
	frameSize = UDim2.new(1, -T.space.md * 2, 0, 16),
	pos = UDim2.fromOffset(T.space.md, 10), z = 31,
})
local offerWhat = UI.label(offerCard, "", {
	name = "What", size = T.text.md, font = T.font.bold,
	frameSize = UDim2.new(1, -T.space.md * 2, 0, 44),
	pos = UDim2.fromOffset(T.space.md, 26), wrap = true, z = 31,
})

local currentOffer: any = nil
local offerUntil = 0

local function closeOffer()
	currentOffer = nil
	offerCard.Visible = false
end

local function answer(accept: boolean)
	local offer = currentOffer
	closeOffer()
	if offer then
		pcall(function()
			Net.request("haggle", { id = offer.id, accept = accept })
		end)
	end
end

local yes = UI.button(offerCard, "Accept", {
	name = "Accept",
	size = UDim2.new(0.5, -T.space.md - 3, 0, touch(34)),
	pos = UDim2.fromOffset(T.space.md, 82),
	color = T.color.gold, textColor = T.color.bg, skin = "button",
	onClick = function()
		answer(true)
	end,
})
yes.ZIndex = 31

local no = UI.button(offerCard, "No", {
	name = "Decline",
	size = UDim2.new(0.5, -T.space.md - 3, 0, touch(34)),
	anchor = Vector2.new(1, 0),
	pos = UDim2.new(1, -T.space.md, 0, 82),
	color = T.color.panelAlt, skin = "button",
	onClick = function()
		answer(false)
	end,
})
no.ZIndex = 31

Net.on("customerOffer", function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	currentOffer = payload
	offerUntil = os.clock() + (tonumber(payload.seconds) or 12)
	offerWho.Text = string.format("Asking %d", number(payload.asking))
	offerWhat.Text = string.format("A customer offers %d", number(payload.offer))
	offerCard.Visible = true
end)

Net.on("saleMade", function()
	--: A sale can close the offer that was open, if the customer bought
	--: something else on the way past.
	if currentOffer then
		closeOffer()
	end
end)

task.spawn(function()
	while true do
		task.wait(0.25)
		if currentOffer then
			local left = offerUntil - os.clock()
			if left <= 0 then
				closeOffer()
			else
				offerWho.Text = string.format("Asking %d \u{00B7} %ds left",
					number(currentOffer.asking), math.ceil(left))
			end
		end
	end
end)

-- =============================== world actions ==============================
--[[
	The prompts in the world are the primary controls.

	A ProximityPrompt already says what the action is and where it happens.
	Duplicating them as on-screen buttons would put two controls on one verb
	and make the yard the less obvious of the two.
]]
ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
	local part = prompt.Parent
	if not part or not part:IsA("BasePart") then
		return
	end
	if prompt.Name == "Act" then
		local plot = part:GetAttribute("plot")
		if type(plot) ~= "number" then
			return
		end
		--: Which verb to ask about depends on the plot; the server decides
		--: whether it is allowed either way.
		pcall(function()
			if prompt.ActionText == "Chop" then
				--: One swing. Holding the prompt repeats it, which is the whole
				--: interaction: the tree comes down over several presses and
				--: the count on the prompt goes with it.
				Net.request("strike", { plot = plot })
			else
				Net.request("plant", { plot = plot, species = selected })
			end
		end)
	elseif prompt.Name == "Carve" then
		pcall(function()
			Net.request("carveBegin", { species = "" })
		end)
	elseif prompt.Name == "Open" and prompt.ActionText == "Manage" then
		showSheet("store", "Your shop")
	elseif prompt.Name == "Sell" then
		pcall(function()
			Net.request("sell")
		end)
	end
end)

-- ================================== poll ====================================
--: One request a second, only to drive the tutorial. The HUD never polls; it
--: is bound to attributes the server publishes.
task.spawn(function()
	while true do
		local ok, snap = pcall(function()
			return Net.request("yard")
		end)
		if ok then
			refreshTutorial(snap)
		end
		task.wait(1)
	end
end)

--[[
	A way in from outside, for the look-and-critique pass.

	Studio refuses synthetic clicks -- `SendMouseButtonEvent` needs a
	capability a game does not have -- and driving by screen coordinates breaks
	the moment anything moves. A BindableFunction the client owns opens the
	same panel the same way a button does, so what gets photographed is what a
	player would see.
]]
do
	local opener = Instance.new("BindableFunction")
	--: The name `forge playtest` looks for. Fixed across games on purpose:
	--: the gate used to derive it from the game id and got `CarvewoodUI`,
	--: which is not where anybody would have put the capital.
	opener.Name = "ForgeUIHook"
	opener.OnInvoke = function(command: any): any
		local text = tostring(command or "")
		local verb, rest = text:match("^(%a+):?(.*)$")
		local titles = { seeds = "Seeds", shop = "Upgrades", crew = "Crew" }
		if verb == "open" and rest ~= "" then
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

function Interface.describe(): { [string]: any }
	return {
		scale = scaler.Scale,
		openPanel = open,
		selectedSeed = selected,
		tutorialVisible = tutorial.Visible,
		icons = Icons.describe(),
	}
end

Forge.Debug.probe("interface", Interface.describe)

return Interface
