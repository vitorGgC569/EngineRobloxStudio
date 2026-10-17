--!strict
--[[
	AscendPanel — the life reset, staged behind a deliberate second click.

	This is the most destructive button in the game: it wipes the rift and
	every dojo upgrade. The requirement -- reach a floor -- is the server's
	(`state.ascend.can`), and so is everything shown on this card. The panel
	only performs the ceremony: first click arms, second within three
	seconds confirms, anything else decays back to safe.

	Two guards, because one is not enough. `armed` is local and expires on a
	timer; `pendingLife` remembers the life the server confirmed, so the
	button reads ASCENDING until a state with a new life arrives. A dropped
	click, a lagged push, an alt-tab -- none of them can leave a dead
	button, because the state push is the only way out.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local UI = Forge.UI
local Icons = UI.ItchIcons

local Theme = require(script.Parent.Theme)

local Panel = {}
Panel.id = "ascend"
Panel.icon = "status.star"
Panel.label = "ASCEND"

local function icon(parent: Instance, token: string, size: number, pos: UDim2,
                    color: Color3): any
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

local function currentState(scope: any, fallback: any): any
	if scope ~= nil and scope.getState ~= nil then
		local state = scope.getState()
		if type(state) == "table" then
			return state
		end
	end
	return fallback
end

function Panel.mount(parent: Instance, scope: any)
	local lastState: any = nil
	local pendingLife: any = nil
	local armed = false
	local button: any = nil

	local root = Instance.new("Frame")
	root.Name = "AscendRoot"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Visible = false
	root.ZIndex = 5
	root.Parent = parent

	local veil = UI.panel(root, {
		name = "Veil",
		size = UDim2.fromScale(1, 1),
		color = Color3.new(0, 0, 0),
		transparency = 0.5,
		radius = 0,
		stroke = false,
	})
	veil.ZIndex = 1

	local window = UI.panel(root, {
		name = "Window",
		size = UDim2.fromScale(0.92, 0.92),
		pos = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		color = Theme.color.panel,
	})
	window.ZIndex = 2

	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(560, 460)
	limit.Parent = window

	local title = UI.label(window, "ASCENSION", {
		name = "Title",
		font = Theme.font.title,
		size = Theme.text.lg,
		frameSize = UDim2.new(1, -260, 0, 34),
		pos = UDim2.fromOffset(14, 10),
		z = 3,
	})

	local close = UI.button(window, "", {
		name = "Close",
		size = UDim2.fromOffset(44, 44),
		pos = UDim2.new(1, -8, 0, 6),
		anchor = Vector2.new(1, 0),
		color = Theme.color.panelAlt,
		textSize = Theme.text.md,
		onClick = function()
			scope.close()
		end,
	})
	close.ZIndex = 3
	if icon(close, "action.close", 20, UDim2.new(0.5, -10, 0.5, -10), Theme.color.text) == nil then
		close.Text = "X"
	end

	-- -------------------------------------------------------------- summary
	local card = UI.panel(window, {
		name = "Info",
		size = UDim2.new(1, -28, 0, 168),
		pos = UDim2.fromOffset(14, 56),
		color = Theme.color.panelAlt,
		stroke = false,
	})

	UI.label(card, "Essence multiplier", {
		name = "Row1Key",
		size = Theme.text.md,
		color = Theme.color.textDim,
		frameSize = UDim2.new(1, -240, 0, 24),
		pos = UDim2.fromOffset(16, 12),
	})

	local essenceValue = UI.label(card, "1x", {
		name = "Row1Value",
		font = Theme.font.bold,
		size = Theme.text.md,
		color = Theme.color.gold,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.fromOffset(200, 24),
		pos = UDim2.new(1, -16, 0, 12),
		anchor = Vector2.new(1, 0),
	})

	UI.label(card, "Required floor", {
		name = "Row2Key",
		size = Theme.text.md,
		color = Theme.color.textDim,
		frameSize = UDim2.new(1, -240, 0, 24),
		pos = UDim2.fromOffset(16, 48),
	})

	local requiredValue = UI.label(card, "0", {
		name = "Row2Value",
		font = Theme.font.bold,
		size = Theme.text.md,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.fromOffset(200, 24),
		pos = UDim2.new(1, -16, 0, 48),
		anchor = Vector2.new(1, 0),
	})

	UI.label(card, "Your best floor", {
		name = "Row3Key",
		size = Theme.text.md,
		color = Theme.color.textDim,
		frameSize = UDim2.new(1, -240, 0, 24),
		pos = UDim2.fromOffset(16, 84),
	})

	local bestValue = UI.label(card, "0", {
		name = "Row3Value",
		font = Theme.font.bold,
		size = Theme.text.md,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.fromOffset(200, 24),
		pos = UDim2.new(1, -16, 0, 84),
		anchor = Vector2.new(1, 0),
	})

	UI.label(card, "Essence on ascend", {
		name = "Row4Key",
		size = Theme.text.md,
		color = Theme.color.textDim,
		frameSize = UDim2.new(1, -240, 0, 24),
		pos = UDim2.fromOffset(16, 120),
	})

	local gainValue = UI.label(card, "+0", {
		name = "Row4Value",
		font = Theme.font.bold,
		size = Theme.text.md,
		color = Theme.color.good,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.fromOffset(200, 24),
		pos = UDim2.new(1, -16, 0, 120),
		anchor = Vector2.new(1, 0),
	})

	UI.label(window, "Resets Rift and upgrades. Keeps auras, collection, tower best, gems.", {
		name = "Explainer",
		size = Theme.text.md,
		color = Theme.color.textDim,
		align = Enum.TextXAlignment.Center,
		wrap = true,
		frameSize = UDim2.new(1, -28, 0, 44),
		pos = UDim2.fromOffset(14, 236),
	})

	-- ---------------------------------------------------------------- states
	local function refresh(state: any)
		if type(state) ~= "table" then
			return
		end
		lastState = state

		local life = tonumber(state.life) or 0
		if pendingLife ~= nil and pendingLife ~= life then
			pendingLife = nil
		end

		title.Text = string.format("ASCENSION — LIFE %d", life)

		local info = if type(state.ascend) == "table" then state.ascend else nil
		local required = if info ~= nil then tonumber(info.required) or 0 else 0
		local gain = if info ~= nil then tonumber(info.gain) or 0 else 0

		essenceValue.Text = if type(state.essenceText) == "string" then state.essenceText else "1x"
		requiredValue.Text = tostring(required)
		bestValue.Text = tostring(tonumber(state.floor) or 0)
		gainValue.Text = "+" .. tostring(gain)

		if button == nil then
			return
		end
		if pendingLife ~= nil then
			button.Text = "ASCENDING..."
			button.TextColor3 = Theme.color.textDim
			button.Active = false
			return
		end
		if info == nil or info.can ~= true then
			button.Text = string.format("REACH FLOOR %d", required)
			button.TextColor3 = Theme.color.textDim
			button.Active = false
			return
		end
		if armed then
			button.Text = "CONFIRM?"
			button.TextColor3 = Theme.color.gold
		else
			button.Text = "ASCEND"
			button.TextColor3 = Theme.color.text
		end
		button.Active = true
	end

	button = UI.button(window, "ASCEND", {
		name = "Ascend",
		size = UDim2.fromOffset(240, 56),
		pos = UDim2.new(0.5, 0, 0, 296),
		anchor = Vector2.new(0.5, 0),
		color = Theme.color.danger,
		textColor = Theme.color.text,
		textSize = Theme.text.lg,
		onClick = function()
			local state = currentState(scope, lastState)
			if type(state) ~= "table" then
				return
			end
			local info = if type(state.ascend) == "table" then state.ascend else nil
			if info == nil or info.can ~= true then
				return
			end
			if not armed then
				armed = true
				task.delay(3, function()
					armed = false
					refresh(currentState(scope, lastState))
				end)
				refresh(state)
				return
			end
			armed = false
			pendingLife = tonumber(state.life) or 0
			scope.send("Ascend", {})
			refresh(state)
		end,
	})

	refresh(currentState(scope, lastState))

	return {
		update = refresh,
	}
end

return Panel
