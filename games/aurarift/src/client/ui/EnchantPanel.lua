--!strict
--[[
	EnchantPanel — the dojo: one row per repeatable upgrade.

	Rows come from `Content.upgrades` in definition order, so a balance pass
	reorders the shelf by editing the content file, not this one. The icon
	comes from the same entry, and the cost text is the server's -- this
	panel never formats a number it does not own and never decides whether a
	purchase is affordable. It sends `Upgrade { id }` and waits.

	Built once; `update(state)` restyles labels. A row that rebuilt itself on
	every push would drop the player's hover mid-second.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local UI = Forge.UI
local Icons = UI.ItchIcons

local Theme = require(script.Parent.Theme)

local Panel = {}
Panel.id = "enchant"
Panel.icon = "action.upgrade"
Panel.label = "DOJO"

local ROW_HEIGHT = 72

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

	local root = Instance.new("Frame")
	root.Name = "EnchantRoot"
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

	UI.label(window, "DOJO — UPGRADES", {
		name = "Title",
		font = Theme.font.title,
		size = Theme.text.lg,
		frameSize = UDim2.new(1, -260, 0, 34),
		pos = UDim2.fromOffset(14, 10),
		z = 3,
	})

	local riftText = UI.label(window, "RIFT 0", {
		name = "Rift",
		font = Theme.font.bold,
		size = Theme.text.md,
		color = Theme.color.gold,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.fromOffset(180, 22),
		pos = UDim2.new(1, -60, 0, 16),
		anchor = Vector2.new(1, 0),
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

	-- ---------------------------------------------------------------- rows
	local scroll = Instance.new("ScrollFrame")
	scroll.Name = "Scroll"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = Theme.color.stroke
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.Position = UDim2.fromOffset(14, 52)
	scroll.Size = UDim2.new(1, -28, 1, -64)
	scroll.Parent = window

	local rowsFrame = Instance.new("Frame")
	rowsFrame.Name = "Rows"
	rowsFrame.BackgroundTransparency = 1
	rowsFrame.BorderSizePixel = 0
	rowsFrame.Size = UDim2.new(1, -10, 0, 0)
	rowsFrame.AutomaticSize = Enum.AutomaticSize.Y
	rowsFrame.Parent = scroll
	UI.list(rowsFrame, { gap = 8 })

	local rows: { any } = {}
	for index, upgrade in ipairs(Content.upgrades) do
		local row = UI.panel(rowsFrame, {
			name = upgrade.id,
			size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			color = Theme.color.panelAlt,
			stroke = false,
		})
		row.LayoutOrder = index

		icon(row, upgrade.icon, 26, UDim2.fromOffset(12, 12), Theme.color.gold)

		UI.label(row, upgrade.name, {
			name = "Name",
			font = Theme.font.bold,
			size = Theme.text.md,
			frameSize = UDim2.new(1, -250, 0, 20),
			pos = UDim2.fromOffset(46, 10),
		})

		UI.label(row, upgrade.desc, {
			name = "Desc",
			size = Theme.text.sm,
			color = Theme.color.textDim,
			wrap = true,
			frameSize = UDim2.new(1, -250, 0, 34),
			pos = UDim2.fromOffset(46, 31),
		})

		local level = UI.label(row, "LV 0/" .. tostring(upgrade.maxLevel), {
			name = "Level",
			font = Theme.font.bold,
			size = Theme.text.sm,
			align = Enum.TextXAlignment.Right,
			frameSize = UDim2.fromOffset(140, 18),
			pos = UDim2.new(1, -96, 0, 12),
			anchor = Vector2.new(1, 0),
		})

		local cost = UI.label(row, "", {
			name = "Cost",
			font = Theme.font.bold,
			size = Theme.text.sm,
			color = Theme.color.good,
			align = Enum.TextXAlignment.Right,
			frameSize = UDim2.fromOffset(140, 18),
			pos = UDim2.new(1, -96, 0, 33),
			anchor = Vector2.new(1, 0),
		})

		local buy = UI.button(row, "BUY", {
			name = "Buy",
			size = UDim2.fromOffset(76, 44),
			pos = UDim2.new(1, -10, 0.5, 0),
			anchor = Vector2.new(1, 0.5),
			color = Theme.color.panel,
			textSize = Theme.text.md,
			onClick = function()
				local state = currentState(scope, lastState)
				if type(state) ~= "table" then
					return
				end
				local info = if type(state.upgradeCosts) == "table" then state.upgradeCosts[upgrade.id] else nil
				if type(info) == "table" and info.maxed == true then
					return
				end
				scope.send("Upgrade", { id = upgrade.id })
			end,
		})

		rows[index] = { spec = upgrade, level = level, cost = cost, buy = buy }
	end

	-- ---------------------------------------------------------------- draw
	local function update(state: any)
		if type(state) ~= "table" then
			return
		end
		lastState = state
		riftText.Text = "RIFT " .. (if type(state.rift) == "string" then state.rift else "0")

		local costs = if type(state.upgradeCosts) == "table" then state.upgradeCosts else {}
		local levels = if type(state.upgrades) == "table" then state.upgrades else {}

		for _, row in rows do
			local spec = row.spec
			local info = costs[spec.id]
			local level = tonumber(if type(info) == "table" then info.level else nil)
				or tonumber(levels[spec.id]) or 0
			local maxed = (type(info) == "table" and info.maxed == true)
				or level >= spec.maxLevel
			if maxed then
				row.level.Text = "MAX"
				row.level.TextColor3 = Theme.color.gold
				row.cost.Text = ""
				row.buy.Text = "MAX"
				row.buy.TextColor3 = Theme.color.gold
				row.buy.Active = false
			else
				row.level.Text = string.format("LV %d/%d", level, spec.maxLevel)
				row.level.TextColor3 = Theme.color.text
				row.cost.Text = if type(info) == "table" then tostring(info.costText or "") else ""
				row.buy.Text = "BUY"
				row.buy.TextColor3 = Theme.color.text
				row.buy.Active = true
			end
		end
	end

	update(currentState(scope, lastState))

	return {
		update = update,
	}
end

return Panel
