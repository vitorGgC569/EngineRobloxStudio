--!strict
-- In-round HUD: state banner + countdown timer, horde counter, kill feed,
-- conversion alerts, coin balance.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LevelMath = require(Shared.LevelMath)

local Theme = require(script.Parent.Theme)

local HUD = {}

function HUD.start(remotes: any)
	local gui = Theme.screenGui("HUD", 2)

	-- Top bar: state + timer
	local topBar = Theme.frame(gui, {
		Size = UDim2.new(0, 320, 0, 56),
		Position = UDim2.new(0.5, -160, 0, 12),
		BackgroundTransparency = 0.25,
	})
	Theme.corner(topBar, 12)
	Theme.stroke(topBar, Color3.fromRGB(60, 64, 78), 1, 0.4)
	local stateLabel = Theme.label(topBar, {
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.new(0, 0, 0, 4),
		Text = "WAITING FOR PLAYERS",
		TextSize = 14,
		TextColor3 = Theme.Colors.TextDim,
	})
	local timerLabel = Theme.label(topBar, {
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.new(0, 0, 0, 24),
		Text = "--:--",
		TextSize = 26,
		Font = Theme.FontDisplay,
	})

	-- Horde counter (left)
	local horde = Theme.frame(gui, {
		Size = UDim2.new(0, 190, 0, 44),
		Position = UDim2.new(0, 12, 0, 12),
		BackgroundTransparency = 0.25,
	})
	Theme.corner(horde, 10)
	local hordeLabel = Theme.label(horde, {
		Size = UDim2.new(1, -12, 1, 0),
		Position = UDim2.new(0, 12, 0, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		TextSize = 15,
	})

	-- Coins (right)
	local coins = Theme.frame(gui, {
		Size = UDim2.new(0, 140, 0, 44),
		Position = UDim2.new(1, -152, 0, 12),
		BackgroundTransparency = 0.25,
	})
	Theme.corner(coins, 10)
	local coinsLabel = Theme.label(coins, {
		Size = UDim2.new(1, -12, 1, 0),
		Position = UDim2.new(0, 12, 0, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "0 coins",
		TextSize = 15,
		TextColor3 = Theme.Colors.Gold,
	})

	-- Level pill + XP bar (under the coins panel, right side)
	local levelPill = Theme.frame(gui, {
		Size = UDim2.new(0, 140, 0, 34),
		Position = UDim2.new(1, -152, 0, 60),
		BackgroundTransparency = 0.25,
	})
	Theme.corner(levelPill, 10)
	local levelLabel = Theme.label(levelPill, {
		Size = UDim2.new(1, -12, 0, 18),
		Position = UDim2.new(0, 12, 0, 3),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "LVL 1",
		TextSize = 14,
		TextColor3 = Theme.Colors.Survivor,
	})
	local xpBar = Theme.frame(levelPill, {
		Size = UDim2.new(1, -24, 0, 6),
		Position = UDim2.new(0, 12, 1, -10),
		BackgroundColor3 = Theme.Colors.Bg,
	})
	Theme.corner(xpBar, 3)
	local xpFill = Theme.frame(xpBar, {
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = Theme.Colors.Survivor,
	})
	Theme.corner(xpFill, 3)

	-- Level-up toast
	local toast = Theme.label(gui, {
		Size = UDim2.new(0, 360, 0, 60),
		Position = UDim2.new(0.5, -180, 0.28, 0),
		Text = "",
		TextSize = 30,
		TextColor3 = Theme.Colors.Gold,
		TextTransparency = 1,
		TextStrokeTransparency = 0.4,
	})

	-- Kill feed (right column)
	local feed = Instance.new("Frame")
	feed.BackgroundTransparency = 1
	feed.Size = UDim2.new(0, 300, 0, 200)
	feed.Position = UDim2.new(1, -312, 0, 64)
	feed.Parent = gui
	local feedLayout = Instance.new("UIListLayout")
	feedLayout.SortOrder = Enum.SortOrder.LayoutOrder
	feedLayout.Padding = UDim.new(0, 4)
	feedLayout.Parent = feed

	local feedCount = 0
	local function pushFeed(text: string, color: Color3?)
		feedCount += 1
		local entry = Theme.label(feed, {
			Size = UDim2.new(1, 0, 0, 18),
			Text = text,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = color or Theme.Colors.Text,
			LayoutOrder = feedCount,
		})
		task.delay(6, function()
			entry:Destroy()
		end)
	end

	-- Timer loop driven by server state pushes
	local deadline: number? = nil
	local serverOffset = 0 -- serverNow - clientNow at last sync
	task.spawn(function()
		while true do
			task.wait(0.2)
			if deadline then
				local remaining = math.max(0, deadline - (os.clock() + serverOffset))
				local minutes = math.floor(remaining / 60)
				local seconds = math.floor(remaining % 60)
				timerLabel.Text = ("%d:%02d"):format(minutes, seconds)
			else
				timerLabel.Text = "--:--"
			end
		end
	end)

	remotes.on("RoundState", function(state)
		local names = {
			WAITING = "WAITING FOR PLAYERS",
			INTERMISSION = "INTERMISSION — VOTE A MAP",
			ACTIVE = "SURVIVE",
			ROUND_END = "ROUND OVER",
		}
		stateLabel.Text = names[state.state] or tostring(state.state)
		deadline = state.deadline
		if state.serverNow then
			serverOffset = state.serverNow - os.clock()
		end
		local infected = (state.playerCount or 0) - (state.survivorCount or 0)
		hordeLabel.Text = ("Survivors %d   Infected %d"):format(
			state.survivorCount or 0,
			math.max(0, infected)
		)
	end)

	remotes.on("ConversionAlert", function(alert)
		if alert.killerName then
			pushFeed(
				("%s was infected by %s"):format(alert.victimName, alert.killerName),
				Theme.Colors.Infected
			)
		else
			pushFeed(("%s turned..."):format(alert.victimName), Theme.Colors.Infected)
		end
	end)

	remotes.on("KillFeed", function(payload)
		pushFeed(payload.text, Theme.Colors.Danger)
	end)

	remotes.on("ProfileSync", function(profile)
		coinsLabel.Text = ("%d coins"):format(profile.coins or 0)
		local level, into, needed = LevelMath.progress(profile.xp or 0)
		levelLabel.Text = ("LVL %d"):format(level)
		xpFill.Size = UDim2.new(needed > 0 and math.clamp(into / needed, 0, 1) or 0, 0, 1, 0)
	end)

	remotes.on("LevelUp", function(payload)
		local extra = payload.keys > 0
				and ("  +%d coins, +%d key%s"):format(
					payload.coins,
					payload.keys,
					payload.keys == 1 and "" or "s"
				)
			or ("  +%d coins"):format(payload.coins)
		toast.Text = ("LEVEL %d!%s"):format(payload.level, extra)
		toast.TextTransparency = 0
		toast.TextStrokeTransparency = 0.4
		TweenService:Create(toast, TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
	end)

	return {
		pushFeed = pushFeed,
	}
end

return HUD
