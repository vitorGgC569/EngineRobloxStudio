--!strict
--[[
	UI — tokens and widgets, so an interface looks designed instead of assembled.

	Agent-built Roblox UI has a signature: default fonts, primary-colour
	backgrounds, no consistent spacing, every panel a slightly different grey.
	The cause is not bad taste, it is that every widget gets invented at the
	point of use with whatever numbers were in mind at that second.

	Tokens fix that. Read colours and spacing from `UI.theme`, never literals,
	and a whole interface stays coherent even when twelve different systems
	built pieces of it.

		local gui = UI.mount("HUD")
		local panel = UI.panel(gui, { size = UDim2.fromOffset(320, 96), pos = ... })
		local hp = UI.bar(panel, { color = UI.theme.color.danger })
		hp:set(0.62)
		UI.toast("Level 7 reached", { color = UI.theme.color.gold })
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Ease = require(script.Parent.Core.Ease)

local UI = {}

-- ================================= tokens ===================================
-- Override any of these before building widgets and the whole UI follows.
UI.theme = {
	color = {
		bg = Color3.fromRGB(16, 15, 20),
		panel = Color3.fromRGB(26, 24, 32),
		panelAlt = Color3.fromRGB(34, 31, 41),
		stroke = Color3.fromRGB(64, 58, 74),
		text = Color3.fromRGB(232, 228, 220),
		textDim = Color3.fromRGB(150, 144, 156),
		accent = Color3.fromRGB(120, 168, 255),
		gold = Color3.fromRGB(238, 196, 108),
		danger = Color3.fromRGB(206, 68, 72),
		warning = Color3.fromRGB(226, 168, 72),
		good = Color3.fromRGB(126, 214, 138),
		mana = Color3.fromRGB(78, 126, 226),
	},
	space = { xs = 4, sm = 8, md = 12, lg = 18, xl = 28 },
	radius = { sm = 4, md = 8, lg = 14, pill = 999 },
	text = { xs = 11, sm = 13, md = 15, lg = 20, xl = 28 },
	font = {
		body = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.Medium),
		bold = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.Bold),
		title = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold),
		mono = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Medium),
	},
}

local T = UI.theme

--: Where the toast column starts. Clear of a top bar by default.
UI.toastTop = 150

-- ================================= mount ====================================
function UI.mount(name: string, options: any?): ScreenGui
	local opts = options or {}
	local player = Players.LocalPlayer
	local parent = player:WaitForChild("PlayerGui")

	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("ScreenGui") then
		return existing
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = opts.resetOnSpawn == true
	gui.IgnoreGuiInset = opts.ignoreInset ~= false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = opts.displayOrder or 10
	gui.Parent = parent
	return gui
end

