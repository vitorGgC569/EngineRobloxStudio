--!strict
--[[
	RanksPanel — the leaderboards, one board at a time.

	Four tabs, ten rows, and a server that answers one `BoardRefresh` at a
	time. That is the whole reason this panel has a throttle: taps arrive
	faster than round trips, and without the 0.4-second gate a player
	drumming through tabs would queue four stale boards and then watch them
	land out of order. `request` collapses that into the latest ask, and
	`event` adopts whatever the server confirms.

	Rows are pooled rather than rebuilt. A board push replaces ten strings
	at most; rebuilding forty frames per tap is how a leaderboard becomes
	the thing that makes a UI feel cheap.

	The LIVE badge is a staleness readout, not a decoration -- it means the
	server confirmed this board within the last minute.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local UI = Forge.UI
local Icons = UI.ItchIcons

local Theme = require(script.Parent.Theme)

local Panel = {}
Panel.id = "ranks"
Panel.icon = "status.medal"
Panel.label = "RANKS"

local BOARDS = {
	{ id = "power", label = "POWER" },
	{ id = "floor", label = "TOWER" },
	{ id = "collection", label = "AURAS" },
	{ id = "divines", label = "DIVINES" },
}

local ROW_COUNT = 10

local function trim(name: string): string
	if #name > 18 then
		return string.sub(name, 1, 18) .. "..."
	end
	return name
end

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
	local activeBoard = "power"
	local lastRequest = 0
	local lastSelect = 0
	local pendingBoard: any = nil
	local updatedAt = 0
	local tabs: { [string]: any } = {}
	local rowPool: { any } = {}

	local root = Instance.new("Frame")
	root.Name = "RanksRoot"
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

	UI.label(window, "RANKS", {
		name = "Title",
		font = Theme.font.title,
		size = Theme.text.lg,
		frameSize = UDim2.new(1, -260, 0, 34),
		pos = UDim2.fromOffset(14, 10),
		z = 3,
	})

	local liveLabel = UI.label(window, "LIVE", {
		name = "Live",
		font = Theme.font.bold,
		size = Theme.text.md,
		color = Theme.color.good,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.fromOffset(80, 22),
		pos = UDim2.new(1, -158, 0, 20),
		anchor = Vector2.new(1, 0),
		z = 3,
	})
	liveLabel.Visible = false

	-- ------------------------------------------------------------- throttle
	local function updateLive()
		liveLabel.Visible = updatedAt > 0 and (os.time() - updatedAt) <= 60
	end

	local function dispatch(board: string)
		lastRequest = os.clock()
		scope.send("BoardRefresh", { board = board })
	end

	local function request(board: string)
		local elapsed = os.clock() - lastRequest
		if elapsed >= 0.4 then
			pendingBoard = nil
			dispatch(board)
			return
		end
		pendingBoard = board
		local wait = 0.45 - elapsed
		task.delay(wait, function()
			if pendingBoard ~= board then
				return
			end
			pendingBoard = nil
			dispatch(board)
		end)
	end

	local function styleTabs()
		for _, board in BOARDS do
			local entry = tabs[board.id]
			if entry ~= nil then
				local active = board.id == activeBoard
				entry.button.TextColor3 = if active then Theme.color.text else Theme.color.textDim
				entry.mark.Visible = active
			end
		end
	end

	local function selectBoard(id: string)
		local now = os.clock()
		if id == activeBoard and now - lastSelect < 0.5 then
			return
		end
		lastSelect = now
		activeBoard = id
		styleTabs()
		request(id)
	end

	-- -------------------------------------------------------------- header
	local refreshBtn = UI.button(window, "", {
		name = "Refresh",
		size = UDim2.fromOffset(90, 44),
		pos = UDim2.new(1, -60, 0, 6),
		anchor = Vector2.new(1, 0),
		color = Theme.color.panelAlt,
		textSize = Theme.text.md,
		onClick = function()
			request(activeBoard)
		end,
	})
	refreshBtn.ZIndex = 3
	if icon(refreshBtn, "action.refresh", 22, UDim2.new(0.5, -11, 0.5, -11), Theme.color.text) == nil then
		refreshBtn.Text = "REFRESH"
	end

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

	-- ---------------------------------------------------------------- tabs
	local tabRow = Instance.new("Frame")
	tabRow.Name = "Tabs"
	tabRow.BackgroundTransparency = 1
	tabRow.BorderSizePixel = 0
	tabRow.Position = UDim2.fromOffset(14, 58)
	tabRow.Size = UDim2.new(1, -28, 0, 44)
	tabRow.Parent = window
	UI.list(tabRow, { horizontal = true, gap = 8 })

	for index, board in BOARDS do
		local id = board.id
		local tabBtn = UI.button(tabRow, board.label, {
			name = id,
			size = UDim2.new(0.25, -6, 0, 44),
			color = Theme.color.panelAlt,
			textColor = Theme.color.textDim,
			textSize = Theme.text.md,
			onClick = function()
				selectBoard(id)
			end,
		})
		tabBtn.LayoutOrder = index

		local mark = Instance.new("Frame")
		mark.Name = "Mark"
		mark.BackgroundColor3 = Theme.color.accent
		mark.BorderSizePixel = 0
		mark.Size = UDim2.new(1, -18, 0, 3)
		mark.Position = UDim2.new(0.5, 0, 1, -5)
		mark.AnchorPoint = Vector2.new(0.5, 0)
		mark.ZIndex = 3
		mark.Visible = false
		mark.Parent = tabBtn

		tabs[id] = { button = tabBtn, mark = mark }
	end
	styleTabs()

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
	scroll.Position = UDim2.fromOffset(14, 110)
	scroll.Size = UDim2.new(1, -28, 1, -122)
	scroll.Parent = window

	local rowsFrame = Instance.new("Frame")
	rowsFrame.Name = "Rows"
	rowsFrame.BackgroundTransparency = 1
	rowsFrame.BorderSizePixel = 0
	rowsFrame.Size = UDim2.new(1, -10, 0, 0)
	rowsFrame.AutomaticSize = Enum.AutomaticSize.Y
	rowsFrame.Parent = scroll
	UI.list(rowsFrame, { gap = 6 })

	for index = 1, ROW_COUNT do
		local row = UI.panel(rowsFrame, {
			name = "Row" .. tostring(index),
			size = UDim2.new(1, 0, 0, 44),
			color = Theme.color.panelAlt,
			stroke = false,
			radius = Theme.radius.sm,
			visible = false,
		})
		row.LayoutOrder = index

		local rank = UI.label(row, "#" .. tostring(index), {
			name = "Rank",
			font = Theme.font.bold,
			size = Theme.text.md,
			color = Theme.color.gold,
			frameSize = UDim2.fromOffset(44, 20),
			pos = UDim2.new(0, 12, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
		})

		local nameLabel = UI.label(row, "", {
			name = "Name",
			size = Theme.text.md,
			frameSize = UDim2.new(1, -180, 0, 20),
			pos = UDim2.new(0, 56, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
		})

		local value = UI.label(row, "", {
			name = "Value",
			font = Theme.font.bold,
			size = Theme.text.md,
			color = Theme.color.good,
			align = Enum.TextXAlignment.Right,
			frameSize = UDim2.fromOffset(120, 20),
			pos = UDim2.new(1, -12, 0.5, 0),
			anchor = Vector2.new(1, 0.5),
		})

		rowPool[index] = { row = row, rank = rank, name = nameLabel, value = value }
	end

	local emptyLabel = UI.label(window, "NO ENTRIES YET", {
		name = "Empty",
		size = Theme.text.sm,
		color = Theme.color.textDim,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -28, 0, 30),
		pos = UDim2.new(0.5, 0, 0, 200),
		anchor = Vector2.new(0.5, 0),
	})

	-- ---------------------------------------------------------------- draw
	local function renderEntries(payload: any)
		local entries = if type(payload.entries) == "table" then payload.entries else {}
		local shown = 0
		for i = 1, #rowPool do
			local slot = rowPool[i]
			local entry = entries[i]
			if type(entry) == "table" then
				shown += 1
				slot.row.Visible = true
				slot.rank.Text = "#" .. tostring(entry.rank or i)
				slot.name.Text = trim(tostring(entry.name or "?"))
				slot.value.Text = tostring(entry.value or "")
			else
				slot.row.Visible = false
			end
		end
		emptyLabel.Visible = shown == 0
	end

	local function update(state: any)
		if type(state) ~= "table" then
			return
		end
		lastState = state
		updateLive()
	end

	local function event(kind: string, payload: any)
		if kind ~= "board" or type(payload) ~= "table" then
			return
		end
		local board = payload.board
		if type(board) ~= "string" or tabs[board] == nil then
			return
		end
		activeBoard = board
		updatedAt = os.time()
		styleTabs()
		renderEntries(payload)
		updateLive()
	end

	request(activeBoard)
	update(currentState(scope, lastState))

	return {
		update = update,
		event = event,
	}
end

return Panel
