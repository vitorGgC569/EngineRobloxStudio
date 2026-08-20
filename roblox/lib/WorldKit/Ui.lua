--!strict
-- L6: UI design system.
--
-- Built on Flexbox (`UIListLayout.HorizontalFlex`/`VerticalFlex` plus
-- `UIFlexItem`, released August 2024) and driven entirely by L0 tokens. Nothing
-- in this module accepts a raw pixel value for spacing, size or colour: those
-- come from the token scale, which is what makes a screen re-themeable and
-- consistent instead of a pile of offsets somebody tuned once.
--
-- Three measured defects are made impossible here rather than documented:
--
--   * `UIListLayout` and `UIGridLayout` sort **alphabetically** by default. That
--     is how a tab strip meant to read Base / Vender / Praça shipped reading
--     Base / Praça / Vender. Every layout this module creates sets
--     `SortOrder = LayoutOrder`, and every child gets an explicit `LayoutOrder`.
--   * `AutomaticSize` in the fill direction is the flex basis. Setting a fixed
--     size *and* expecting flex to fit content is the most common way a panel
--     ends up clipping its own text.
--   * A handler that references a variable declared later in the file kills the
--     whole script with no server-side trace. Builders here return their
--     instance and never close over anything defined below them.

local Tokens = require(script.Parent.Tokens)

local Ui = {}

export type Options = { [string]: any }

local nextOrder: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any

local function fail(message: string): never
	error("[WorldKit.Ui] " .. message, 3)
end

--- Assign the next explicit LayoutOrder within a container.
---
--- Never left to chance. A child without an order is a child the engine sorts by
--- name, and names are presentation, not sequence.
local function order(parent: Instance, explicit: number?): number
	if explicit ~= nil then
		return explicit
	end
	local current = (nextOrder[parent] or 0) + 1
	nextOrder[parent] = current
	return current
end

local function applyCommon(instance: GuiObject, parent: Instance, options: Options)
	instance.BackgroundTransparency = if options.backgroundTransparency ~= nil
		then options.backgroundTransparency
		else 1
	instance.BorderSizePixel = 0
	instance.LayoutOrder = order(parent, options.layoutOrder)
	if options.size ~= nil then
		instance.Size = options.size
	end
	if options.position ~= nil then
		instance.Position = options.position
	end
	if options.anchorPoint ~= nil then
		instance.AnchorPoint = options.anchorPoint
	end
	if options.automaticSize ~= nil then
		instance.AutomaticSize = options.automaticSize
	end
	if options.visible ~= nil then
		instance.Visible = options.visible
	end
	if options.name ~= nil then
		instance.Name = options.name
	end
	instance.Parent = parent
end

local function corner(instance: GuiObject, radius: number)
	local shape = Instance.new("UICorner")
	shape.CornerRadius = UDim.new(0, radius)
	shape.Parent = instance
end

local function pad(instance: GuiObject, amount: number)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, amount)
	padding.PaddingBottom = UDim.new(0, amount)
	padding.PaddingLeft = UDim.new(0, amount)
	padding.PaddingRight = UDim.new(0, amount)
	padding.Parent = instance
end

-- ------------------------------------------------------------------- screen

--- A ScreenGui with the defaults a production UI actually needs.
function Ui.screen(parent: Instance, name: string, options: Options?): ScreenGui
	local opts = options or {}
	local screen = Instance.new("ScreenGui")
	screen.Name = name
	screen.ResetOnSpawn = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Respects notches and home indicators. Off by default in the engine, which
	-- is why so many mobile layouts have a button under the home bar.
	screen.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	screen.IgnoreGuiInset = opts.ignoreGuiInset == true
	screen.DisplayOrder = opts.displayOrder or 0
	screen.Enabled = if opts.enabled ~= nil then opts.enabled else true
	screen.Parent = parent
	return screen
end

-- -------------------------------------------------------------------- stack