-- =============================== primitives =================================
local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function stroke(parent: Instance, color: Color3, thickness: number?, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 1
	s.Transparency = transparency or 0.35
	s.Parent = parent
	return s
end

UI.corner = corner
UI.stroke = stroke

--[[
	Skins: real artwork behind a widget, when the catalogue has some.

	A flat panel with a stroke is a respectable default and it is still what
	you get by asking for nothing. But a project that has published a UI pack
	wants the pack's frame, and the difference between "an agent drew a
	rectangle" and "somebody designed this" is mostly that one image.

	Applied as a child `ImageLabel` filling the widget rather than by changing
	what the widget *is*. Layout, sizing and every existing caller are then
	untouched: a skin is a backdrop, and where the catalogue has no frame for
	the role nothing happens and the flat background stays.

	Nine-slice, always. A 96-pixel border stretched across a 600-pixel panel is
	a blur; sliced, the corners draw at their own size and only the middle
	stretches. The rect is measured off the artwork by the publisher, because
	which pixels are the border is not recoverable from the uploaded asset.
]]
local catalogue: any = nil
local catalogueChecked = false

local function skinBook(): any
	if not catalogueChecked then
		catalogueChecked = true
		local module = script:FindFirstChild("ItchIcons")
		if module and module:IsA("ModuleScript") then
			local ok, loaded = pcall(require, module)
			catalogue = if ok then loaded else nil
		end
	end
	return catalogue
end

--: Returns whether it skinned, so a caller can decide what to do with the
--: flat background it was otherwise going to draw.
--: Second return says whether the art fills its own middle. Half the panel
--: frames in these packs are overlay borders drawn with a transparent centre,
--: and a widget that clears its own fill for one of those has no surface left
--: -- which is exactly how the first skinned HUD came out invisible.
--: Set an ImageLabel's own image and slice rect from the catalogue, for when
--: the widget *is* the picture. A panel takes this form; a labelled button
--: cannot, because a TextButton has Text and an ImageButton does not.
function UI.dress(image: any, role: string, state: string?): (boolean, boolean, boolean)
	local book = skinBook()
	if not book or not book.skin then
		return false, false, false
	end
	local took, opaque, dark = book.skin(image, role, state)
	return took == true, opaque == true, dark == true
end

function UI.skin(widget: GuiObject, role: string, state: string?): (boolean, boolean, boolean)
	local book = skinBook()
	if not book or not book.skin then
		return false, false, false
	end

	local found = widget:FindFirstChild("Skin")
	local image = if found and found:IsA("ImageLabel")
		then found :: ImageLabel
		else Instance.new("ImageLabel")
	image.Name = "Skin"
	image.Size = UDim2.fromScale(1, 1)
	image.BackgroundTransparency = 1
	--[[
		The ZIndex here orders this image among *its siblings*, and that is all
		it can do.

		`mount` sets `ZIndexBehavior.Sibling`, and the name says what it means:
		ZIndex sorts siblings, while a child is drawn above its parent
		**always**, whatever the numbers say. So a skin parented to the widget
		it decorates covers that widget's own text, and no ZIndex can move it
		behind. Measured the long way round: the label was present, white,
		opaque, visible, with `TextBounds` of 51x12 -- laid out and drawn, and
		painted over by its own background.

		This form is therefore only for widgets that have no content of their
		own to cover. Anything with text uses the holder in `UI.button`.
	]]
	--: Followed, not copied once. A caller that raises the widget's ZIndex
	--: after building it -- which is how anything gets above a scrim -- would
	--: otherwise leave its own skin behind at the old depth.
	local function follow()
		image.ZIndex = math.max(widget.ZIndex - 1, 0)
	end
	follow()
	if not image:FindFirstChild("ZFollow") then
		local marker = Instance.new("BoolValue")
		marker.Name = "ZFollow"
		marker.Parent = image
		widget:GetPropertyChangedSignal("ZIndex"):Connect(follow)
	end
	image.Parent = widget

	local took, opaque, dark = book.skin(image, role, state)
	if not took then
		image:Destroy()
		return false, false, false
	end
	return true, opaque == true, dark == true
end

--[[
	A panel is a Frame, or an ImageLabel when it is skinned.

	Not a Frame with an image child, which is what this did first and what
	broke it: a `UIListLayout` on the panel lays out **every** visible
	GuiObject under it, and the skin is one. It took the first row at full
	width and pushed the real contents out of the panel -- a top bar whose
	frame was drawn in one place and whose readouts were laid out beside it,
	off the edge, which is the sort of thing only a screenshot shows.

	Roblox has no "ignore this child" flag for a layout, so making the
	background *be* the container is the fix. It is also simpler: one instance,
	and the layout's children are only ever content.

	Both are `GuiObject`, so callers cannot tell and nothing downstream changes.
]]
--: Swap a skinned button's face without rebuilding it. The face is the
--: button's *sibling*, so it is reached through the holder.
function UI.reskin(button: GuiObject, role: string, state: string): boolean
	local holder = button.Parent
	if not holder or not holder:IsA("GuiObject") then
		return false
	end
	local face = holder:FindFirstChild("Skin")
	if not face or not face:IsA("ImageLabel") then
		return false
	end
	return (UI.dress(face, role, state))
end

function UI.panel(parent: Instance, options: any?): GuiObject
	local o = options or {}

	local f: any = nil
	local dressed, solid = false, false
	if o.skin then
		local candidate = Instance.new("ImageLabel")
		dressed, solid = UI.dress(candidate, o.skin, o.skinState)
		if dressed then
			f = candidate
		else
			candidate:Destroy()
		end
	end
	if not f then
		f = Instance.new("Frame")
	end

	f.Name = o.name or "Panel"
	f.Size = o.size or UDim2.fromOffset(240, 120)
	f.Position = o.pos or UDim2.fromOffset(0, 0)
	f.AnchorPoint = o.anchor or Vector2.zero
	f.BackgroundColor3 = o.color or T.color.panel
	--: Only an opaque frame replaces the fill. An overlay border keeps it, and
	--: reads as a border *on* a panel, which is what it was drawn to be.
	f.BackgroundTransparency = if solid then 1 else (o.transparency or 0.08)
	f.BorderSizePixel = 0
	f.Visible = o.visible ~= false
	f.Parent = parent

	corner(f, o.radius or T.radius.md)
	if o.stroke ~= false and not dressed then
		stroke(f, o.strokeColor or T.color.stroke)
	end
	if o.padding then
		local p = Instance.new("UIPadding")
		local pad = UDim.new(0, o.padding)
		p.PaddingTop, p.PaddingBottom, p.PaddingLeft, p.PaddingRight = pad, pad, pad, pad
		p.Parent = f
	end
	return f
end

function UI.label(parent: Instance, text: string, options: any?): TextLabel
	local o = options or {}
	local l = Instance.new("TextLabel")
	l.Name = o.name or "Label"
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextSize = o.size or T.text.md
	l.FontFace = o.font or T.font.body
	l.TextColor3 = o.color or T.color.text
	l.TextXAlignment = o.align or Enum.TextXAlignment.Left
	l.TextYAlignment = o.valign or Enum.TextYAlignment.Center
	l.TextWrapped = o.wrap == true
	l.RichText = o.rich ~= false
	l.Size = o.frameSize or UDim2.new(1, 0, 1, 0)
	l.Position = o.pos or UDim2.fromOffset(0, 0)
	l.AnchorPoint = o.anchor or Vector2.zero
	l.ZIndex = o.z or 2
	l.Parent = parent
	return l
end

--[[
	A bar with a delayed trail. The trail is the whole point: it shows how much
	damage just landed, which is information the player cannot get from a bar
	that simply jumps to its new value.
]]
function UI.bar(parent: Instance, options: any?)
	local o = options or {}
	local color = o.color or T.color.danger

	local holder = Instance.new("Frame")
	holder.Name = o.name or "Bar"
	holder.Size = o.size or UDim2.new(1, 0, 0, 18)
	holder.Position = o.pos or UDim2.fromOffset(0, 0)
	holder.AnchorPoint = o.anchor or Vector2.zero
	holder.BackgroundColor3 = o.background or Color3.fromRGB(20, 18, 24)
	holder.BorderSizePixel = 0
	holder.ClipsDescendants = true
	holder.Parent = parent
	corner(holder, o.radius or T.radius.sm)

	local trail = Instance.new("Frame")
	trail.Size = UDim2.fromScale(1, 1)
	trail.BackgroundColor3 = color:Lerp(Color3.new(1, 1, 1), 0.5)
	trail.BackgroundTransparency = 0.45
	trail.BorderSizePixel = 0
	trail.ZIndex = 2
	trail.Parent = holder

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.ZIndex = 3
	fill.Parent = holder

	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.22), color)
	grad.Rotation = 90
	grad.Parent = fill

	if o.stroke ~= false then
		stroke(holder, T.color.stroke, 1, 0.5)
	end

	local api = {
		holder = holder,
		fill = fill,
		trail = trail,
		value = 1,
		target = 1,
		trailValue = 1,
	}

	function api:set(alpha: number)
		api.target = math.clamp(alpha, 0, 1)
	end

	function api:setInstant(alpha: number)
		api.target = math.clamp(alpha, 0, 1)
		api.value = api.target
		api.trailValue = api.target
		fill.Size = UDim2.fromScale(api.value, 1)
		trail.Size = UDim2.fromScale(api.value, 1)
	end

	function api:step(dt: number)
		api.value = Ease.approach(api.value, api.target, o.speed or 14, dt)
		fill.Size = UDim2.fromScale(api.value, 1)
		if api.trailValue > api.value then
			api.trailValue = Ease.approach(api.trailValue, api.value, o.trailSpeed or 2.2, dt)
		else
			api.trailValue = api.value
		end
		trail.Size = UDim2.fromScale(api.trailValue, 1)
	end

	--[[
		Self-driving unless the caller wants to own the loop.

		Note the separate `local conn` declaration. Written as
		`local conn = signal:Connect(function() conn:Disconnect() end)`, the
		`conn` inside the closure is not the local — it is not in scope yet — so
		it resolves to a nil global and the disconnect errors every frame after
		the bar is destroyed, leaking the connection forever. It compiles, and
		only a static analysis pass over unknown globals found it.
	]]
	if o.autoStep ~= false and RunService:IsClient() then
		local conn: RBXScriptConnection
		conn = RunService.RenderStepped:Connect(function(dt)
			if not holder.Parent then
				conn:Disconnect()
				return
			end
			api:step(dt)
		end)
		api.connection = conn
	end

	return api
