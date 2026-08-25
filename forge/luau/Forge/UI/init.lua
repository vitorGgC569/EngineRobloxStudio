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

function UI.panel(parent: Instance, options: any?): Frame
	local o = options or {}
	local f = Instance.new("Frame")
	f.Name = o.name or "Panel"
	f.Size = o.size or UDim2.fromOffset(240, 120)
	f.Position = o.pos or UDim2.fromOffset(0, 0)
	f.AnchorPoint = o.anchor or Vector2.zero
	f.BackgroundColor3 = o.color or T.color.panel
	f.BackgroundTransparency = o.transparency or 0.08
	f.BorderSizePixel = 0
	f.Visible = o.visible ~= false
	f.Parent = parent

	corner(f, o.radius or T.radius.md)
	if o.stroke ~= false then
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

	corner(b, o.radius or T.radius.sm)
	local s = stroke(b, o.strokeColor or T.color.stroke)

	local base = b.BackgroundColor3
	local hover = base:Lerp(Color3.new(1, 1, 1), 0.12)

	b.MouseEnter:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.12), { BackgroundColor3 = hover }):Play()
		TweenService:Create(s, TweenInfo.new(0.12), { Transparency = 0 }):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.16), { BackgroundColor3 = base }):Play()
		TweenService:Create(s, TweenInfo.new(0.16), { Transparency = 0.35 }):Play()
	end)
	-- press feedback: 60ms of scale is the difference between a button that
	-- responds and one that feels broken
	b.MouseButton1Down:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.06), { Size = (o.size or UDim2.fromOffset(140, 34)) - UDim2.fromOffset(4, 4) }):Play()
	end)
	b.MouseButton1Up:Connect(function()
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
		holder.Position = UDim2.new(0.5, -180, 0, 90)
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