--- A flex container. `direction` is "row" or "column".
function Ui.stack(tokens: Tokens.TokenSet, parent: Instance, direction: string, options: Options?): Frame
	local opts = options or {}
	if direction ~= "row" and direction ~= "column" then
		fail('stack direction must be "row" or "column"')
	end

	local frame = Instance.new("Frame")
	applyCommon(frame, parent, opts)
	if opts.size == nil then
		frame.Size = UDim2.fromScale(1, 1)
	end

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = if direction == "row"
		then Enum.FillDirection.Horizontal
		else Enum.FillDirection.Vertical
	-- The single most important line in this module.
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, tokens:space(opts.gap or "base"))
	layout.HorizontalAlignment = opts.horizontalAlignment or Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = opts.verticalAlignment or Enum.VerticalAlignment.Center
	if opts.flex ~= nil then
		local alignment = (Enum.UIFlexAlignment :: any)[opts.flex]
		if typeof(alignment) ~= "EnumItem" then
			fail("unknown UIFlexAlignment: " .. tostring(opts.flex))
		end
		if direction == "row" then
			layout.HorizontalFlex = alignment
		else
			layout.VerticalFlex = alignment
		end
	end
	layout.Parent = frame

	if opts.padding ~= nil then
		pad(frame, tokens:space(opts.padding))
	end
	return frame
end

--- Mark a child as the one that absorbs leftover space.
function Ui.flexible(instance: GuiObject, mode: string?): UIFlexItem
	local item = Instance.new("UIFlexItem")
	local resolved = (Enum.UIFlexMode :: any)[mode or "Fill"]
	if typeof(resolved) ~= "EnumItem" then
		fail("unknown UIFlexMode: " .. tostring(mode))
	end
	item.FlexMode = resolved
	item.Parent = instance
	return item
end

--- Fixed empty space, when flex is the wrong tool.
function Ui.spacer(tokens: Tokens.TokenSet, parent: Instance, step: string, options: Options?): Frame
	local opts = options or {}
	local amount = tokens:space(step)
	local frame = Instance.new("Frame")
	frame.Name = "Spacer"
	frame.Size = UDim2.fromOffset(amount, amount)
	applyCommon(frame, parent, opts)
	return frame
end

-- -------------------------------------------------------------------- panel

--- The dark card everything else sits on.
---
--- Matching the reference: a near-black ground with a bright stroke, generous
--- corner radius and real padding. The stroke is what stops a panel from
--- dissolving into a bright world behind it.
function Ui.panel(tokens: Tokens.TokenSet, parent: Instance, options: Options?): Frame
	local opts = options or {}
	local frame = Instance.new("Frame")
	frame.Name = opts.name or "Panel"
	frame.BackgroundColor3 = tokens:color(opts.role or "ink")
	applyCommon(frame, parent, opts)
	frame.BackgroundTransparency = opts.backgroundTransparency or 0.05

	-- Grows to fit what is in it, unless a size was asked for.
	--
	-- A Frame defaults to 100x100 pixels, and a panel left at that size draws a
	-- small dark square while its children render outside it. A capture with a
	-- screen open showed exactly that: the title, the body text and the Close
	-- button floating over the world with a stamp-sized backing behind one of
	-- them. Every panel in every generated game was doing this, and no test
	-- caught it because none of them had ever been opened.
	if opts.size == nil and opts.automaticSize == nil then
		frame.AutomaticSize = Enum.AutomaticSize.XY
	end

	-- And stacks them, for the same reason.
	--
	-- Without a layout, every child sits at the panel origin: the title, the
	-- body and the button drew on top of one another. A panel is a column
	-- unless it is told otherwise, which is what every caller already assumed.
	if opts.layout ~= false then
		local list = Instance.new("UIListLayout")
		list.FillDirection = Enum.FillDirection.Vertical
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Padding = UDim.new(0, tokens:space(opts.gap or "tight"))
		list.HorizontalAlignment = Enum.HorizontalAlignment.Center
		list.Parent = frame
	end

	corner(frame, tokens:space(opts.radius or "base"))
	pad(frame, tokens:space(opts.padding or "roomy"))

	local stroke = Instance.new("UIStroke")
	stroke.Color = tokens:color(opts.strokeRole or "neutralLight")
	stroke.Thickness = opts.strokeThickness or 2
	stroke.Transparency = opts.strokeTransparency or 0.72
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame

	return frame