end

function UI.button(parent: Instance, text: string, options: any?): TextButton
	local o = options or {}
	local b = Instance.new("TextButton")
	b.Name = o.name or "Button"
	b.Size = o.size or UDim2.fromOffset(140, 34)
	b.Position = o.pos or UDim2.fromOffset(0, 0)
	b.AnchorPoint = o.anchor or Vector2.zero
	b.BackgroundColor3 = o.color or T.color.panelAlt
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.Text = text
	b.TextSize = o.textSize or T.text.sm
	b.FontFace = T.font.bold
	b.TextColor3 = o.textColor or T.color.text
	b.Parent = parent

	--: Opt-in, like the panel's. Defaulting it on would put itch button faces
	--: behind every button in every game that already has its own art, without
	--: anybody asking for it or being told.
	local role = if type(o.skin) == "string" then o.skin
		elseif o.skin == true then "button"
		else nil

	--[[
		A skinned button is two siblings in a holder, not a button with a
		picture inside it.

		Under `Sibling` behaviour a child always draws above its parent, so a
		skin parented to the button hides the button's own label -- which it
		did, completely, while every property said the text was fine. Siblings
		*are* ordered by ZIndex, so putting the face and the button side by
		side inside a transparent holder puts the label back on top.

		The holder takes the size, position and layout slot the caller asked
		for; the button fills it. Callers keep the TextButton, so `.Text` and
		`.Active` still work on what they were handed.
	]]
	local skinned, solid, dark = false, false, false
	if role then
		local face = Instance.new("ImageLabel")
		local took: boolean
		took, solid, dark = UI.dress(face, role, "normal")
		if took then
			skinned = true
			local holder = Instance.new("Frame")
			holder.Name = (o.name or "Button") .. "Holder"
			holder.Size = b.Size
			holder.Position = b.Position
			holder.AnchorPoint = b.AnchorPoint
			holder.BackgroundTransparency = 1
			holder.BorderSizePixel = 0
			holder.LayoutOrder = b.LayoutOrder
			holder.Parent = parent

			face.Name = "Skin"
			face.Size = UDim2.fromScale(1, 1)
			face.BackgroundTransparency = 1
			face.ZIndex = 1
			face.Parent = holder

			b.Size = UDim2.fromScale(1, 1)
			b.Position = UDim2.fromOffset(0, 0)
			b.AnchorPoint = Vector2.zero
			b.ZIndex = 2
			b.Parent = holder

			--: The caller raises the button's ZIndex to clear a scrim; the
			--: holder is the thing that actually needs to be above it.
			b:GetPropertyChangedSignal("ZIndex"):Connect(function()
				holder.ZIndex = b.ZIndex
			end)
			holder.ZIndex = b.ZIndex
		else
			face:Destroy()
		end
	end
	if solid then
		b.BackgroundTransparency = 1
		--[[
			The label's colour is re-decided, and overriding the caller here is
			deliberate.

			A caller picks text to read against the fill it asked for. A skin
			replaces that fill with artwork the caller has never seen, so the
			choice it made is about a background that no longer exists. This
			one was black text chosen for an accent-blue button, landing on a
			face drawn white-outside-black-inside: the label was still there,
			still the right string, and completely invisible.

			The interior's luminance is measured at publish time, so the widget
			can answer this rather than the caller guessing.
		]]
		b.TextColor3 = if dark then T.color.text else T.color.bg
	end

	corner(b, o.radius or T.radius.sm)
	local s = if skinned then nil else stroke(b, o.strokeColor or T.color.stroke)

	local base = b.BackgroundColor3
	local hover = base:Lerp(Color3.new(1, 1, 1), 0.12)

	--[[
		Two ways to show a press, and which one is right depends on the art.

		Unskinned, the background lightens and the stroke sharpens. Skinned,
		the *face swaps* -- to whatever the pack drew for `hover` and
		`pressed`, falling back to the normal face where it drew none. Tinting
		a drawn button lighter looks like a rendering fault; swapping to the
		artist's own hover state looks like the pack intended.
	]]
	b.MouseEnter:Connect(function()
		if skinned then
			UI.reskin(b, role :: string, "hover")
			return
		end
		TweenService:Create(b, TweenInfo.new(0.12), { BackgroundColor3 = hover }):Play()
		if s then
			TweenService:Create(s, TweenInfo.new(0.12), { Transparency = 0 }):Play()
		end
	end)
	b.MouseLeave:Connect(function()
		if skinned then
			UI.reskin(b, role :: string, "normal")
			return
		end
		TweenService:Create(b, TweenInfo.new(0.16), { BackgroundColor3 = base }):Play()
		if s then
			TweenService:Create(s, TweenInfo.new(0.16), { Transparency = 0.35 }):Play()
		end
	end)
	-- press feedback: 60ms of scale is the difference between a button that
	-- responds and one that feels broken
	b.MouseButton1Down:Connect(function()
		if skinned then
			UI.reskin(b, role :: string, "pressed")
		end
		TweenService:Create(b, TweenInfo.new(0.06), { Size = (o.size or UDim2.fromOffset(140, 34)) - UDim2.fromOffset(4, 4) }):Play()
	end)
	b.MouseButton1Up:Connect(function()
		if skinned then
			UI.reskin(b, role :: string, "normal")
		end
		TweenService:Create(b, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = o.size or UDim2.fromOffset(140, 34) }):Play()
	end)

	if o.onClick then
		b.MouseButton1Click:Connect(o.onClick)
	end
	return b
