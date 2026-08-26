--!strict
-- Shared UI construction helpers + palette. One consistent visual language. The base API
-- (frame/label/button/corner/fadeIn/screenGui) is unchanged so existing screens keep
-- working; this pass deepens the palette and adds gradient/stroke/panel helpers plus a
-- universal press-pop on every button for a more tactile, shipped-title feel.

local TweenService = game:GetService("TweenService")

local Theme = {}

Theme.Colors = {
	Bg = Color3.fromRGB(14, 15, 20),
	Panel = Color3.fromRGB(26, 28, 36),
	PanelLight = Color3.fromRGB(40, 43, 54),
	Text = Color3.fromRGB(238, 240, 245),
	TextDim = Color3.fromRGB(150, 154, 168),
	Infected = Color3.fromRGB(120, 226, 92),
	Survivor = Color3.fromRGB(92, 172, 255),
	Danger = Color3.fromRGB(235, 74, 74),
	Gold = Color3.fromRGB(248, 200, 76),
	-- Accent gradient endpoints for headers / hero buttons.
	AccentA = Color3.fromRGB(120, 226, 92),
	AccentB = Color3.fromRGB(64, 196, 160),
}

Theme.Font = Enum.Font.GothamBold
Theme.FontLight = Enum.Font.Gotham
Theme.FontDisplay = Enum.Font.GothamBlack

function Theme.corner(instance: Instance, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 8)
	corner.Parent = instance
end

-- Add a UIStroke outline. Returns it so callers can tweak/animate.
function Theme.stroke(instance: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Theme.Colors.PanelLight
	stroke.Thickness = thickness or 1
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = instance
	return stroke
end

-- Add a vertical (default) UIGradient between two colors.
function Theme.gradient(instance: Instance, top: Color3, bottom: Color3, rotation: number?): UIGradient
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(top, bottom)
	gradient.Rotation = rotation or 90
	gradient.Parent = instance
	return gradient
end

function Theme.frame(parent: Instance, props: { [string]: any }): Frame
	local frame = Instance.new("Frame")
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = Theme.Colors.Panel
	for k, v in props do
		(frame :: any)[k] = v
	end
	frame.Parent = parent
	return frame
end

-- A finished "card": rounded panel with a soft top-lit gradient and a subtle border.
function Theme.panel(parent: Instance, props: { [string]: any }): Frame
	local frame = Theme.frame(parent, props)
	Theme.corner(frame, 14)
	Theme.gradient(frame, Theme.Colors.PanelLight, Theme.Colors.Panel, 90)
	Theme.stroke(frame, Color3.fromRGB(60, 64, 78), 1, 0.35)
	return frame
end

function Theme.label(parent: Instance, props: { [string]: any }): TextLabel
	local label = Instance.new("TextLabel")
	label.BorderSizePixel = 0
	label.BackgroundTransparency = 1
	label.Font = Theme.Font
	label.TextColor3 = Theme.Colors.Text
	label.TextScaled = false
	label.TextSize = 16
	for k, v in props do
		(label :: any)[k] = v
	end
	label.Parent = parent
	return label
end

-- Universal press-pop: buttons scale down slightly while held, springing back on
-- release/leave. Purely visual and independent of BackgroundColor3, so it never fights
-- call sites that recolor a button for state.
local function attachPress(button: GuiButton)
	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = button
	local function to(target: number, style: Enum.EasingStyle)
		TweenService:Create(scale, TweenInfo.new(0.12, style, Enum.EasingDirection.Out), { Scale = target })
			:Play()
	end
	button.MouseButton1Down:Connect(function()
		to(0.95, Enum.EasingStyle.Quad)
	end)
	button.MouseButton1Up:Connect(function()
		to(1, Enum.EasingStyle.Back)
	end)
	button.MouseLeave:Connect(function()
		to(1, Enum.EasingStyle.Quad)
	end)
end

function Theme.button(parent: Instance, props: { [string]: any }): TextButton
	local button = Instance.new("TextButton")
	button.BorderSizePixel = 0
	button.BackgroundColor3 = Theme.Colors.PanelLight
	button.Font = Theme.Font
	button.TextColor3 = Theme.Colors.Text
	button.TextSize = 16
	button.AutoButtonColor = true
	for k, v in props do
		(button :: any)[k] = v
	end
	button.Parent = parent
	Theme.corner(button)
	attachPress(button)
	return button
end

function Theme.fadeIn(instance: GuiObject, duration: number?)
	instance.Visible = true
	local tween = TweenService:Create(
		instance,
		TweenInfo.new(duration or 0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = instance.BackgroundTransparency }
	)
	tween:Play()
end

function Theme.screenGui(name: string, displayOrder: number?): ScreenGui
	local Players = game:GetService("Players")
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = displayOrder or 1
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return gui
end

return Theme