end

-- --------------------------------------------------------------------- text

local function font(tokens: Tokens.TokenSet, weight: string?): Font
	return Font.new(
		"rbxasset://fonts/families/" .. tokens.raw.typography.family .. ".json",
		tokens:weight(weight or "medium")
	)
end

--- A text label at a named type step.
function Ui.text(tokens: Tokens.TokenSet, parent: Instance, step: string, body: string, options: Options?): TextLabel
	local opts = options or {}
	local label = Instance.new("TextLabel")
	label.Name = opts.name or "Text"
	label.Text = body
	label.FontFace = font(tokens, opts.weight)
	label.TextSize = tokens:text(step)
	label.TextColor3 = tokens:color(opts.role or "neutralLight")
	label.TextXAlignment = opts.xAlign or Enum.TextXAlignment.Center
	label.TextYAlignment = opts.yAlign or Enum.TextYAlignment.Center
	label.TextWrapped = opts.wrapped == true
	-- Content-sized by default. A label with a fixed size and wrapped text is
	-- how a string silently gets clipped on the one device nobody tested.
	label.AutomaticSize = opts.automaticSize or Enum.AutomaticSize.XY
	applyCommon(label, parent, opts)
	if opts.size == nil then
		label.Size = UDim2.fromOffset(0, 0)
	end

	if opts.outline ~= false then
		-- A bright world behind white text destroys it. The reference leans on a
		-- heavy dark outline for exactly this reason.
		local stroke = Instance.new("UIStroke")
		stroke.Color = tokens:color("ink")
		stroke.Thickness = opts.outlineThickness or 2
		stroke.Transparency = opts.outlineTransparency or 0.15
		stroke.Parent = label
	end
	return label
end

