--!strict
--[[
	Panels — the six doors, and the room behind each one.

	One scrim, one frame, six builders. Each builder fills the content area
	from whatever state exists right now and registers a refresh, so an
	open panel follows a profile change without being closed and reopened.

	Full rebuild on refresh: at this scale (sixty bestiary cells, a dozen
	shop rows) clearing and redrawing is cheaper than diffing, and a panel
	that draws itself from state can never show a stale price.

	The chrome is shared with the HUD through `Skin`: an accent-capped
	frame, a title bar closed by one hairline, and one vocabulary for list
	rows -- a card, a hover lift, and a coloured edge drawn only where
	state matters (equipped, in use, done, claimed). Colour is spent on
	information, never on decoration.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local UI = Forge.UI
local Net = Forge.Net

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local FishCatalog = require(Shared.FishCatalog)
local Format = require(Shared.Format)

local Skin = require(script.Parent.Skin)

local state = require(script.Parent.Parent.state)
local audio = require(script.Parent.Parent.audio)

local Panels = {}

local T = UI.theme

local gui: ScreenGui? = nil
local scrim: TextButton? = nil
local frame: GuiObject? = nil
local titleLabel: TextLabel? = nil
local subtitleLabel: TextLabel? = nil
local content: ScrollingFrame? = nil
local tabRow: Frame? = nil

local current: string? = nil
local refreshers: { [string]: () -> () } = {}
local built: { [string]: boolean } = {}

--: Async caches for the two channels that push rather than answer.
local questPayload: any = nil
local boardCache: { [string]: any } = {}
local boardTab = "biggest_day"

local TAB_LIST = {
	{ id = "shop", label = "MARKET" },
	{ id = "map", label = "TIDE MAP" },
	{ id = "bestiary", label = "BESTIARY" },
	{ id = "quests", label = "QUESTS" },
	{ id = "ranks", label = "RANKS" },
	{ id = "settings", label = "SETTINGS" },
}

-- ================================ helpers ===================================
--: The house row: a card that lists itself under a layout and lifts under
--: the cursor. State edges are drawn by the callers that have state.
local function row(parent: Instance, height: number, options: any?): GuiObject
	local o = options or {}
	local card = UI.panel(parent, {
		size = UDim2.new(1, -8, 0, height),
		color = o.color or T.color.panelAlt,
		transparency = o.transparency or 0.25,
		radius = T.radius.md,
	})
	Skin.hover(card)
	return card
end

--: A 3px state edge, inset so it cannot poke out of the card's rounded
--: corners: accent = in hand, gold = ready, good = done.
local function edge(card: GuiObject, color: Color3)
	local strip = Instance.new("Frame")
	strip.Name = "Edge"
	strip.BackgroundColor3 = color
	strip.BorderSizePixel = 0
	strip.Size = UDim2.new(0, 3, 1, -16)
	strip.Position = UDim2.fromOffset(0, 8)
	strip.ZIndex = 2
	strip.Parent = card
	UI.corner(strip, 2)
end

local function setContent(fn: () -> ())
	local box = content
	if not box then
		return
	end
	for _, child in box:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
	fn()
end

--: Section caption with an accent tick. The tick lives inside its own
--: container Frame: a ScrollingFrame's UIListLayout lays out every child,
--: so the decoration cannot sit beside the caption as a direct sibling.
local function caption(parent: Instance, text: string)
	local head = Instance.new("Frame")
	head.Name = "Caption"
	head.BackgroundTransparency = 1
	head.Size = UDim2.new(1, -8, 0, 22)
	head.Parent = parent

	local tick = Instance.new("Frame")
	tick.Name = "Tick"
	tick.BackgroundColor3 = T.color.accent
	tick.BackgroundTransparency = 0.2
	tick.BorderSizePixel = 0
	tick.Size = UDim2.fromOffset(3, 11)
	tick.Position = UDim2.fromOffset(4, 6)
	tick.ZIndex = 2
	tick.Parent = head
	UI.corner(tick, 2)

	UI.label(head, string.upper(text), {
		font = T.font.bold,
		size = T.text.xs,
		color = T.color.textDim,
		frameSize = UDim2.new(1, -20, 0, 18),
		pos = UDim2.fromOffset(14, 2),
	})
end

--: What a list says when it has nothing: a quiet card, not a blank gap.
local function emptyState(parent: Instance, text: string)
	local card = UI.panel(parent, {
		size = UDim2.new(1, -8, 0, 58),
		color = T.color.panel,
		transparency = 0.45,
		radius = T.radius.md,
	})
	UI.label(card, text, {
		size = T.text.sm,
		color = T.color.textDim,
		wrap = true,
		frameSize = UDim2.new(1, -28, 1, 0),
		pos = UDim2.fromOffset(14, 0),
		align = Enum.TextXAlignment.Center,
	})
end

-- ================================= market ===================================
local function buildShop()
	setContent(function()
		local profile = state.get()
		if not profile or not content then
			return
		end
		local box = content

		caption(box, "rods")
		for _, rod in Items.rods do
			local owned = profile.rods.owned[rod.id] == true
			local equipped = profile.rods.equipped == rod.id
			local line = row(box, 52)
			if equipped then
				edge(line, T.color.accent)
			end
			UI.label(line, rod.name, {
				font = T.font.bold,
				size = T.text.md,
				color = if equipped then T.color.accent else T.color.text,
				pos = UDim2.fromOffset(12, 6),
				frameSize = UDim2.new(0.6, 0, 0, 18),
			})
			UI.label(line, string.format("power %.0f   luck +%d   range %.0fm   reel x%.2f", rod.power, rod.luck, rod.range, rod.reel), {
				size = T.text.xs,
				color = T.color.textDim,
				pos = UDim2.fromOffset(12, 26),
				frameSize = UDim2.new(0.75, 0, 0, 14),
			})
			UI.label(line, rod.blurb, {
				size = T.text.xs,
				color = T.color.textDim,
				pos = UDim2.fromOffset(12, 38),
				frameSize = UDim2.new(0.75, 0, 0, 12),
			})
			if equipped then
				UI.label(line, "EQUIPPED", {
					font = T.font.bold,
					size = T.text.sm,
					color = T.color.accent,
					pos = UDim2.new(1, -110, 0, 16),
					frameSize = UDim2.fromOffset(98, 20),
					align = Enum.TextXAlignment.Right,
				})
			else
				local label = if owned then "EQUIP" else Format.money(rod.cost)
				local canAfford = owned or (profile.coins >= rod.cost)
				UI.button(line, label, {
					size = UDim2.fromOffset(98, 26),
					pos = UDim2.new(1, -110, 0, 13),
					color = if not canAfford then T.color.panel
						elseif owned then T.color.panelAlt
						else T.color.gold,
					textColor = if not canAfford then T.color.textDim
						elseif owned then T.color.text
						else T.color.bg,
					onClick = function()
						audio.sfx("ui.click")
						if owned then
							Net.send("EquipRod", { rod = rod.id })
						else
							Net.send("BuyRod", { rod = rod.id })
						end
					end,
				}).TextSize = T.text.xs
			end
		end

		caption(box, "bait")
		for _, bait in Items.baits do
			local count = profile.baits.owned[bait.id] or 0
			local equipped = profile.baits.equipped == bait.id
			local line = row(box, 44)
			if equipped then
				edge(line, T.color.accent)
			end
			UI.label(line, string.format("%s   x%d", bait.name, count), {
				font = T.font.bold,
				size = T.text.sm,
				color = if equipped then T.color.accent else T.color.text,
				pos = UDim2.fromOffset(12, 5),
				frameSize = UDim2.new(0.6, 0, 0, 16),
			})
			UI.label(line, string.format("bite x%.2f   luck +%d   -- %s", bait.bite, bait.luck, bait.blurb), {
				size = T.text.xs,
				color = T.color.textDim,
				pos = UDim2.fromOffset(12, 23),
				frameSize = UDim2.new(0.8, 0, 0, 14),
			})
			local buyCost = bait.cost * 5
			local canAfford = profile.coins >= buyCost
			UI.button(line, "BUY x5  " .. Format.money(buyCost), {
				size = UDim2.fromOffset(110, 24),
				pos = UDim2.new(1, -122, 0, 4),
				color = if canAfford then T.color.gold else T.color.panel,
				textColor = if canAfford then T.color.bg else T.color.textDim,
				onClick = function()
					audio.sfx("ui.click")
					Net.send("BuyBait", { bait = bait.id, qty = 5 })
				end,
			}).TextSize = T.text.xs
			if count > 0 then
				UI.button(line, if equipped then "IN USE" else "USE", {
					size = UDim2.fromOffset(74, 24),
					pos = UDim2.new(1, -122, 0, 30),
					color = if equipped then T.color.accent else T.color.panelAlt,
					textColor = if equipped then T.color.bg else T.color.text,
					onClick = function()
						audio.sfx("ui.click")
						Net.send("EquipBait", { bait = bait.id })
					end,
				}).TextSize = T.text.xs
			end
		end

		caption(box, "boats")
		for _, boat in Items.boats do
			local owned = profile.boats.owned[boat.id] == true
			local equipped = profile.boats.equipped == boat.id
			local line = row(box, 46)
			if equipped then
				edge(line, T.color.accent)
			end
			UI.label(line, boat.name, {
				font = T.font.bold,
				size = T.text.sm,
				color = if equipped then T.color.accent else T.color.text,
				pos = UDim2.fromOffset(12, 5),
				frameSize = UDim2.new(0.6, 0, 0, 16),
			})
			UI.label(line, string.format("speed %.0f   crate +%d   boat luck +%d", boat.speed, boat.crate, boat.luck), {
				size = T.text.xs,
				color = T.color.textDim,
				pos = UDim2.fromOffset(12, 24),
				frameSize = UDim2.new(0.8, 0, 0, 14),
			})
			if owned then
				UI.button(line, if equipped then "IN USE" else "USE", {
					size = UDim2.fromOffset(90, 24),
					pos = UDim2.new(1, -102, 0, 10),
					color = if equipped then T.color.accent else T.color.panelAlt,
					textColor = if equipped then T.color.bg else T.color.text,
					onClick = function()
						audio.sfx("ui.click")
						Net.send("BuyBoat", { boat = boat.id })
					end,
				}).TextSize = T.text.xs
			else
				local canAfford = profile.coins >= boat.cost
				UI.button(line, Format.money(boat.cost), {
					size = UDim2.fromOffset(90, 24),
					pos = UDim2.new(1, -102, 0, 10),
					color = if canAfford then T.color.gold else T.color.panel,
					textColor = if canAfford then T.color.bg else T.color.textDim,
					onClick = function()
						audio.sfx("ui.click")
						Net.send("BuyBoat", { boat = boat.id })
					end,
				}).TextSize = T.text.xs
			end
		end
	end)
end

-- ================================== map =====================================
local function buildMap()
	setContent(function()
		local profile = state.get()
		if not profile or not content then
			return
		end
		local level = state.level()
		local here = nil
		local character = game:GetService("Players").LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			local zone = Config.zoneAt(root.Position)
			here = zone and zone.id or nil
		end

		for _, zone in Config.zones do
			local unlocked = profile.zones[zone.id] == true
			local line = row(content, 62)
			if here == zone.id then
				edge(line, T.color.accent)
			end
			UI.label(line, zone.name, {
				font = T.font.title,
				size = T.text.md,
				color = if here == zone.id then T.color.accent else T.color.text,
				pos = UDim2.fromOffset(12, 6),
				frameSize = UDim2.new(0.65, 0, 0, 18),
			})
			UI.label(line, zone.blurb, {
				size = T.text.xs,
				color = T.color.textDim,
				pos = UDim2.fromOffset(12, 26),
				frameSize = UDim2.new(0.65, 0, 0, 14),
			})
			UI.label(line, string.format("%s water   --   %s", zone.depth, if here == zone.id then "you are here" else "open sea"), {
				size = T.text.xs,
				color = T.color.textDim,
				pos = UDim2.fromOffset(12, 42),
				frameSize = UDim2.new(0.65, 0, 0, 14),
			})
			if not unlocked then
				local can = level >= zone.unlockLevel and profile.coins >= zone.cost
				UI.button(line, string.format("CHART  %s  (Lv %d)", Format.money(zone.cost), zone.unlockLevel), {
					size = UDim2.fromOffset(160, 28),
					pos = UDim2.new(1, -172, 0, 17),
					color = if can then T.color.gold else T.color.panel,
					textColor = if can then T.color.bg else T.color.textDim,
					onClick = function()
						audio.sfx("ui.click")
						Net.send("UnlockZone", { zone = zone.id })
					end,
				}).TextSize = T.text.xs
			elseif here ~= zone.id then
				UI.button(line, "TRAVEL", {
					size = UDim2.fromOffset(160, 28),
					pos = UDim2.new(1, -172, 0, 17),
					color = T.color.accent,
					textColor = T.color.bg,
					onClick = function()
						audio.sfx("ui.click")
						Net.send("TravelTo", { zone = zone.id })
					end,
				}).TextSize = T.text.xs
			else
				UI.label(line, "CHARTED -- YOU ARE HERE", {
					font = T.font.bold,
					size = T.text.xs,
					color = T.color.accent,
					pos = UDim2.new(1, -180, 0, 22),
					frameSize = UDim2.fromOffset(168, 18),
					align = Enum.TextXAlignment.Right,
				})
			end
		end
	end)
end

-- ================================ bestiary ==================================
local function buildBestiary()
	setContent(function()
		local profile = state.get()
		if not profile or not content then
			return
		end
		local bestiary = profile.bestiary or {}
		local known = profile.stats.species or 0

		local header = row(content, 44)
		local medal = Skin.icon(header, "status.medal", {
			size = UDim2.fromOffset(16, 16),
			pos = UDim2.fromOffset(14, 14),
			transparency = 0.1,
		})
		UI.label(header, string.format("%d of %d species recorded", known, FishCatalog.total()), {
			font = T.font.bold,
			size = T.text.md,
			color = T.color.gold,
			pos = UDim2.fromOffset(if medal then 38 else 14, 12),
			frameSize = UDim2.new(1, if medal then -52 else -28, 0, 20),
		})

		local grid = Instance.new("Frame")
		grid.Name = "Grid"
		grid.BackgroundTransparency = 1
		grid.Size = UDim2.new(1, -8, 0, 0)
		grid.AutomaticSize = Enum.AutomaticSize.Y
		grid.Parent = content
		local layout = Instance.new("UIGridLayout")
		layout.CellSize = UDim2.fromOffset(148, 64)
		layout.CellPadding = UDim2.fromOffset(6, 6)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = grid

		for order, entry in FishCatalog.species do
			local record = bestiary[entry.id]
			local tier = FishCatalog.rarityById[entry.rarity]
			local cell = UI.panel(grid, {
				name = entry.id,
				size = UDim2.fromOffset(148, 64),
				color = if record then T.color.panelAlt else T.color.panel,
				transparency = if record then 0.1 else 0.4,
				strokeColor = if record and tier then tier.color else T.color.stroke,
			})
			cell.LayoutOrder = order
			if not record then
				local lock = Skin.icon(cell, "status.lock", {
					size = UDim2.fromOffset(18, 18),
					pos = UDim2.new(0.5, 0, 0, 12),
					anchor = Vector2.new(0.5, 0),
					transparency = 0.25,
				})
				UI.label(cell, "???", {
					font = T.font.title,
					size = T.text.md,
					color = T.color.textDim,
					frameSize = UDim2.new(1, 0, 0, 18),
					pos = UDim2.fromOffset(0, if lock then 34 else 23),
					align = Enum.TextXAlignment.Center,
				})
			else
				local strip = Instance.new("Frame")
				strip.Name = "Rarity"
				strip.BackgroundColor3 = tier and tier.color or T.color.stroke
				strip.BorderSizePixel = 0
				strip.Size = UDim2.new(0, 3, 1, -16)
				strip.Position = UDim2.fromOffset(0, 8)
				strip.ZIndex = 2
				strip.Parent = cell
				UI.corner(strip, 2)
				UI.label(cell, entry.name, {
					font = T.font.bold,
					size = T.text.sm,
					color = T.color.text,
					pos = UDim2.fromOffset(14, 6),
					frameSize = UDim2.new(1, -20, 0, 16),
				})
				UI.label(cell, string.format("%s  x%d", tier and tier.name or entry.rarity, record.count or 0), {
					size = T.text.xs,
					color = tier and tier.color or T.color.textDim,
					pos = UDim2.fromOffset(14, 24),
					frameSize = UDim2.new(1, -20, 0, 14),
				})
				UI.label(cell, string.format("best %.2f kg", record.record or 0), {
					font = T.font.mono,
					size = T.text.xs,
					color = T.color.textDim,
					pos = UDim2.fromOffset(14, 42),
					frameSize = UDim2.new(1, -20, 0, 14),
				})
			end
		end
	end)
end

-- ================================= quests ===================================
local function buildQuests()
	setContent(function()
		if not content then
			return
		end
		local payload = questPayload
		if not payload then
			emptyState(content, "Loading the day's errands...")
			return
		end

		local banner = row(content, 56)
		edge(banner, T.color.gold)
		UI.label(banner, string.format("LOGIN STREAK  DAY %d", payload.streak or 1), {
			font = T.font.title,
			size = T.text.md,
			color = T.color.gold,
			pos = UDim2.fromOffset(14, 8),
			frameSize = UDim2.new(0.6, 0, 0, 18),
		})
		local reward = payload.login or { coins = 0 }
		UI.label(banner, string.format("today's purse: %s   --   quest rewards x%.2f", Format.money(reward.coins or 0), payload.multiplier or 1), {
			size = T.text.xs,
			color = T.color.textDim,
			pos = UDim2.fromOffset(14, 30),
			frameSize = UDim2.new(0.7, 0, 0, 14),
		})
		if payload.dailyClaimed then
			UI.label(banner, "CLAIMED", {
				font = T.font.bold,
				size = T.text.sm,
				color = T.color.textDim,
				pos = UDim2.new(1, -130, 0, 18),
				frameSize = UDim2.fromOffset(118, 20),
				align = Enum.TextXAlignment.Right,
			})
		else
			UI.button(banner, "CLAIM TODAY", {
				size = UDim2.fromOffset(118, 28),
				pos = UDim2.new(1, -130, 0, 14),
				color = T.color.gold,
				textColor = T.color.bg,
				onClick = function()
					audio.sfx("ui.success")
					Net.send("ClaimDaily", {})
				end,
			}).TextSize = T.text.xs
		end

		local list = payload.list or {}
		if #list == 0 then
			emptyState(content, "The errands board is empty today. New work is posted at midnight UTC.")
		end
		for _, quest in list do
			local line = row(content, 58)
			local done = (quest.progress or 0) >= (quest.target or 1)
			if quest.claimed then
				edge(line, T.color.good)
			elseif done then
				edge(line, T.color.gold)
			else
				edge(line, T.color.accent)
			end
			UI.label(line, quest.label, {
				font = T.font.bold,
				size = T.text.sm,
				color = T.color.text,
				pos = UDim2.fromOffset(14, 8),
				frameSize = UDim2.new(0.7, 0, 0, 16),
			})
			UI.label(line, string.format("pays %s and %d xp", Format.money(quest.rewardCoins or 0), quest.rewardXp or 0), {
				size = T.text.xs,
				color = T.color.textDim,
				pos = UDim2.fromOffset(14, 40),
				frameSize = UDim2.new(0.7, 0, 0, 14),
			})
			local progress = UI.bar(line, {
				color = if done then T.color.good else T.color.accent,
				size = UDim2.new(0.55, 0, 0, 10),
				pos = UDim2.fromOffset(14, 26),
				radius = T.radius.pill,
			})
			progress:setInstant(math.clamp((quest.progress or 0) / math.max(quest.target or 1, 1), 0, 1))

			if quest.claimed then
				UI.label(line, "PAID", {
					font = T.font.bold,
					size = T.text.sm,
					color = T.color.good,
					pos = UDim2.new(1, -120, 0, 18),
					frameSize = UDim2.fromOffset(108, 20),
					align = Enum.TextXAlignment.Right,
				})
			elseif done then
				UI.button(line, "CLAIM", {
					size = UDim2.fromOffset(108, 28),
					pos = UDim2.new(1, -122, 0, 15),
					color = T.color.good,
					textColor = T.color.bg,
					onClick = function()
						audio.sfx("ui.success")
						Net.send("ClaimQuest", { questId = quest.id })
					end,
				}).TextSize = T.text.xs
			else
				UI.label(line, string.format("%d / %d", quest.progress or 0, quest.target or 1), {
					font = T.font.mono,
					size = T.text.sm,
					color = T.color.textDim,
					pos = UDim2.new(1, -120, 0, 18),
					frameSize = UDim2.fromOffset(108, 20),
					align = Enum.TextXAlignment.Right,
				})
			end
		end
	end)
end

-- ================================== ranks ===================================
local function buildRanks()
	setContent(function()
		if not content then
			return
		end

		local tabs = Instance.new("Frame")
		tabs.BackgroundTransparency = 1
		tabs.Size = UDim2.new(1, -8, 0, 30)
		tabs.Parent = content
		UI.list(tabs, { horizontal = true, gap = 6 })
		for _, definition in { "biggest_day", "species", "coins" } do
			local label = string.gsub(definition, "_", " ")
			local active = boardTab == definition
			local button = UI.button(tabs, string.upper(label), {
				size = UDim2.fromOffset(140, 26),
				color = if active then T.color.accent else T.color.panelAlt,
				textColor = if active then T.color.bg else T.color.text,
				onClick = function()
					audio.sfx("ui.click")
					boardTab = definition
					Net.send("RequestBoard", { board = definition })
					buildRanks()
				end,
			})
			button.TextSize = T.text.xs
		end

		local payload = boardCache[boardTab]
		if not payload then
			emptyState(content, "Asking the harbor master...")
			return
		end

		UI.label(content, string.format("%s   --   %s", payload.title or "", payload.subtitle or ""), {
			size = T.text.xs,
			color = T.color.textDim,
			frameSize = UDim2.new(1, -8, 0, 16),
		})

		local rows = payload.rows or {}
		if #rows == 0 then
			emptyState(content, "No one has posted to this board yet -- the day is young.")
		end
		for _, entry in rows do
			local line = if entry.me
				then row(content, 30, { color = T.color.accent, transparency = 0.85 })
				else row(content, 30)
			if entry.me then
				edge(line, T.color.accent)
			end
			UI.label(line, string.format("#%d", entry.rank), {
				font = T.font.mono,
				size = T.text.sm,
				color = if entry.rank == 1 then T.color.gold else T.color.textDim,
				pos = UDim2.fromOffset(12, 0),
				frameSize = UDim2.fromOffset(40, 30),
			})
			UI.label(line, entry.name, {
				font = if entry.me then T.font.bold else T.font.body,
				size = T.text.sm,
				color = if entry.me then T.color.accent else T.color.text,
				pos = UDim2.fromOffset(58, 0),
				frameSize = UDim2.new(0.6, 0, 1, 0),
			})
			local value = entry.value
			local text = if payload.unit == "kg" then string.format("%.2f kg", value)
				elseif payload.unit == "coins" then Format.money(value)
				else tostring(math.floor(value))
			UI.label(line, text, {
				font = T.font.mono,
				size = T.text.sm,
				color = T.color.gold,
				pos = UDim2.new(1, -160, 0, 0),
				frameSize = UDim2.fromOffset(148, 30),
				align = Enum.TextXAlignment.Right,
			})
		end

		if payload.resetIn then
			UI.label(content, string.format("resets in %s", Format.duration(payload.resetIn)), {
				size = T.text.xs,
				color = T.color.textDim,
				frameSize = UDim2.new(1, -8, 0, 16),
			})
		end
	end)
end

-- ================================ settings ==================================
local function buildSettings()
	setContent(function()
		local profile = state.get()
		if not profile or not content then
			return
		end

		local function volumeRow(label: string, key: string)
			local line = row(content, 44)
			UI.label(line, label, {
				font = T.font.bold,
				size = T.text.sm,
				color = T.color.text,
				pos = UDim2.fromOffset(14, 10),
				frameSize = UDim2.new(0.4, 0, 0, 18),
			})
			local value = profile.settings[key] or 0
			--: The meter repeats the number as a shape, so a glance across
			--: the row reads the level without parsing the percentage.
			local meter = UI.bar(line, {
				color = T.color.accent,
				size = UDim2.new(0.4, -14, 0, 5),
				pos = UDim2.fromOffset(14, 31),
				radius = T.radius.pill,
				autoStep = false,
			})
			meter:setInstant(value)
			UI.label(line, string.format("%d%%", math.floor(value * 100)), {
				font = T.font.mono,
				size = T.text.sm,
				color = T.color.textDim,
				pos = UDim2.new(0.45, 0, 0, 12),
				frameSize = UDim2.fromOffset(60, 18),
			})
			local function bump(delta: number)
				local current = state.get()
				if not current then
					return
				end
				local next_ = math.clamp(current.settings[key] + delta, 0, 1)
				current.settings[key] = next_
				audio.sfx("ui.click")
				audio.setVolumes(current.settings)
				Net.send("SaveSettings", { music = current.settings.music, sfx = current.settings.sfx })
				buildSettings()
			end
			UI.button(line, "-10", {
				size = UDim2.fromOffset(54, 26),
				pos = UDim2.new(1, -238, 0, 9),
				color = T.color.panelAlt,
				onClick = function()
					bump(-0.1)
				end,
			}).TextSize = T.text.xs
			UI.button(line, "+10", {
				size = UDim2.fromOffset(54, 26),
				pos = UDim2.new(1, -178, 0, 9),
				color = T.color.panelAlt,
				onClick = function()
					bump(0.1)
				end,
			}).TextSize = T.text.xs
			UI.button(line, if key == "music" then "MUSIC" else "SOUND", {
				size = UDim2.fromOffset(100, 26),
				pos = UDim2.new(1, -118, 0, 9),
				color = T.color.panel,
				textColor = T.color.textDim,
				onClick = function()
					bump(0)
				end,
			}).TextSize = T.text.xs
		end

		volumeRow("Master music", "music")
		volumeRow("Master sound", "sfx")

		local tips = row(content, 88)
		UI.label(tips, "HOW TO FISH", {
			font = T.font.bold,
			size = T.text.xs,
			color = T.color.textDim,
			pos = UDim2.fromOffset(14, 10),
			frameSize = UDim2.new(1, -28, 0, 14),
		})
		UI.label(tips, "Hold the mouse to charge, release over open water. When the bite comes: hold to pull, release to ease. Keep the marker inside the light and the line will hold. Sell at the harbor for the 15% bonus; sail far for what the shallows do not carry.", {
			size = T.text.sm,
			color = T.color.text,
			wrap = true,
			pos = UDim2.fromOffset(14, 26),
			frameSize = UDim2.new(1, -28, 0, 56),
		})
	end)
end

local BUILDERS = {
	shop = buildShop,
	map = buildMap,
	bestiary = buildBestiary,
	quests = buildQuests,
	ranks = buildRanks,
	settings = buildSettings,
}

local TITLES = {
	shop = { "THE MARKET", "rods, bait and boats -- the harbor's whole pitch" },
	map = { "TIDE MAP", "five waters, and what it costs to know them" },
	bestiary = { "BESTIARY", "everything the sea has shown you so far" },
	quests = { "QUESTS", "three errands, renewed at midnight UTC" },
	ranks = { "RANKS", "who is catching what, right now" },
	settings = { "SETTINGS", "volume, and how to fish" },
}

-- ================================== host ====================================
function Panels.refresh()
	local id = current
	if id and refreshers[id] then
		refreshers[id]()
	end
end

function Panels.open(id: string)
	if not frame or not titleLabel or not content or not tabRow then
		return
	end
	if not BUILDERS[id] then
		id = "shop"
	end
	current = id
	built[id] = true

	titleLabel.Text = TITLES[id][1]
	subtitleLabel.Text = TITLES[id][2]
	for _, button in tabRow:GetChildren() do
		if button:IsA("TextButton") then
			local active = button.Name == id
			button.BackgroundColor3 = if active then T.color.accent else T.color.panelAlt
			button.TextColor3 = if active then T.color.bg else T.color.text
		end
	end

	BUILDERS[id]()
	refreshers[id] = BUILDERS[id]
	if id == "ranks" then
		Net.send("RequestBoard", { board = boardTab })
	end
	frame.Visible = true
	scrim.Visible = true
end

function Panels.close()
	if frame then
		frame.Visible = false
	end
	if scrim then
		scrim.Visible = false
	end
	current = nil
end

function Panels.toggle(id: string)
	if current == id then
		Panels.close()
	else
		Panels.open(id)
	end
end

function Panels.mount()
	gui = UI.mount("TideboundPanels", { displayOrder = 20 })

	scrim = Instance.new("TextButton")
	scrim.Name = "Scrim"
	scrim.Text = ""
	scrim.AutoButtonColor = false
	scrim.BackgroundColor3 = T.color.bg
	scrim.BackgroundTransparency = 0.45
	scrim.BorderSizePixel = 0
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.Visible = false
	scrim.Parent = gui
	scrim.MouseButton1Click:Connect(Panels.close)

	frame = UI.panel(gui, {
		name = "Frame",
		size = UDim2.fromOffset(760, 480),
		pos = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		radius = T.radius.lg,
		visible = false,
	})
	Skin.wash(frame, T.color.panelAlt:Lerp(T.color.panel, 0.5), T.color.panel)
	Skin.strip(frame, T.color.accent)

	titleLabel = UI.label(frame, "", {
		font = T.font.title,
		size = T.text.lg,
		color = T.color.text,
		pos = UDim2.fromOffset(22, 16),
		frameSize = UDim2.new(0.6, 0, 0, 24),
	})
	subtitleLabel = UI.label(frame, "", {
		size = T.text.xs,
		color = T.color.textDim,
		pos = UDim2.fromOffset(22, 42),
		frameSize = UDim2.new(0.8, 0, 0, 14),
	})

	--: The close button is the catalogue's `action.close` glyph when the
	--: pack carries it, and the multiplication sign when it does not --
	--: either way a 30px square instead of a word competing with the title.
	local close = UI.button(frame, "", {
		name = "Close",
		size = UDim2.fromOffset(30, 30),
		pos = UDim2.new(1, -44, 0, 14),
		color = T.color.panelAlt,
		onClick = function()
			audio.sfx("ui.click")
			Panels.close()
		end,
	})
	if not Skin.icon(close, "action.close", {
		size = UDim2.fromOffset(14, 14),
		pos = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	}) then
		close.Text = "\u{00D7}"
		close.TextSize = T.text.md
	end

	Skin.divider(frame, 100)

	tabRow = Instance.new("Frame")
	tabRow.Name = "Tabs"
	tabRow.BackgroundTransparency = 1
	tabRow.Size = UDim2.new(1, -44, 0, 28)
	tabRow.Position = UDim2.fromOffset(22, 66)
	tabRow.Parent = frame
	UI.list(tabRow, { horizontal = true, gap = 6 })
	for _, tab in TAB_LIST do
		local button = UI.button(tabRow, tab.label, {
			name = tab.id,
			size = UDim2.fromOffset(108, 26),
			color = T.color.panelAlt,
			onClick = function()
				audio.sfx("ui.click")
				Panels.open(tab.id)
			end,
		})
		button.TextSize = T.text.xs
	end

	content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.Size = UDim2.new(1, -44, 1, -140)
	content.Position = UDim2.fromOffset(22, 106)
	content.ScrollBarThickness = 6
	content.ScrollBarImageColor3 = T.color.stroke
	content.CanvasSize = UDim2.new(0, 0, 0, 0)
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.Parent = frame
	UI.list(content, { gap = 8 })

	state.changed:Connect(Panels.refresh)

	Net.on("QuestSync", function(payload: any)
		questPayload = payload
		if current == "quests" then
			buildQuests()
		end
	end)

	Net.on("BoardSync", function(payload: any)
		boardCache[payload.board] = payload
		if current == "ranks" and (payload.board == boardTab) then
			buildRanks()
		end
	end)

	return gui
end

return Panels
