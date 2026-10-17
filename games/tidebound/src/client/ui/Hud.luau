--!strict
--[[
	Hud — what is true right now, and the doors to everything else.

	Top left: who you are (level, xp, purse). Top right: the sea's mood.
	Bottom left: what is on the rod, in the tin and in the crate. Right
	edge: six doors, docked together on one rail. Bottom centre: one
	contextual hint, chosen by what the profile has not seen yet -- the
	tutorial is the HUD noticing, not a modal nobody reads.

	Everything here is read-only: `refresh` paints from `state.get()` and
	never writes back. The chrome is the same vocabulary as the panels --
	deep panels with an accent cap, gold where money lives -- assembled
	from `Forge.UI` widgets and `Skin` so no screen is a one-off rectangle.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local UI = Forge.UI
local Net = Forge.Net

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local Items = require(Shared.Items)

local Skin = require(script.Parent.Skin)

local state = require(script.Parent.Parent.state)
local audio = require(script.Parent.Parent.audio)

local Hud = {}

local T = UI.theme

local lastWeather: any = nil

local HINTS = {
	{ step = "cast", text = "Hold the mouse to charge a cast, release to throw. Click the water." },
	{ step = "bite", text = "When something bites: hold to pull, let go to ease the line. Keep the marker in the light." },
	{ step = "shop", text = "The market stalls and the right-edge buttons are the same market. Bait pays for itself." },
	{ step = "sell", text = "Fish ride in your crate. Sell at the harbor -- the dock pays 15% more." },
	{ step = "boat", text = "Press the boat button, sit at the helm, and the sea becomes a road." },
	{ step = "quests", text = "Three errands a day. They pay in coins and xp. Check the Quests door." },
}

local function setVisible(widget: GuiObject, visible: boolean)
	widget.Visible = visible
end

function Hud.mount(openPanel: (string) -> ())
	local gui = UI.mount("TideboundHUD", { displayOrder = 10 })

	-- ============================ profile card ============================
	local card = UI.panel(gui, {
		name = "Profile",
		size = UDim2.fromOffset(296, 86),
		pos = UDim2.fromOffset(16, 14),
		radius = T.radius.lg,
	})
	Skin.wash(card, T.color.panelAlt:Lerp(T.color.panel, 0.55), T.color.panel)
	Skin.strip(card, T.color.accent)

	local levelLabel = UI.label(card, "LEVEL 1", {
		font = T.font.title,
		size = T.text.md,
		color = T.color.accent,
		pos = UDim2.fromOffset(16, 10),
		frameSize = UDim2.new(0, 160, 0, 18),
	})
	--: The purse wears the coin from the catalogue, and the number keeps
	--: its right edge; if the token ever misses, the label just widens.
	local coinGlyph = Skin.icon(card, "economy.coin", {
		size = UDim2.fromOffset(14, 14),
		pos = UDim2.new(1, -16, 0, 12),
		anchor = Vector2.new(1, 0),
	})
	local coinsLabel = UI.label(card, "$0", {
		font = T.font.mono,
		size = T.text.md,
		color = T.color.gold,
		pos = UDim2.new(0, 16, 0, 10),
		frameSize = UDim2.new(1, if coinGlyph then -54 else -32, 0, 18),
		align = Enum.TextXAlignment.Right,
	})
	UI.label(card, "EXPERIENCE", {
		font = T.font.bold,
		size = T.text.xs,
		color = T.color.textDim,
		pos = UDim2.fromOffset(16, 36),
		frameSize = UDim2.new(0, 120, 0, 12),
	})
	local xpBar = UI.bar(card, {
		name = "Xp",
		color = T.color.accent,
		size = UDim2.new(1, -32, 0, 12),
		pos = UDim2.fromOffset(16, 52),
		radius = T.radius.pill,
	})
	local xpText = UI.label(card, "", {
		size = T.text.xs,
		color = T.color.textDim,
		pos = UDim2.fromOffset(16, 66),
		frameSize = UDim2.new(1, -32, 0, 12),
	})

	-- ============================= weather ================================
	local weather = UI.panel(gui, {
		name = "Weather",
		size = UDim2.fromOffset(196, 70),
		pos = UDim2.new(1, -16, 0, 14),
		anchor = Vector2.new(1, 0),
		radius = T.radius.lg,
	})
	Skin.wash(weather, T.color.panelAlt:Lerp(T.color.panel, 0.55), T.color.panel)
	Skin.strip(weather, T.color.accent)
	Skin.icon(weather, "status.warning", {
		size = UDim2.fromOffset(16, 16),
		pos = UDim2.fromOffset(12, 10),
		transparency = 0.1,
	})
	local weatherPhase = UI.label(weather, "CLEAR", {
		font = T.font.title,
		size = T.text.md,
		color = T.color.text,
		pos = UDim2.fromOffset(36, 8),
		frameSize = UDim2.new(1, -48, 0, 18),
	})
	local weatherClock = UI.label(weather, "--:--", {
		font = T.font.mono,
		size = T.text.sm,
		color = T.color.textDim,
		pos = UDim2.fromOffset(36, 27),
		frameSize = UDim2.new(1, -48, 0, 16),
	})
	local _, weatherTip = Skin.chip(weather, "the sea is calm", {
		name = "Tip",
		size = UDim2.new(1, -24, 0, 17),
		pos = UDim2.fromOffset(12, 46),
		color = T.color.bg,
		transparency = 0.35,
		textColor = T.color.textDim,
		font = T.font.body,
	})

	local function paintWeather()
		if not lastWeather then
			return
		end
		weatherPhase.Text = string.upper(lastWeather.label or lastWeather.phase or "?")
		weatherClock.Text = string.format("%s  %s", Format.hour(lastWeather.hour or 0), lastWeather.night and "NIGHT" or "DAY")
		weatherClock.TextColor3 = if lastWeather.night then T.color.accent else T.color.textDim
		weatherTip.Text = if lastWeather.night
			then "night fish are up -- luck is greener"
			else "the water remembers the storm"
	end

	Net.on("WeatherSync", function(payload: any)
		lastWeather = payload
		paintWeather()
	end)

	-- ============================== loadout ===============================
	local loadout = UI.panel(gui, {
		name = "Loadout",
		size = UDim2.fromOffset(296, 108),
		pos = UDim2.new(0, 16, 1, -16),
		anchor = Vector2.new(0, 1),
		radius = T.radius.lg,
	})
	Skin.wash(loadout, T.color.panelAlt:Lerp(T.color.panel, 0.55), T.color.panel)
	Skin.strip(loadout, T.color.accent)
	local rodLabel = UI.label(loadout, "ROD  --", {
		size = T.text.sm,
		color = T.color.text,
		pos = UDim2.fromOffset(16, 12),
		frameSize = UDim2.new(1, -32, 0, 16),
	})
	local baitLabel = UI.label(loadout, "BAIT  --", {
		size = T.text.sm,
		color = T.color.text,
		pos = UDim2.fromOffset(16, 32),
		frameSize = UDim2.new(1, -32, 0, 16),
	})
	local crateLabel = UI.label(loadout, "CRATE 0/24", {
		size = T.text.sm,
		color = T.color.text,
		pos = UDim2.fromOffset(16, 52),
		frameSize = UDim2.new(1, -32, 0, 16),
	})
	--: Luck reads as a chip rather than a fourth line of prose: it is a
	--: bonus, not a possession, and the pill says so at a glance.
	local _, luckLabel = Skin.chip(loadout, "LUCK  +0.0", {
		name = "Luck",
		size = UDim2.fromOffset(96, 18),
		pos = UDim2.fromOffset(16, 76),
		color = T.color.panelAlt,
		transparency = 0.25,
		textColor = T.color.good,
		font = T.font.mono,
	})

	local sellButton = UI.button(loadout, "SELL CRATE", {
		name = "Sell",
		size = UDim2.new(0, 110, 0, 26),
		pos = UDim2.new(1, -124, 1, -36),
		color = T.color.gold,
		textColor = T.color.bg,
		onClick = function()
			audio.sfx("ui.click")
			Net.send("SellCrate", {})
		end,
	})
	sellButton.TextSize = T.text.xs

	local boatRow = Instance.new("Frame")
	boatRow.Name = "BoatRow"
	boatRow.BackgroundTransparency = 1
	boatRow.Size = UDim2.new(0, 110, 0, 56)
	boatRow.Position = UDim2.new(1, -124, 0, 12)
	boatRow.Parent = loadout
	UI.list(boatRow, { gap = 4 })
	UI.button(boatRow, "CALL BOAT", {
		size = UDim2.new(1, 0, 0, 26),
		color = T.color.panelAlt,
		onClick = function()
			audio.sfx("ui.click")
			Net.send("SummonBoat", {})
			local profile = state.get()
			if profile and not profile.tutorial.seen.boat then
				Net.send("TutorialDone", { step = "boat" })
			end
		end,
	}).TextSize = T.text.xs
	UI.button(boatRow, "STOW BOAT", {
		size = UDim2.new(1, 0, 0, 26),
		color = T.color.panelAlt,
		onClick = function()
			audio.sfx("ui.click")
			Net.send("StoreBoat", {})
		end,
	}).TextSize = T.text.xs

	-- ============================== doors =================================
	--: One rail behind the six doors, so the right edge reads as a control
	--: dock instead of six buttons floating over the water.
	local doors = UI.panel(gui, {
		name = "Doors",
		size = UDim2.fromOffset(146, 226),
		pos = UDim2.new(1, -16, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		color = T.color.panel,
		transparency = 0.25,
		radius = T.radius.lg,
	})
	Skin.strip(doors, T.color.accent, { size = UDim2.new(1, -14, 0, 3), pos = UDim2.fromOffset(7, 2) })

	--: The buttons live on an inner stack, not on the rail itself: a
	--: UIListLayout lays out *every* child, and the strip above is one.
	local doorStack = Instance.new("Frame")
	doorStack.Name = "Stack"
	doorStack.BackgroundTransparency = 1
	doorStack.Size = UDim2.new(1, -14, 1, -14)
	doorStack.Position = UDim2.fromOffset(7, 7)
	doorStack.Parent = doors
	UI.list(doorStack, { gap = 6, vAlign = Enum.VerticalAlignment.Center })

	local DOORS = {
		{ id = "shop", label = "MARKET", token = "nav.shop" },
		{ id = "map", label = "TIDE MAP", token = "nav.map" },
		{ id = "bestiary", label = "BESTIARY", token = "nav.inventory" },
		{ id = "quests", label = "QUESTS", token = "nav.quest" },
		{ id = "ranks", label = "RANKS", token = "nav.leaderboard" },
		{ id = "settings", label = "SETTINGS", token = "nav.settings" },
	}
	for _, door in DOORS do
		local button = UI.button(doorStack, door.label, {
			name = door.id,
			size = UDim2.new(1, 0, 0, 30),
			color = T.color.panelAlt,
			onClick = function()
				audio.sfx("ui.open")
				openPanel(door.id)
			end,
		})
		button.TextSize = T.text.xs
		button.TextXAlignment = Enum.TextXAlignment.Left
		local glyph = Skin.icon(button, door.token, {
			size = UDim2.fromOffset(15, 15),
			pos = UDim2.new(0, 9, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			transparency = 0.1,
		})
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, if glyph then 31 else 10)
		padding.Parent = button
	end

	-- =============================== hint =================================
	local hint = UI.panel(gui, {
		name = "Hint",
		size = UDim2.fromOffset(640, 38),
		pos = UDim2.new(0.5, 0, 1, -64),
		anchor = Vector2.new(0.5, 1),
		color = T.color.panel,
		transparency = 0.15,
		radius = T.radius.lg,
	})
	Skin.wash(hint, T.color.panelAlt:Lerp(T.color.panel, 0.6), T.color.panel)
	Skin.strip(hint, T.color.accent, { size = UDim2.new(1, -28, 0, 2), pos = UDim2.fromOffset(14, 2) })
	Skin.icon(hint, "status.info", {
		size = UDim2.fromOffset(16, 16),
		pos = UDim2.new(0, 14, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		transparency = 0.15,
	})
	local hintLabel = UI.label(hint, "", {
		size = T.text.sm,
		color = T.color.text,
		frameSize = UDim2.new(1, -62, 1, 0),
		align = Enum.TextXAlignment.Center,
		pos = UDim2.fromOffset(38, 0),
	})

	-- ============================ quest focus =============================
	--: One line, under the hint bar: the day's most finishable errand. The
	--: HUD renders it and never reads a quest itself -- focus is a reading
	--: of the save, and the save already has exactly one writer.
	local questLine, questLabel = Skin.chip(gui, "", {
		name = "QuestFocus",
		size = UDim2.fromOffset(620, 24),
		pos = UDim2.new(0.5, 0, 1, -22),
		anchor = Vector2.new(0.5, 1),
		color = T.color.panelAlt,
		transparency = 0.2,
		textColor = T.color.accent,
		visible = false,
	})

	local function setQuest(text: string?)
		questLabel.Text = text or ""
		questLine.Visible = text ~= nil and text ~= ""
	end

	local function refresh()
		local profile = state.get()
		if not profile then
			return
		end
		local level = state.level()
		levelLabel.Text = string.format("LEVEL %d", level)
		coinsLabel.Text = Format.money(profile.coins or 0)
		xpBar:set(state.xpAlpha())
		local floor = Config.xpForLevel(level)
		local ceil = Config.xpForLevel(math.min(level + 1, Config.maxLevel))
		xpText.Text = string.format("%d / %d to next level", (profile.xp or 0) - floor, ceil - floor)

		local rod = state.rod()
		rodLabel.Text = string.format("ROD   %s  (%.0f power)", rod and rod.name or "--", rod and rod.power or 0)
		local bait = state.bait()
		if bait then
			baitLabel.Text = string.format("BAIT  %s  x%d", bait.name, state.baitCount(bait.id))
		else
			baitLabel.Text = "BAIT  bare hook"
		end
		local crate = profile.crate or {}
		local capacity = Items.crateCapacity(profile.boats and profile.boats.equipped or "rowboat")
		crateLabel.Text = string.format("CRATE %d/%d", #crate, capacity)
		luckLabel.Text = string.format("LUCK  +%.1f", profile.luck or 0)

		--: The first hint the profile has not seen. Nil-safe on purpose.
		local seen = profile.tutorial and profile.tutorial.seen or {}
		local chosen = nil
		for _, entry in HINTS do
			if not seen[entry.step] then
				chosen = entry
				break
			end
		end
		if chosen then
			hintLabel.Text = chosen.text
			setVisible(hint, true)
		else
			setVisible(hint, false)
		end
		sellButton.Text = string.format("SELL  %d", #crate)
		sellButton.Active = #crate > 0
		sellButton.TextColor3 = if #crate > 0 then T.color.bg else T.color.textDim

		paintWeather()
	end

	state.changed:Connect(refresh)
	refresh()

	return {
		gui = gui,
		refresh = refresh,
		--: Written by QuestTrackerController, never by refresh: the focus
		--: changes when the save does, and that is a different signal.
		setQuest = setQuest,
	}
end

return Hud
