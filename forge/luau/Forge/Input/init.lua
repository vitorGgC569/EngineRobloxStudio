--!strict
--[[
	Input — actions, not keys.

	Roughly half of Roblox plays on a phone. A game that reads
	`UserInputService.InputBegan` and compares against `Enum.KeyCode.Q` has
	already decided it does not ship there, and usually nobody notices until the
	first mobile session shows a player who cannot dodge.

	So nothing in a game refers to a key. It refers to an action, and the action
	knows what it is on each device:

		Input.defineAction("dodge", {
			keyboard = Enum.KeyCode.Q,
			gamepad  = Enum.KeyCode.ButtonL2,
			touch    = { label = "Dodge", order = 2 },
		})

		Input.bind("dodge", function(phase)
			if phase == "begin" then dodge() end
		end)

		local move = Input.axis("move")     -- WASD, thumbstick or joystick
		if Input.isDown("block") then ... end

	Touch buttons are generated from the definitions. Declaring an action with a
	`touch` table is the entire mobile port for that action — there is no second
	implementation to keep in sync, which is the reason mobile support usually
	rots.

	Rebinding is free because the indirection already exists, and bindings
	persist per player.
]]

local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Core.Signal)
local Trove = require(script.Parent.Core.Trove)

local Input = {}

Input.deviceChanged = Signal.new() -- (device)
Input.actionTriggered = Signal.new() -- (action, phase)

export type TouchSpec = {
	label: string?,
	icon: string?,
	order: number?,
	size: number?,
	anchor: string?, -- "right" (default) | "left"
	hold: boolean?,
}

export type ActionSpec = {
	keyboard: any?, -- KeyCode or UserInputType
	keyboardAlt: any?,
	gamepad: any?,
	touch: TouchSpec?,
	axis: boolean?, -- declares a 2D axis rather than a button
	description: string?,
	rebindable: boolean?,
	priority: number?,
}

local actions: { [string]: ActionSpec } = {}
local handlers: { [string]: { (phase: string, action: string) -> () } } = {}
local down: { [string]: boolean } = {}
local bindings: { [string]: { keyboard: any?, gamepad: any? } } = {}
local touchButtons: { [string]: TextButton } = {}
local mounted = false
local device = "keyboard"
local touchGui: ScreenGui? = nil
local moveVector = Vector2.zero
local touchJoystick: any = nil
-- Every connection this module makes lives here, so `unmount` is one line and
-- a soft restart cannot leave two joysticks listening to the same touch.
local trove = Trove.new()

Input.config = {
	touchButtonSize = 78,
	touchMargin = 22,
	joystickRadius = 84,
	deadzone = 0.18,
}

-- ================================= device ===================================
local function detectDevice(): string
	if UserInputService.GamepadEnabled and UserInputService:GetGamepadConnected(Enum.UserInputType.Gamepad1) then
		return "gamepad"
	end
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		return "touch"
	end
	return "keyboard"
end

function Input.device(): string
	return device
end

function Input.isTouch(): boolean
	return device == "touch"
end

function Input.isGamepad(): boolean
	return device == "gamepad"
end

local function setDevice(next_: string)
	if next_ == device then
		return
	end
	device = next_
	if touchGui then
		touchGui.Enabled = device == "touch"
	end
	Input.deviceChanged:Fire(device)
end

-- =============================== definition =================================
function Input.defineAction(name: string, spec: ActionSpec)
	spec.rebindable = spec.rebindable ~= false
	actions[name] = spec
	bindings[name] = bindings[name] or { keyboard = spec.keyboard, gamepad = spec.gamepad }
	handlers[name] = handlers[name] or {}
	if mounted then
		Input.refresh()
	end
end

function Input.defineActions(table_: { [string]: ActionSpec })
	for name, spec in table_ do
		Input.defineAction(name, spec)
	end
	if mounted then
		Input.refresh()
	end
end

function Input.actions(): { string }
	local out = {}
	for name in actions do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