--- A numeric readout: label above, value below, value in the success accent.
--- A glyph drawn from primitives, for a place where a word will not do.
---
--- The goal is explicit that improvised text is not an icon, and it is right:
--- a HUD reading "cash 49  wave 4  integrity 0" makes a player parse four
--- labels every time they glance at it, and at a glance is the only time a HUD
--- is ever read.
---
--- Drawn rather than uploaded. An image asset needs a round trip through
--- moderation before it can appear, and a generated game that cannot show an
--- icon until someone publishes it is a game that ships with placeholders. A
--- coin is a disc with a rim; a wave is a stack of chevrons; a shield is a
--- tapered plate. Frames and corners, no upload, and the colours come from the
--- token set so they belong to the same language as the world.
---
--- Sized in token steps and validated by `Ui.audit` at the size it is used,
--- because an icon that reads at 128px and smears at 24 is the failure the goal
--- names specifically.
function Ui.icon(tokens: Tokens.TokenSet, parent: Instance, kind: string, options: Options?): Frame
	local opts = options or {}
	local size = opts.iconSize or tokens:text("title")
	local role = opts.role or "accentGold"

	local holder = Instance.new("Frame")
	holder.Name = opts.name or ("Icon_" .. kind)
	holder.Size = UDim2.fromOffset(size, size)
	holder.BackgroundTransparency = 1
	holder:SetAttribute("RQEIcon", kind)
	applyCommon(holder, parent, opts)

	local function shape(name: string, scale: Vector2, offset: Vector2,
		colour: Color3, rounded: number?): Frame
		local piece = Instance.new("Frame")
		piece.Name = name
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Position = UDim2.fromScale(0.5 + offset.X, 0.5 + offset.Y)
		piece.Size = UDim2.fromScale(scale.X, scale.Y)
		piece.BackgroundColor3 = colour
		piece.BorderSizePixel = 0
		piece.Parent = holder
		if rounded ~= nil then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(rounded, 0)
			corner.Parent = piece
		end
		return piece
	end

	local accent = tokens:color(role)
	local dark = tokens:color("ink")

	-- A plate under every glyph.
	--
	-- Without it `wave` and `tier` were stacks of bars all in one accent: no
	-- internal edge, nothing for the eye to resolve, and at 16px four of them
	-- in a row read as gold smudges. `Ui.audit` had been reporting exactly that
	-- for every size, and it went unread because the audit only ran inside a
	-- live HUD. Rendering the components on their own surfaced it in seconds.
	--
	-- The plate is what gives a flat glyph its contrast, and it doubles as
	-- separation from whatever the camera happens to be pointing at.
	local plate = Instance.new("Frame")
	plate.Name = "Plate"
	plate.AnchorPoint = Vector2.new(0.5, 0.5)
	plate.Position = UDim2.fromScale(0.5, 0.5)
	plate.Size = UDim2.fromScale(1, 1)
	plate.BackgroundColor3 = dark
	plate.BackgroundTransparency = 0.15
	plate.BorderSizePixel = 0
	plate.ZIndex = 0
	plate.Parent = holder
	local plateCorner = Instance.new("UICorner")
	plateCorner.CornerRadius = UDim.new(0.28, 0)
	plateCorner.Parent = plate

	if kind == "currency" or kind == "coin" then
		shape("Rim", Vector2.new(0.9, 0.9), Vector2.new(0, 0), dark, 0.5)
		shape("Face", Vector2.new(0.72, 0.72), Vector2.new(0, 0), accent, 0.5)
		shape("Mark", Vector2.new(0.16, 0.42), Vector2.new(0, 0), dark, 0.3)
	elseif kind == "wave" then
		-- Three chevrons: the shape a wave counter wants, and the same language
		-- the threat lane on the ground uses.
		-- Alternating weight as well as a plate: the middle bar heavier gives
		-- the stack a direction, which is what makes three bars read as a wave
		-- rather than as a menu icon.
		for index = 0, 2 do
			local thickness = if index == 1 then 0.2 else 0.13
			shape("Chevron" .. index, Vector2.new(0.58, thickness),
				Vector2.new(0, -0.26 + index * 0.26), accent, 0.5)
		end
	elseif kind == "integrity" or kind == "shield" then
		shape("Plate", Vector2.new(0.78, 0.86), Vector2.new(0, -0.04), accent, 0.32)
		shape("Boss", Vector2.new(0.34, 0.34), Vector2.new(0, -0.06), dark, 0.5)
	elseif kind == "tier" or kind == "upgrade" then
		for index = 0, 2 do
			local width = 0.66 - index * 0.19
			shape("Step" .. index, Vector2.new(width, 0.14),
				Vector2.new(0, 0.28 - index * 0.28), accent, 0.4)
		end
	elseif kind == "tower" then
		shape("Base", Vector2.new(0.68, 0.2), Vector2.new(0, 0.34), dark, 0.2)
		shape("Shaft", Vector2.new(0.4, 0.6), Vector2.new(0, -0.02), accent, 0.15)
		shape("Crown", Vector2.new(0.62, 0.16), Vector2.new(0, -0.34), dark, 0.3)
	else
		fail(string.format(
			"unknown icon %q; drawn icons are currency, wave, integrity, tier, tower. "
			.. "An icon nobody drew would fall back to a coloured square, which is "
			.. "the improvised placeholder this function exists to remove", kind))
	end

	return holder
end

