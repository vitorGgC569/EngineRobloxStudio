--!strict
--[[
	IndexPanel — the collection, the slots, and the equip loop.

	One cell per aura in `Content.cards`, in definition order, so the grid a
	player learns is the grid the content is authored in. Undiscovered cells
	still exist: they are the shape of what is missing, which is the reason
	to summon again.

	Reads through `scope.getState()` on the click path and `update(state)`
	on the draw path; nothing keeps a second opinion of the profile. A click
	sends intent only -- a card id and a slot number. The server decides
	whether the card was owned.

	Built once, restyled in place: 41 cells rebuilt on every StateSync are
	41 flickers every three seconds.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))
local Format = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Format"))

local UI = Forge.UI
local Icons = UI.ItchIcons

local Theme = require(script.Parent.Theme)

local Panel = {}
Panel.id = "index"
Panel.icon = "nav.inventory"
Panel.label = "INDEX"

local CARD_SIZE = UDim2.fromOffset(98, 122)
local CARD_COLUMNS = 5

--: A drawn icon, or nothing. A token that does not resolve removes the
--: picture and leaves the readout, which is the acceptable failure -- a
--: blank square is not.
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

--: The rail's copy of state, or the last push this panel saw, or nothing.
local function currentState(scope: any, fallback: any): any
	if scope ~= nil and scope.getState ~= nil then
		local state = scope.getState()
		if type(state) == "table" then
			return state
		end
	end
	return fallback
end

local function ownedCount(state: any, cardId: string): number
	local collection = state.collection
	if type(collection) ~= "table" then
		return 0
	end
	for _, entry in collection do
		if type(entry) == "table" and entry.id == cardId then
			return tonumber(entry.count) or 0
		end
	end
	return 0
end

--: New auras fill the first open unlocked slot; with every unlocked slot
--: taken, the click replaces slot 1, which is what the player expects a
--: full board to do.
local function firstOpenSlot(state: any): number
	local slots = tonumber(state.slots) or 1
	local equipped = state.equipped
	for slot = 1, slots do
		local cardId = if type(equipped) == "table" then equipped[slot] else nil
		if cardId == nil or cardId == "" then
			return slot
		end
	end
	return 1
end

