--!strict
--[[
	TowerPanel — the Infinite Tower: one floor, one clock, one button.

	Two layouts in one frame. Idle plans the next fight; live draws the one
	in progress from `Battle` events at 4 Hz. The 2.5-second result window
	the server keeps is this panel's win moment: a gold banner, then back to
	the ladder.

	`event` stores the payload and re-renders; `update` folds in the battle
	StateSync carries but never overwrites a fight the panel has already
	seen from an event. Two sources, one last write wins, chosen on purpose
	-- a renderer that flips between them is a bar that stutters.

	Everything shown is server-owned: floor, progress, time and reward all
	travel pre-computed. This panel asks for a fight and draws it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local UI = Forge.UI
local Icons = UI.ItchIcons

local Theme = require(script.Parent.Theme)

local Panel = {}
Panel.id = "tower"
Panel.icon = "combat.sword"
Panel.label = "TOWER"

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

--: `active` is the server's authority on whether a fight exists; `phase`
--: is the fallback for the shape StateSync carries, which has no `active`.
local function isLive(battle: any): boolean
	return type(battle) == "table"
		and (battle.active == true or battle.phase == "fight")
end

function Panel.mount(parent: Instance, scope: any)
	local lastState: any = nil
	local lastBattle: any = nil
	local resultToken = 0

	local root = Instance.new("Frame")
	root.Name = "TowerRoot"
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

	UI.label(window, "INFINITE TOWER", {
		name = "Title",
		font = Theme.font.title,
		size = Theme.text.lg,
		frameSize = UDim2.new(1, -260, 0, 34),
		pos = UDim2.fromOffset(14, 10),
		z = 3,
	})

	local bestText = UI.label(window, "BEST: FLOOR 0", {
		name = "Best",
		font = Theme.font.bold,
		size = Theme.text.md,
		color = Theme.color.gold,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.fromOffset(200, 22),
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

	-- ---------------------------------------------------------------- idle
	local idle = Instance.new("Frame")
	idle.Name = "Idle"
	idle.BackgroundTransparency = 1
	idle.BorderSizePixel = 0
	idle.Position = UDim2.fromOffset(0, 50)
	idle.Size = UDim2.new(1, 0, 1, -50)
	idle.Parent = window

	local nextText = UI.label(idle, "NEXT FLOOR 1", {
		name = "Next",
		font = Theme.font.title,
		size = Theme.text.xl,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -40, 0, 40),
		pos = UDim2.fromOffset(20, 34),
	})

	local idleBoss = UI.label(idle, "BOSS FLOOR", {
		name = "BossTag",
		font = Theme.font.bold,
		size = Theme.text.md,
		color = Theme.color.violet,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -40, 0, 22),
		pos = UDim2.fromOffset(20, 78),
	})
	idleBoss.Visible = false

	local powerText = UI.label(idle, "POWER 0", {
		name = "Power",
		size = Theme.text.md,
		color = Theme.color.textDim,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -40, 0, 22),
		pos = UDim2.fromOffset(20, 128),
	})

	UI.button(idle, "FIGHT", {
		name = "Fight",
		size = UDim2.fromOffset(220, 56),
		pos = UDim2.new(0.5, 0, 0, 186),
		anchor = Vector2.new(0.5, 0),
		color = Theme.color.gold,
		textColor = Theme.color.bg,
		textSize = Theme.text.lg,
		onClick = function()
			scope.send("BattleStart", {})
		end,
	})

	local replay = UI.button(idle, "REPLAY", {
		name = "Replay",
		size = UDim2.fromOffset(160, 44),
		pos = UDim2.new(0.5, 0, 0, 258),
		anchor = Vector2.new(0.5, 0),
		color = Theme.color.panelAlt,
		textSize = Theme.text.md,
		onClick = function()
			local state = currentState(scope, lastState)
			local best = 0
			if type(state) == "table" then
				best = tonumber(state.floor) or 0
			end
			if best >= 1 then
				scope.send("BattleStart", { floor = best })
			end
		end,
	})
	replay.Visible = false

	-- ---------------------------------------------------------------- live
	local live = Instance.new("Frame")
	live.Name = "Live"
	live.BackgroundTransparency = 1
	live.BorderSizePixel = 0
	live.Position = UDim2.fromOffset(0, 50)
	live.Size = UDim2.new(1, 0, 1, -50)
	live.Visible = false
	live.Parent = window

	local liveFloor = UI.label(live, "FLOOR 1", {
		name = "Floor",
		font = Theme.font.title,
		size = Theme.text.xl,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -40, 0, 40),
		pos = UDim2.fromOffset(20, 30),
	})

	local liveBoss = UI.label(live, "BOSS FLOOR", {
		name = "BossTag",
		font = Theme.font.bold,
		size = Theme.text.md,
		color = Theme.color.violet,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -40, 0, 22),
		pos = UDim2.fromOffset(20, 74),
	})
	liveBoss.Visible = false

	local progressText = UI.label(live, "TOWER PROGRESS  0%", {
		name = "Progress",
		font = Theme.font.bold,
		size = Theme.text.md,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -40, 0, 22),
		pos = UDim2.fromOffset(20, 126),
	})

	local bar = UI.bar(live, {
		name = "ProgressBar",
		size = UDim2.new(1, -150, 0, 18),
		pos = UDim2.new(0.5, 0, 0, 154),
		anchor = Vector2.new(0.5, 0),
		color = Theme.color.accent,
	})

	local timeText = UI.label(live, "0s LEFT", {
		name = "Time",
		size = Theme.text.md,
		color = Theme.color.textDim,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -40, 0, 22),
		pos = UDim2.fromOffset(20, 182),
	})

	local stop = UI.button(live, "STOP", {
		name = "Stop",
		size = UDim2.fromOffset(130, 44),
		pos = UDim2.new(0.5, 0, 0, 240),
		anchor = Vector2.new(0.5, 0),
		color = Theme.color.panelAlt,
		textColor = Theme.color.danger,
		textSize = Theme.text.md,
		onClick = function()
			scope.send("BattleStop", {})
		end,
	})

	local banner = UI.panel(live, {
		name = "Result",
		size = UDim2.fromOffset(420, 120),
		pos = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		color = Theme.color.panel,
		strokeColor = Theme.color.gold,
		visible = false,
	})
	banner.ZIndex = 5
	local bannerStroke = banner:FindFirstChildOfClass("UIStroke")

	local resultTitle = UI.label(banner, "VICTORY", {
		name = "ResultTitle",
		font = Theme.font.title,
		size = Theme.text.lg,
		color = Theme.color.gold,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -20, 0, 40),
		pos = UDim2.fromOffset(10, 22),
	})

	local resultSub = UI.label(banner, "", {
		name = "ResultSub",
		font = Theme.font.bold,
		size = Theme.text.md,
		color = Theme.color.gold,
		align = Enum.TextXAlignment.Center,
		frameSize = UDim2.new(1, -20, 0, 24),
		pos = UDim2.fromOffset(10, 68),
	})

	-- ---------------------------------------------------------------- draw
	local function render()
		local best = 0
		if type(lastState) == "table" then
			best = tonumber(lastState.floor) or 0
		end
		bestText.Text = string.format("BEST: FLOOR %d", best)

		local battle = lastBattle
		local liveNow = isLive(battle)
		idle.Visible = not liveNow
		live.Visible = liveNow

		if liveNow then
			local floor = tonumber(battle.floor) or 0
			liveFloor.Text = string.format("FLOOR %d", floor)
			liveBoss.Visible = battle.boss == true
			local progress = math.clamp(tonumber(battle.progress) or 0, 0, 1)
			progressText.Text = string.format("TOWER PROGRESS  %d%%", math.floor(progress * 100 + 0.5))
			bar:set(progress)
			timeText.Text = string.format("%ds LEFT", math.max(0, math.ceil(tonumber(battle.timeLeft) or 0)))
			stop.Visible = battle.phase == "fight"
		else
			local nextFloor = best + 1
			nextText.Text = string.format("NEXT FLOOR %d", nextFloor)
			idleBoss.Visible = Content.isBoss(nextFloor)
			local power = if type(lastState) == "table" and type(lastState.powerText) == "string"
				then lastState.powerText else "0"
			powerText.Text = "POWER " .. power
			replay.Visible = best >= 1
		end
	end

	local function showResult(payload: any)
		resultToken += 1
		local token = resultToken
		if payload.phase == "won" then
			local reward = if type(payload.reward) == "string" and payload.reward ~= ""
				then "  +" .. payload.reward else ""
			resultTitle.Text = "VICTORY" .. reward
			resultTitle.TextColor3 = Theme.color.gold
			resultSub.Text = if payload.firstClear == true then "FIRST CLEAR!" else ""
			if bannerStroke ~= nil then
				bannerStroke.Color = Theme.color.gold
			end
		else
			resultTitle.Text = "DEFEAT — RAISE YOUR POWER"
			resultTitle.TextColor3 = Theme.color.danger
			resultSub.Text = ""
			if bannerStroke ~= nil then
				bannerStroke.Color = Theme.color.danger
			end
		end
		banner.Visible = true
		task.delay(2.5, function()
			if token ~= resultToken then
				return
			end
			banner.Visible = false
			render()
		end)
	end

	local function update(state: any)
		if type(state) ~= "table" then
			return
		end
		lastState = state
		local battle = state.battle
		if type(battle) == "table" then
			--: A live event payload is fresher than the slow push; never
			--: let a 3-second sync step a 4 Hz bar backwards.
			if lastBattle == nil or lastBattle.active ~= true then
				lastBattle = battle
			end
		elseif lastBattle == nil or lastBattle.active ~= true then
			lastBattle = nil
		end
		render()
	end

	local function event(kind: string, payload: any)
		if kind ~= "battle" or type(payload) ~= "table" then
			return
		end
		lastBattle = payload
		if payload.phase == "won" or payload.phase == "lost" then
			showResult(payload)
		end
		render()
	end

	update(currentState(scope, lastState))

	return {
		update = update,
		event = event,
	}
end

return Panel