function Ui.value(tokens: Tokens.TokenSet, parent: Instance, caption: string, body: string, options: Options?): Frame
	local opts = options or {}
	local group = Ui.stack(tokens, parent, "column", {
		name = opts.name or "Value",
		gap = "hair",
		size = UDim2.fromOffset(0, 0),
		automaticSize = Enum.AutomaticSize.XY,
		layoutOrder = opts.layoutOrder,
	})
	if opts.icon ~= nil then
		-- An icon instead of the caption, not beside it: a glyph plus its own
		-- name is the label twice, and the HUD has no room to say anything
		-- twice.
		Ui.icon(tokens, group, opts.icon, {
			name = "Glyph",
			iconSize = opts.iconSize,
			role = opts.iconRole,
		})
	else
		Ui.text(tokens, group, opts.captionStep or "caption", caption, {
			role = "neutralLight",
			weight = "medium",
			name = "Caption",
		})
	end
	Ui.text(tokens, group, opts.valueStep or "title", body, {
		role = opts.valueRole or "accentSuccess",
		weight = "bold",
		name = "Amount",
	})
	return group
end

-- ------------------------------------------------------------------- button

--- A button that reacts.
---
--- Hover and press states come from the motion tokens, so every button in every
--- game built on this SDK moves at the same speed with the same curve. That
--- consistency is most of what "feels finished" means.
function Ui.button(tokens: Tokens.TokenSet, parent: Instance, body: string, options: Options?): TextButton
	local opts = options or {}
	local roleName = opts.role or "accentGold"
	local base = tokens:color(roleName)

	local button = Instance.new("TextButton")
	button.Name = opts.name or "Button"
	button.Text = ""
	button.AutoButtonColor = false
	button.BackgroundColor3 = base
	applyCommon(button, parent, opts)
	button.BackgroundTransparency = 0
	if opts.size == nil then
		button.AutomaticSize = Enum.AutomaticSize.XY
		button.Size = UDim2.fromOffset(0, 0)
	end

	corner(button, tokens:space(opts.radius or "snug"))
	pad(button, tokens:space(opts.padding or "base"))

	-- A layout, so AutomaticSize can measure the label.
	--
	-- Without one the button grew to some size unrelated to its text and the
	-- fill came out narrower than the words sitting on it -- three buttons in a
	-- row overlapped each other. The same defect `Ui.panel` had, found the same
	-- way: by rendering the component on its own instead of inside a running
	-- game where it was one small wrong thing among many.
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = tokens:color("ink")
	stroke.Thickness = 2
	stroke.Transparency = 0.25
	stroke.Parent = button

	local label = Ui.text(tokens, button, opts.step or "label", body, {
		role = opts.labelRole or "ink",
		weight = "bold",
		name = "Label",
		outline = false,
	})
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)

	-- Everything below is declared after `button` exists, deliberately.
	local duration = tokens:duration("quick")
	local easing = tokens:easing("standard")
	local info = TweenInfo.new(duration, easing.style, easing.direction)
	local TweenService = game:GetService("TweenService")

	local function tint(scale: number)
		TweenService:Create(button, info, {
			BackgroundColor3 = Color3.new(
				math.clamp(base.R * scale, 0, 1),
				math.clamp(base.G * scale, 0, 1),
				math.clamp(base.B * scale, 0, 1)
			),
		}):Play()
	end

	button.MouseEnter:Connect(function()
		tint(1.12)
	end)
	button.MouseLeave:Connect(function()
		tint(1)
	end)
	button.MouseButton1Down:Connect(function()
		tint(0.85)
	end)
	button.MouseButton1Up:Connect(function()
		tint(1.12)
	end)

	return button
end

-- --------------------------------------------------------------------- grid

--- A grid that also respects LayoutOrder.
function Ui.grid(tokens: Tokens.TokenSet, parent: Instance, cell: Vector2, options: Options?): Frame
	local opts = options or {}
	local frame = Instance.new("Frame")
	frame.Name = opts.name or "Grid"
	applyCommon(frame, parent, opts)
	if opts.size == nil then
		frame.Size = UDim2.fromScale(1, 1)
	end

	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(cell.X, cell.Y)
	local gap = tokens:space(opts.gap or "snug")
	layout.CellPadding = UDim2.fromOffset(gap, gap)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = opts.horizontalAlignment or Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = opts.verticalAlignment or Enum.VerticalAlignment.Top
	layout.Parent = frame
	return frame