--[[
	phase is "begin" | "end". Returning true from a handler marks the input
	consumed, which is how a menu takes priority over gameplay without either
	knowing about the other.
]]
function Input.bind(name: string, handler: (phase: string, action: string) -> ()): () -> ()
	if not actions[name] then
		warn(string.format("[Input] '%s' was never defined", name))
	end
	handlers[name] = handlers[name] or {}
	table.insert(handlers[name], handler)
	return function()
		local list = handlers[name]
		local index = table.find(list, handler)
		if index then
			table.remove(list, index)
		end
	end
end

function Input.isDown(name: string): boolean
	return down[name] == true
end

local function fire(name: string, phase: string)
	down[name] = phase == "begin"
	Input.actionTriggered:Fire(name, phase)
	for _, handler in (handlers[name] or {}) do
		local ok, err = pcall(handler, phase, name)
		if not ok then
			warn(string.format("[Input] handler for '%s' errored: %s", name, tostring(err)))
		end
	end
end

Input.fire = fire

-- ================================ movement ==================================
--[[
	One movement vector regardless of device. Keyboard and gamepad come from the
	Humanoid's own MoveDirection so the engine never fights Roblox's control
	scripts; touch adds the virtual joystick on top.
]]
function Input.axis(name: string?): Vector2
	if name and name ~= "move" then
		return Vector2.zero
	end
	if device == "touch" and touchJoystick and touchJoystick.active then
		return touchJoystick.value
	end
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local direction = humanoid.MoveDirection
		return Vector2.new(direction.X, direction.Z)
	end
	return moveVector
end

-- ================================ rebinding =================================
function Input.rebind(name: string, key: any, forDevice: string?)
	local spec = actions[name]
	if not spec or not spec.rebindable then
		return false
	end
	local slot = forDevice or (device == "gamepad" and "gamepad" or "keyboard")
	bindings[name][slot] = key
	Input.refresh()
	return true
end

function Input.binding(name: string, forDevice: string?): any
	local slot = forDevice or (device == "gamepad" and "gamepad" or "keyboard")
	return bindings[name] and bindings[name][slot]
end

-- Readable label for a binding, for a settings screen or a key prompt.
function Input.label(name: string): string
	if device == "touch" then
		local spec = actions[name]
		return spec and spec.touch and (spec.touch.label or name) or name
	end
	local key = Input.binding(name)
	if typeof(key) == "EnumItem" then
		local text = key.Name
		text = string.gsub(text, "^Button", "")
		text = string.gsub(text, "^MouseButton1$", "LMB")
		text = string.gsub(text, "^MouseButton2$", "RMB")
		return text
	end
	return name
end

function Input.serializeBindings(): { [string]: any }
	local out: { [string]: any } = {}
	for name, binding in bindings do
		local spec = actions[name]
		if spec and spec.rebindable then
			out[name] = {
				keyboard = typeof(binding.keyboard) == "EnumItem" and binding.keyboard.Name or nil,
				gamepad = typeof(binding.gamepad) == "EnumItem" and binding.gamepad.Name or nil,
			}
		end
	end
	return out
end

function Input.loadBindings(saved: { [string]: any })
	for name, entry in saved do
		if not bindings[name] then
			continue
		end
		if entry.keyboard and (Enum.KeyCode :: any)[entry.keyboard] then
			bindings[name].keyboard = (Enum.KeyCode :: any)[entry.keyboard]
		end
		if entry.gamepad and (Enum.KeyCode :: any)[entry.gamepad] then
			bindings[name].gamepad = (Enum.KeyCode :: any)[entry.gamepad]
		end
	end
	Input.refresh()
end