function Panel.mount(parent: Instance, scope: any)
	local lastState: any = nil

	local root = Instance.new("Frame")
	root.Name = "IndexRoot"
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

	local title = UI.label(window, string.format("AURA INDEX  0/%d", Content.cardCount()), {
		name = "Title",
		font = Theme.font.title,
		size = Theme.text.lg,
		frameSize = UDim2.new(1, -70, 0, 34),
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

	-- ---------------------------------------------------------------- slots
	local chipRow = Instance.new("Frame")
	chipRow.Name = "Slots"
	chipRow.BackgroundTransparency = 1
	chipRow.BorderSizePixel = 0
	chipRow.Position = UDim2.fromOffset(14, 52)
	chipRow.Size = UDim2.new(1, -28, 0, 48)
	chipRow.Parent = window
	UI.list(chipRow, { horizontal = true, gap = 8 })

	local chips: { any } = {}
	for slot = 1, 3 do
		local chip = UI.button(chipRow, "", {
			name = "Slot" .. slot,
			size = UDim2.new(1 / 3, -6, 0, 48),
			color = Theme.color.panelAlt,
			textSize = Theme.text.md,
			onClick = function()
				local state = currentState(scope, lastState)
				if type(state) ~= "table" then
					return
				end
				if slot > (tonumber(state.slots) or 1) then
					return
				end
				local equipped = state.equipped
				local cardId = if type(equipped) == "table" then equipped[slot] else nil
				if type(cardId) == "string" and cardId ~= "" then
					scope.send("Unequip", { slot = slot })
				end
			end,
		})
		chip.LayoutOrder = slot

		local cover = Instance.new("Frame")
		cover.Name = "Cover"
		cover.Size = UDim2.fromScale(1, 1)
		cover.BackgroundColor3 = Theme.color.bg
		cover.BackgroundTransparency = 0.25
		cover.BorderSizePixel = 0
		cover.Visible = false
		cover.ZIndex = 1
		cover.Parent = chip
		UI.corner(cover, Theme.radius.sm)

		local lock = icon(chip, "status.lock", 14, UDim2.new(1, -26, 0, 7), Theme.color.textDim)
		if lock ~= nil then
			lock.Visible = false
		end

		local label = UI.label(chip, "", {
			name = "Name",
			size = Theme.text.md,
			wrap = true,
			valign = Enum.TextYAlignment.Center,
			frameSize = UDim2.new(1, -46, 0, 40),
			pos = UDim2.fromOffset(8, 4),
		})

		chips[slot] = { chip = chip, cover = cover, lock = lock, label = label }
	end

	-- ---------------------------------------------------------------- grid
	local scroll = Instance.new("ScrollFrame")
	scroll.Name = "Scroll"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = Theme.color.stroke
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.Position = UDim2.fromOffset(14, 108)
	scroll.Size = UDim2.new(1, -28, 1, -120)
	scroll.Parent = window

	local grid = Instance.new("Frame")
	grid.Name = "Cards"
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.Size = UDim2.new(1, -10, 0, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.Parent = scroll

	local layout = Instance.new("UIGridLayout")
	layout.CellSize = CARD_SIZE
	layout.CellPadding = UDim2.fromOffset(6, 6)
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.FillDirectionMaxCells = CARD_COLUMNS
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid

	local cards: { any } = {}
	for index, card in ipairs(Content.cards) do
		local tint = Theme.rarityColor(card.rarity)
		local button = UI.button(grid, "", {
			name = card.id,
			size = CARD_SIZE,
			color = Theme.color.panelAlt,
			strokeColor = tint,
			onClick = function()
				local state = currentState(scope, lastState)
				if type(state) ~= "table" then
					return
				end
				if ownedCount(state, card.id) <= 0 then
					return
				end
				scope.send("Equip", { card = card.id, slot = firstOpenSlot(state) })
			end,
		})
		button.LayoutOrder = index

		local cover = Instance.new("Frame")
		cover.Name = "Cover"
		cover.Size = UDim2.fromScale(1, 1)
		cover.BackgroundColor3 = Theme.color.bg
		cover.BorderSizePixel = 0
		cover.Visible = true
		cover.ZIndex = 1
		cover.Parent = button
		UI.corner(cover, Theme.radius.sm)

		local nameLabel = UI.label(button, "???", {
			name = "Name",
			font = Theme.font.bold,
			size = Theme.text.md,
			color = Theme.color.textDim,
			align = Enum.TextXAlignment.Center,
			wrap = true,
			frameSize = UDim2.new(1, -10, 0, 40),
			pos = UDim2.fromOffset(5, 10),
		})

		local badge = UI.label(button, "", {
			name = "Badge",
			font = Theme.font.bold,
			size = Theme.text.sm,
			color = Theme.color.gold,
			frameSize = UDim2.fromOffset(34, 18),
			pos = UDim2.fromOffset(6, 4),
			z = 3,
		})
		badge.Visible = false

		local countLabel = UI.label(button, "", {
			name = "Count",
			size = Theme.text.md,
			color = Theme.color.textDim,
			frameSize = UDim2.fromOffset(44, 20),
			pos = UDim2.fromOffset(8, 96),
		})

		local powerLabel = UI.label(button, "", {
			name = "Power",
			font = Theme.font.bold,
			size = Theme.text.md,
			align = Enum.TextXAlignment.Right,
			frameSize = UDim2.fromOffset(60, 20),
			pos = UDim2.new(1, -8, 0, 96),
			anchor = Vector2.new(1, 0),
		})

		cards[index] = {
			button = button,
			cover = cover,
			name = nameLabel,
			badge = badge,
			count = countLabel,
			power = powerLabel,
			edge = button:FindFirstChildOfClass("UIStroke"),
			spec = card,
		}
	end

	-- ---------------------------------------------------------------- draw
	local function renderChips(state: any)
		local slots = tonumber(state.slots) or 1
		local equipped = if type(state.equipped) == "table" then state.equipped else {}
		for slot = 1, 3 do
			local view = chips[slot]
			local cardId = equipped[slot]
			if slot > slots then
				view.label.Text = string.format("SLOT %d · LOCKED", slot)
				view.label.TextColor3 = Theme.color.textDim
				view.cover.Visible = true
				if view.lock ~= nil then
					view.lock.Visible = true
				end
			elseif type(cardId) == "string" and cardId ~= "" then
				local card = Content.card(cardId)
				view.label.Text = string.format("SLOT %d · %s", slot, if card then card.name else cardId)
				view.label.TextColor3 = Theme.color.text
				view.cover.Visible = false
				if view.lock ~= nil then
					view.lock.Visible = false
				end
			else
				view.label.Text = string.format("SLOT %d · EMPTY", slot)
				view.label.TextColor3 = Theme.color.textDim
				view.cover.Visible = false
				if view.lock ~= nil then
					view.lock.Visible = false
				end
			end
		end
	end

	local function renderCards(state: any)
		local equippedAt: { [string]: number } = {}
		local equipped = state.equipped
		if type(equipped) == "table" then
			for slot = 1, 3 do
				local cardId = equipped[slot]
				if type(cardId) == "string" and cardId ~= "" then
					equippedAt[cardId] = slot
				end
			end
		end

		for _, view in cards do
			local card = view.spec
			local count = ownedCount(state, card.id)
			local tint = Theme.rarityColor(card.rarity)
			if view.edge ~= nil then
				view.edge.Color = tint
			end
			if count > 0 then
				view.name.Text = card.name
				view.name.TextColor3 = tint
				view.count.Text = string.format("x%d", count)
				view.power.Text = Format.abbrev(Content.cardPower(card.id, math.max(0, count - 1)))
				view.power.TextColor3 = tint
				view.cover.Visible = false
				local placed = equippedAt[card.id]
				view.badge.Visible = placed ~= nil
				view.badge.Text = if placed then string.format("E%d", placed) else ""
				if view.edge ~= nil then
					view.edge.Transparency = 0.15
				end
			else
				view.name.Text = "???"
				view.name.TextColor3 = Theme.color.textDim
				view.count.Text = ""
				view.power.Text = ""
				view.badge.Visible = false
				view.cover.Visible = true
				if view.edge ~= nil then
					view.edge.Transparency = 0.65
				end
			end
		end
	end

	local function update(state: any)
		if type(state) ~= "table" then
			return
		end
		lastState = state
		local unique = tonumber(state.unique) or 0
		local total = tonumber(state.total) or Content.cardCount()
		title.Text = string.format("AURA INDEX  %d/%d", unique, total)
		renderChips(state)
		renderCards(state)
	end

	update(currentState(scope, lastState))

	return {
		update = update,
	}
end

return Panel