end

--- A scrolling list with the scrollbar sized to its content.
function Ui.scroller(tokens: Tokens.TokenSet, parent: Instance, options: Options?): ScrollingFrame
	local opts = options or {}
	local scroller = Instance.new("ScrollingFrame")
	scroller.Name = opts.name or "Scroller"
	scroller.ScrollBarThickness = opts.scrollBarThickness or 6
	scroller.ScrollBarImageColor3 = tokens:color("neutralLight")
	scroller.ScrollBarImageTransparency = 0.5
	-- Content-driven canvas. A hand-maintained CanvasSize is always one item out
	-- of date.
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.CanvasSize = UDim2.new()
	scroller.ScrollingDirection = opts.direction or Enum.ScrollingDirection.Y
	applyCommon(scroller, parent, opts)
	if opts.size == nil then
		scroller.Size = UDim2.fromScale(1, 1)
	end

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, tokens:space(opts.gap or "snug"))
	layout.Parent = scroller
	return scroller
end

-- ------------------------------------------------------------------- motion

--- Tween using a named motion token.
--- Tween a property, and land on the value whether or not the tween can run.
---
--- TweenService does not animate in Studio's edit mode. That is not an edge
--- case here: the scene critic captures screenshots in edit mode, so every
--- meter in every game the factory made photographed at whatever its Size was
--- when it was built -- which is full. A HUD showing 100% health while the
--- attribute said 17 is the kind of defect that survives review, because the
--- picture looks fine.
---
--- Measured: `meterSet(tokens, meter, 0.35)` left `Fill.Size.X.Scale` at 1.00
--- both before and after, in edit context.
---
--- So the goal is applied directly when nothing will animate it, and tweened
--- when something will. Callers get the same end state either way, which is the
--- only promise this function should be making.
function Ui.animate(tokens: Tokens.TokenSet, instance: Instance, durationName: string, easingName: string, goal: { [string]: any }): Tween?
	local easing = tokens:easing(easingName)
	local info = TweenInfo.new(tokens:duration(durationName), easing.style, easing.direction)
	local tween = game:GetService("TweenService"):Create(instance, info, goal)

	if not game:GetService("RunService"):IsRunning() then
		for property, value in pairs(goal) do
			-- One bad property must not cost the others their value.
			pcall(function()
				(instance :: any)[property] = value
			end)
		end
		return nil
	end

	tween:Play()
	return tween
end

-- --------------------------------------------------------------- hud kit

--- A vertical sheen, which is what makes a flat fill read as a surface.
---
--- Two stops, both subtle. A gradient strong enough to notice is a gradient
--- that dates the interface; the job here is only to stop a rectangle looking
--- like a rectangle.
local function sheen(instance: GuiObject, strength: number?): UIGradient
	local amount = strength or 0.12
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.new(1 - amount, 1 - amount, 1 - amount)),
	})
	gradient.Parent = instance
	return gradient
end