-- ============================== touch surface ===============================
local function buildTouchButton(name: string, spec: TouchSpec, index: number)
	local UI = require(script.Parent.UI)
	local T = UI.theme
	local size = spec.size or Input.config.touchButtonSize
	local margin = Input.config.touchMargin

	local button = Instance.new("TextButton")
	button.Name = "Touch_" .. name
	button.Size = UDim2.fromOffset(size, size)
	button.BackgroundColor3 = T.color.panelAlt
	button.BackgroundTransparency = 0.25
	button.BorderSizePixel = 0
	button.Text = spec.label or name
	button.TextSize = T.text.xs
	button.FontFace = T.font.bold
	button.TextColor3 = T.color.text
	button.AutoButtonColor = false

	local order = spec.order or index
	-- Stacked up from the bottom-right thumb arc; the first action declared is
	-- the one closest to the thumb.
	local column = math.floor((order - 1) / 3)
	local row = (order - 1) % 3
	button.Position = UDim2.new(
		1, -(margin + size + column * (size + 10)),
		1, -(margin + size + row * (size + 10))
	)
	if spec.anchor == "left" then
		button.Position = UDim2.new(0, margin + column * (size + 10), 1, -(margin + size + row * (size + 10)))
	end

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = T.color.stroke
	stroke.Thickness = 1.5
	stroke.Transparency = 0.3
	stroke.Parent = button

	trove:connect(button.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			button.BackgroundTransparency = 0.05
			fire(name, "begin")
		end
	end)
	trove:connect(button.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			button.BackgroundTransparency = 0.25
			fire(name, "end")
		end
	end)

	button.Parent = touchGui
	touchButtons[name] = button
end

