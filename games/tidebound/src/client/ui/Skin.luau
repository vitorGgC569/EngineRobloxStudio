--!strict
--[[
	Skin — the shared chrome for Tidebound's interface.

	Every screen in this game is drawn from the same short list of
	ingredients: a panel with a soft vertical wash, a thin accent strip
	along its top edge, icons that arrive by token from
	`Forge.UI.ItchIcons` rather than by asset id, and hover feedback that is
	two property tweens instead of a per-frame loop. Keeping them in one
	file is what stops six screens built at six different times from
	reading as six different games.

	Nothing here holds state or owns a widget. Each helper decorates an
	instance the caller already created, and every one degrades to the
	plain panel when the catalogue does not carry the token: a missing
	icon may cost the icon, never the layout.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local UI = Forge.UI
local Icons = UI.ItchIcons

local Skin = {}

local T = UI.theme

--: A thin rule of accent along a panel's top edge, fading out to the
--: right so the eye lands on the title instead of on the furniture.
function Skin.strip(frame: GuiObject, color: Color3?, options: any?): Frame
	local o = options or {}
	local bar = Instance.new("Frame")
	bar.Name = "AccentStrip"
	bar.BackgroundColor3 = color or T.color.accent
	bar.BorderSizePixel = 0
	bar.Size = o.size or UDim2.new(1, -20, 0, 3)
	bar.Position = o.pos or UDim2.fromOffset(10, 2)
	bar.ZIndex = 2
	bar.Parent = frame
	UI.corner(bar, 2)

	local fade = Instance.new("UIGradient")
	fade.Color = ColorSequence.new(bar.BackgroundColor3, bar.BackgroundColor3)
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 0.85),
	})
	fade.Parent = bar
	return bar
end

--: A vertical wash over the whole face. Two theme colours, one gradient:
--: enough depth that a flat panel reads as a surface.
function Skin.wash(frame: GuiObject, top: Color3?, bottom: Color3?): UIGradient
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(top or T.color.panelAlt, bottom or T.color.panel)
	grad.Parent = frame
	return grad
end

--[[
	An icon by token, or nil.

	The nil is the point. Callers lay out around the glyph -- a left inset
	on a button, a shifted label -- and need to know whether there is one.
	A blank ImageLabel where the catalogue had nothing is exactly the
	failure the ItchIcons header warns about, so the label is destroyed
	when the token misses and the caller keeps its plain presentation.
]]
function Skin.icon(parent: Instance, token: string, options: any?): ImageLabel?
	local o = options or {}
	local glyph = Instance.new("ImageLabel")
	glyph.Name = o.name or "Icon"
	glyph.BackgroundTransparency = 1
	glyph.Size = o.size or UDim2.fromOffset(16, 16)
	glyph.Position = o.pos or UDim2.fromOffset(0, 0)
	glyph.AnchorPoint = o.anchor or Vector2.zero
	glyph.ImageTransparency = o.transparency or 0
	glyph.ZIndex = o.z or 2
	if o.color then
		glyph.ImageColor3 = o.color
	end
	glyph.Parent = parent
	if Icons.apply(glyph, token) then
		return glyph
	end
	glyph:Destroy()
	return nil
end

--: A pill of text: the state chips (luck, hints, tags, score) share one
--: silhouette wherever they appear.
function Skin.chip(parent: Instance, text: string, options: any?): (GuiObject, TextLabel)
	local o = options or {}
	local pill = UI.panel(parent, {
		name = o.name or "Chip",
		size = o.size or UDim2.fromOffset(110, 20),
		pos = o.pos or UDim2.fromOffset(0, 0),
		anchor = o.anchor,
		color = o.color or T.color.panelAlt,
		transparency = o.transparency or 0.2,
		radius = T.radius.pill,
		stroke = o.stroke,
		strokeColor = o.strokeColor,
		visible = o.visible,
	})
	local padX = o.padX or 5
	local label = UI.label(pill, text, {
		font = o.font or T.font.bold,
		size = o.fontSize or T.text.xs,
		color = o.textColor or T.color.text,
		frameSize = UDim2.new(1, -padX * 2, 1, 0),
		pos = UDim2.fromOffset(padX, 0),
		align = o.align or Enum.TextXAlignment.Center,
	})
	return pill, label
end

--[[
	Hover feedback for a card: two property tweens, no loop.

	`Forge.UI.button` already does this for buttons; rows built as plain
	panels had nothing, and a list of dead rectangles is most of what makes
	an interface feel like a placeholder.
]]
function Skin.hover(widget: GuiObject, options: any?)
	local o = options or {}
	local base = widget.BackgroundColor3
	local lit = base:Lerp(o.lift or Color3.new(1, 1, 1), o.boost or 0.08)
	local edge = widget:FindFirstChildOfClass("UIStroke")
	local edgeBase = if edge then edge.Transparency else 0
	local enter = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local leave = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	widget.MouseEnter:Connect(function()
		TweenService:Create(widget, enter, { BackgroundColor3 = lit }):Play()
		if edge then
			TweenService:Create(edge, enter, { Transparency = math.max(0, edgeBase - 0.25) }):Play()
		end
	end)
	widget.MouseLeave:Connect(function()
		TweenService:Create(widget, leave, { BackgroundColor3 = base }):Play()
		if edge then
			TweenService:Create(edge, leave, { Transparency = edgeBase }):Play()
		end
	end)
end

--: A hairline, for separating a header or a footer from a body without
--: drawing a box around either.
function Skin.divider(parent: Instance, y: number, options: any?): Frame
	local o = options or {}
	local line = Instance.new("Frame")
	line.Name = "Divider"
	line.BackgroundColor3 = o.color or T.color.stroke
	line.BackgroundTransparency = o.transparency or 0.6
	line.BorderSizePixel = 0
	line.Size = o.size or UDim2.new(1, -28, 0, 1)
	line.Position = UDim2.fromOffset(o.x or 14, y)
	line.ZIndex = 1
	line.Parent = parent
	return line
end

return Skin