--- A readout in a container: icon, value, and something to sit on.
---
--- The version this replaces drew an icon and a number directly onto the world.
--- Over a bright sky the number vanished; over a dark wall the icon did. A chip
--- is the smallest thing that fixes both, and it is what every shipped Roblox
--- HUD uses for currency.
function Ui.chip(tokens: Tokens.TokenSet, parent: Instance, options: Options?): Frame
	local opts = options or {}
	local frame = Instance.new("Frame")
	frame.Name = opts.name or "Chip"
	frame.BackgroundColor3 = tokens:color(opts.role or "ink")
	-- Nearly clear. The shelf is the surface; a chip is a division inside it,
	-- and when both carried a strong fill the bar read as four loose pills
	-- rather than one readout.
	-- Enough fill to separate one readout from the next. At 0.75 the four chips
	-- ran together into a single line of text with glyphs between the numbers,
	-- which is the crowding this component was added to fix.
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.Size = UDim2.fromOffset(0, 0)
	applyCommon(frame, parent, opts)
	-- After `applyCommon`, not before.
	--
	-- It resets BackgroundTransparency to 1 whenever the caller did not pass
	-- one, so setting it above was silently undone: the chips and the shelf
	-- rendered fully transparent through three rounds of "adjust and look at a
	-- screenshot", and every capture was ambiguous between "the fix did
	-- nothing" and "the fix is subtle". Reading the property back said 1.
	frame.BackgroundTransparency = opts.backgroundTransparency or 0.45

	corner(frame, tokens:space("snug"))
	pad(frame, tokens:space(opts.padding or "tight"))

	-- A light top edge. The cheapest possible suggestion of a raised surface,
	-- and the reason a chip does not read as a hole cut in the screen.
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, tokens:space("hair"))
	row.Parent = frame

	if opts.icon ~= nil then
		Ui.icon(tokens, frame, opts.icon, {
			name = "Glyph",
			iconSize = opts.iconSize or tokens:text("body"),
			role = opts.iconRole,
			layoutOrder = 1,
		})
	end
	Ui.text(tokens, frame, opts.step or "body", tostring(opts.value or ""), {
		name = "Amount",
		weight = "bold",
		role = opts.valueRole or "neutralLight",
		layoutOrder = 2,
	})
	return frame
end

--- A meter: a proportion the eye reads without counting.
---
--- Integrity as a number tells a player nothing at a glance -- 62 is only
--- meaningful against a maximum they have to remember. A bar is the shape of
--- the question they are actually asking, which is "how much is left".
---
--- Returns the fill so a caller can drive it; `Ui.meterSet` does the clamping.
function Ui.meter(tokens: Tokens.TokenSet, parent: Instance, options: Options?): Frame
	local opts = options or {}
	local track = Instance.new("Frame")
	track.Name = opts.name or "Meter"
	track.BackgroundColor3 = tokens:color("ink")
	track.BackgroundTransparency = 0.25
	track.Size = opts.size or UDim2.new(0, 168, 0, tokens:space("base"))
	applyCommon(track, parent, opts)
	corner(track, tokens:space("hair"))

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = tokens:color(opts.role or "accentSuccess")
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(math.clamp(tonumber(opts.fraction) or 1, 0, 1), 1)
	fill.Parent = track
	corner(fill, tokens:space("hair"))
	sheen(fill, 0.18)

	local stroke = Instance.new("UIStroke")
	stroke.Color = tokens:color("neutralLight")
	stroke.Thickness = 1
	stroke.Transparency = 0.86
	stroke.Parent = track
	return track
end

--- Drive a meter, with the colour carrying the urgency.
---
--- Green to gold to red is not decoration: a player glancing at a bar reads
--- colour before length, so the colour has to agree with the number or the
--- fastest signal on screen is the wrong one.
function Ui.meterSet(tokens: Tokens.TokenSet, meter: Frame, fraction: number): ()
	local fill = meter:FindFirstChild("Fill")
	if fill == nil or not fill:IsA("Frame") then
		return
	end
	local value = math.clamp(fraction, 0, 1)
	local role = if value > 0.5 then "accentSuccess"
		elseif value > 0.2 then "accentGold"
		else "accentDanger"
	;(fill :: Frame).BackgroundColor3 = tokens:color(role)
	Ui.animate(tokens, fill, "quick", "standard", {
		Size = UDim2.fromScale(value, 1),
	})
end