end

function UI.list(parent: Instance, options: any?): UIListLayout
	local o = options or {}
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = o.horizontal and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, o.gap or T.space.sm)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = o.hAlign or Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = o.vAlign or Enum.VerticalAlignment.Top
	layout.Parent = parent
	return layout
end

-- ================================= toasts ===================================
local toastHolder: Frame? = nil

function UI.toast(text: string, options: any?)
	if not RunService:IsClient() then
		return
	end
	local o = options or {}

	if not toastHolder or not toastHolder.Parent then
		local gui = UI.mount("ForgeToasts", { displayOrder = 500 })
		local holder = Instance.new("Frame")
		holder.Name = "Toasts"
		holder.Size = UDim2.fromOffset(360, 400)
		--[[
			Below where a HUD puts its top bar, not on top of it.

			Ninety pixels is where a status shelf lives, and three stacked
			toasts covered the wave, the integrity meter and the balance
			completely -- the three things a player is most likely to be
			checking at the moment something worth announcing happens.

			`toastTop` overrides it for a game whose HUD sits somewhere else.
		]]
		holder.Position = UDim2.new(0.5, -180, 0, UI.toastTop)
		holder.BackgroundTransparency = 1
		holder.Parent = gui
		UI.list(holder, { gap = T.space.sm, hAlign = Enum.HorizontalAlignment.Center })
		toastHolder = holder
	end

	local frame = UI.panel(toastHolder :: Frame, {
		size = UDim2.fromOffset(340, 34),
		transparency = 0.15,
		radius = T.radius.sm,
	})
	frame.BackgroundColor3 = T.color.panelAlt

	local label = UI.label(frame, text, {
		color = o.color or T.color.text,
		size = T.text.sm,
		align = Enum.TextXAlignment.Center,
		font = T.font.bold,
	})
	label.Size = UDim2.new(1, -16, 1, 0)
	label.Position = UDim2.fromOffset(8, 0)

	frame.BackgroundTransparency = 1
	label.TextTransparency = 1
	TweenService:Create(frame, TweenInfo.new(0.18), { BackgroundTransparency = 0.15 }):Play()
	TweenService:Create(label, TweenInfo.new(0.18), { TextTransparency = 0 }):Play()

	task.delay(o.duration or 3, function()
		if not frame.Parent then
			return
		end
		TweenService:Create(frame, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
		local out = TweenService:Create(label, TweenInfo.new(0.3), { TextTransparency = 1 })
		out.Completed:Connect(function()
			frame:Destroy()
		end)
		out:Play()
	end)
end

-- What a validator reads to prove the interface exists and is populated.
function UI.describe(): { [string]: any }
	local player = Players.LocalPlayer
	local gui = player and player:FindFirstChild("PlayerGui")
	if not gui then
		return { mounted = false }
	end
	local screens = {}
	for _, child in gui:GetChildren() do
		if child:IsA("ScreenGui") then
			table.insert(screens, {
				name = child.Name,
				enabled = child.Enabled,
				descendants = #child:GetDescendants(),
			})
		end
	end
	return { mounted = true, screens = screens }
end


--[[
	Siblings, resolved on the first thing that asks for one.

	This family holds modules beside this file, and until now the only way to
	reach them was to require the instance directly — so `Forge.UI.AttributeInteractions`
	was nil while `require(ReplicatedStorage.Forge.UI.AttributeInteractions)` worked. Two
	conventions in one engine, and the inconsistency is the defect: the first
	game written against `Forge.Core.Boot` died on `attempt to index nil`.

	Lazy rather than eager, matching `Forge` itself. Touching one family must
	not drag in every module it contains — several of them build tables and
	open connections at load, and paying for all of that to read one constant
	is how a require graph becomes a frame budget.
]]
return setmetatable(UI, {
	__index = function(self, key: string): any
		local child = script:FindFirstChild(key)
		if not child or not child:IsA("ModuleScript") then
			return nil
		end
		local module = require(child) :: any
		rawset(self, key, module)
		return module
	end,
})