local function buildJoystick()
	local UI = require(script.Parent.UI)
	local T = UI.theme
	local radius = Input.config.joystickRadius

	local base = Instance.new("Frame")
	base.Name = "Joystick"
	base.Size = UDim2.fromOffset(radius * 2, radius * 2)
	base.Position = UDim2.new(0, Input.config.touchMargin, 1, -(radius * 2 + Input.config.touchMargin))
	base.BackgroundColor3 = T.color.panel
	base.BackgroundTransparency = 0.55
	base.BorderSizePixel = 0
	base.Parent = touchGui

	local baseCorner = Instance.new("UICorner")
	baseCorner.CornerRadius = UDim.new(1, 0)
	baseCorner.Parent = base

	local knob = Instance.new("Frame")
	knob.Size = UDim2.fromOffset(radius * 0.8, radius * 0.8)
	knob.Position = UDim2.fromScale(0.5, 0.5)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.BackgroundColor3 = T.color.text
	knob.BackgroundTransparency = 0.35
	knob.BorderSizePixel = 0
	knob.Parent = base

	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = knob

	local joystick = { active = false, value = Vector2.zero, base = base, knob = knob, inputId = nil }
	touchJoystick = joystick

	local function update(position: Vector2)
		local centre = base.AbsolutePosition + base.AbsoluteSize / 2
		local delta = position - centre
		local distance = math.min(delta.Magnitude, radius)
		local direction = delta.Magnitude > 0.01 and delta.Unit or Vector2.zero
		knob.Position = UDim2.new(0.5, direction.X * distance, 0.5, direction.Y * distance)
		local strength = distance / radius
		joystick.value = strength < Input.config.deadzone and Vector2.zero or direction * strength
	end

	trove:connect(base.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			joystick.active = true
			joystick.inputId = input
			update(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)
	trove:connect(UserInputService.InputChanged, function(input)
		if joystick.active and input == joystick.inputId then
			update(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)
	trove:connect(UserInputService.InputEnded, function(input)
		if input == joystick.inputId then
			joystick.active = false
			joystick.inputId = nil
			joystick.value = Vector2.zero
			knob.Position = UDim2.fromScale(0.5, 0.5)
		end
	end)
end

--[[
	Rebuilds every binding. Cheap, and called whenever an action is added or a
	key is rebound, so there is no path where the live bindings disagree with
	the table.
]]
function Input.refresh()
	if not mounted then
		return
	end

	for name in actions do
		ContextActionService:UnbindAction("Forge_" .. name)
	end

	for name, spec in actions do
		if spec.axis then
			continue
		end
		local keys = {}
		local binding = bindings[name]
		if binding.keyboard then
			table.insert(keys, binding.keyboard)
		end
		if spec.keyboardAlt then
			table.insert(keys, spec.keyboardAlt)
		end
		if binding.gamepad then
			table.insert(keys, binding.gamepad)
		end
		if #keys == 0 then
			continue
		end

		ContextActionService:BindActionAtPriority(
			"Forge_" .. name,
			function(_, inputState)
				if inputState == Enum.UserInputState.Begin then
					fire(name, "begin")
				elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
					fire(name, "end")
				end
				return Enum.ContextActionResult.Pass
			end,
			false,
			spec.priority or Enum.ContextActionPriority.Default.Value,
			table.unpack(keys)
		)
	end

	-- touch surface follows the same definitions
	if touchGui then
		for _, button in touchButtons do
			button:Destroy()
		end
		table.clear(touchButtons)

		local index = 0
		local ordered = {}
		for name, spec in actions do
			if spec.touch then
				table.insert(ordered, { name = name, spec = spec.touch })
			end
		end
		table.sort(ordered, function(a, b)
			return (a.spec.order or 99) < (b.spec.order or 99)
		end)
		for _, entry in ordered do
			index += 1
			buildTouchButton(entry.name, entry.spec, index)
		end
	end
end

function Input.mount()
	if mounted or not RunService:IsClient() then
		return
	end
	mounted = true

	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "ForgeTouch"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	touchGui = gui

	if UserInputService.TouchEnabled then
		buildJoystick()
	end

	setDevice(detectDevice())

	-- Device can change mid-session: a phone with a controller, a laptop that
	-- someone picks up a gamepad for. Following the last input used is the only
	-- detection that matches what the player is actually holding.
	trove:connect(UserInputService.LastInputTypeChanged, function(inputType)
		if inputType == Enum.UserInputType.Touch then
			setDevice("touch")
		elseif inputType.Name:find("Gamepad") then
			setDevice("gamepad")
		elseif inputType == Enum.UserInputType.Keyboard or inputType.Name:find("Mouse") then
			setDevice("keyboard")
		end
	end)

	Input.refresh()
end

--[[
	Tear everything down. Needed by tests and by any flow that rebuilds the
	client shell without a rejoin; without it a second `mount` stacks a second
	joystick on the first.
]]
function Input.unmount()
	if not mounted then
		return
	end
	trove:clean()
	for name in actions do
		ContextActionService:UnbindAction("Forge_" .. name)
	end
	for _, button in touchButtons do
		button:Destroy()
	end
	table.clear(touchButtons)
	if touchGui then
		touchGui:Destroy()
		touchGui = nil
	end
	touchJoystick = nil
	mounted = false
end

function Input.describe(): { [string]: any }
	if not RunService:IsClient() then
		return { context = "client-only", appliesHere = false }
	end
	local report: { [string]: any } = {}
	for name, spec in actions do
		report[name] = {
			keyboard = typeof(bindings[name].keyboard) == "EnumItem" and bindings[name].keyboard.Name or nil,
			gamepad = typeof(bindings[name].gamepad) == "EnumItem" and bindings[name].gamepad.Name or nil,
			touch = spec.touch ~= nil,
			handlers = #(handlers[name] or {}),
		}
	end

	-- An action with no touch spec is an action a phone cannot perform. Naming
	-- them is the cheapest mobile audit there is.
	local unreachableOnTouch = {}
	for name, spec in actions do
		if not spec.touch and not spec.axis then
			table.insert(unreachableOnTouch, name)
		end
	end
	table.sort(unreachableOnTouch)

	return {
		device = device,
		mounted = mounted,
		actions = report,
		unreachableOnTouch = unreachableOnTouch,
		touchButtons = (function()
			local n = 0
			for _ in touchButtons do
				n += 1
			end
			return n
		end)(),
	}
end

return Input