--- The bar that holds the chips: one surface, not four floating numbers.
---
--- Grouping is hierarchy. Four separate readouts are four things to find; one
--- shelf with four chips in it is one thing to glance at, and the difference
--- costs a single frame.
function Ui.shelf(tokens: Tokens.TokenSet, parent: Instance, options: Options?): Frame
	local opts = options or {}
	local frame = Instance.new("Frame")
	frame.Name = opts.name or "Shelf"
	frame.BackgroundColor3 = tokens:color("ink")
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.Size = UDim2.fromOffset(0, 0)
	applyCommon(frame, parent, opts)
	frame.BackgroundTransparency = opts.backgroundTransparency or 0.15

	corner(frame, tokens:space("base"))
	pad(frame, tokens:space(opts.padding or "tight"))
	sheen(frame, 0.08)

	local stroke = Instance.new("UIStroke")
	stroke.Color = tokens:color("neutralLight")
	stroke.Thickness = 1
	stroke.Transparency = 0.88
	stroke.Parent = frame

	local row = Instance.new("UIListLayout")
	row.FillDirection = if opts.direction == "column"
		then Enum.FillDirection.Vertical
		else Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, tokens:space(opts.gap or "tight"))
	row.Parent = frame
	return frame
end

-- ------------------------------------------------------------------- audit

--- The smallest size a drawn glyph still reads at, and the thinnest part it can
--- be made of. Both are measured against the icons in this module: the chevron
--- stack is the tightest of them at 0.16 of the box, which puts its bars at
--- 2.6px when the box is 16 -- just above the floor, and under it at 12.
local ICON_MIN_PX = 16
local ICON_MIN_FEATURE_PX = 2

--- Report layout hazards in an existing tree.
---
--- Written because every defect it looks for actually shipped here at least
--- once, and none of them produces an error.
function Ui.audit(root: Instance): { string }
	local problems: { string } = {}
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("UIListLayout") or descendant:IsA("UIGridLayout") then
			if (descendant :: any).SortOrder ~= Enum.SortOrder.LayoutOrder then
				table.insert(problems, string.format(
					"%s sorts by Name; children will appear in alphabetical order",
					descendant:GetFullName()
				))
			end
		end
		if descendant:GetAttribute("RQEIcon") ~= nil then
			-- An icon is only an icon at the size it is drawn at. The goal names
			-- 16-64px because that is the band a HUD actually uses, and a glyph
			-- that resolves in a mockup at 128 can arrive as a smear at 20.
			local frame = descendant :: Frame
			local box = frame.AbsoluteSize.X
			if box <= 0 then
				box = frame.Size.X.Offset
			end
			if box > 0 and box < ICON_MIN_PX then
				table.insert(problems, string.format(
					"%s draws icon %q at %dpx; below %dpx its parts fall under a "
					.. "pixel and it reads as a coloured square",
					descendant:GetFullName(), tostring(descendant:GetAttribute("RQEIcon")),
					box, ICON_MIN_PX
				))
			end
			local tones = {}
			local count = 0
			for _, piece in ipairs(frame:GetChildren()) do
				if piece:IsA("GuiObject") then
					local part = piece :: GuiObject
					local thin = math.min(part.Size.X.Scale, part.Size.Y.Scale) * box
					if box > 0 and thin > 0 and thin < ICON_MIN_FEATURE_PX then
						table.insert(problems, string.format(
							"%s has a %.1fpx feature at icon size %dpx; anything under "
							.. "%dpx aliases away",
							part:GetFullName(), thin, box, ICON_MIN_FEATURE_PX
						))
					end
					local key = tostring(part.BackgroundColor3)
					if tones[key] == nil then
						tones[key] = true
						count += 1
					end
				end
			end
			if count < 2 then
				table.insert(problems, string.format(
					"%s draws its icon in one tone; a single-tone glyph has no "
					.. "internal edge and reads as a block", descendant:GetFullName()
				))
			end
		end
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			local text = descendant :: TextLabel
			if text.TextScaled and text.TextWrapped == false and text.AutomaticSize == Enum.AutomaticSize.None then
				table.insert(problems, string.format(
					"%s is TextScaled with a fixed size and no wrapping; long strings will be unreadable",
					descendant:GetFullName()
				))
			end
			if text.TextTransparency < 1 and text.TextColor3 == text.BackgroundColor3 and text.BackgroundTransparency < 1 then
				table.insert(problems, string.format(
					"%s draws text in its own background colour", descendant:GetFullName()
				))
			end
		end
	end
	return problems
end

return Ui
