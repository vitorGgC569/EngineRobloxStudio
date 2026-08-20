--!strict
--[[
	Keeper — the only other person on the shelf.

	Selling, quests and conversation, all through Forge modules that know
	nothing about each other. `Dialogue` calls an action by name; this file is
	where the name gets its meaning.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Assets = Forge.Assets
local Dialogue = Forge.Dialogue
local Nav = Forge.Nav
local Events = Forge.Events
local Interaction = Forge.Interaction
local Inventory = Forge.Inventory
local Net = Forge.Net
local Progression = Forge.Progression
local Quest = Forge.Quest
local Debug = Forge.Debug

local Shore = require(script.Parent.Shore)

local Keeper = {}

local function subjectOf(player: Player): string
	return "player:" .. player.UserId
end

local function playerFor(subject: string): Player?
	local userId = tonumber(string.match(subject, "player:(%d+)"))
	if not userId then
		return nil
	end
	for _, player in Players:GetPlayers() do
		if player.UserId == userId then
			return player
		end
	end
	return nil
end

-- ============================== the actions =================================
-- Dialogue says "sell"; this decides what selling is.
local function registerActions()
	Dialogue.action("sell", function(ctx)
		local player = playerFor(ctx.subject)
		if not player then
			return nil
		end
		local bag = Inventory.get(ctx.subject)
		if not bag then
			return nil
		end

		local earned, sold = 0, 0
		for _, entry in Inventory.list(bag) do
			local definition = Inventory.itemDef(entry.id)
			if definition and definition.value then
				earned += definition.value * entry.count
				sold += entry.count
				Inventory.remove(bag, entry.id, entry.count)
			end
		end

		if sold == 0 then
			Net.fire(player, "Notify", { text = "Your satchel is empty." })
			return { sold = 0 }
		end

		Inventory.addCurrency(bag, "coin", earned)
		Events.emit("keeper.sold", { subject = ctx.subject, amount = earned, items = sold })
		Net.fire(player, "Notify", {
			text = string.format("Sold %d pieces for %d coin.", sold, earned),
			color = Color3.fromRGB(238, 202, 128),
		})
		Keeper.sync(player)
		Debug.count("keeper.sold", earned)
		return { sold = sold, earned = earned }
	end)

	Dialogue.action("quests", function(ctx)
		local player = playerFor(ctx.subject)
		if not player then
			return nil
		end

		-- Hand in anything finished before offering anything new: a player who
		-- walks up with a completed quest should not have to ask twice.
		local turnedIn = {}
		for _, entry in Quest.journal(ctx.subject) do
			if entry.fulfilled then
				local ok, rewards = Quest.complete(ctx.subject, entry.id)
				if ok and rewards then
					Keeper.grant(player, rewards)
					table.insert(turnedIn, entry.name)
				end
			end
		end

		local offers = {}
		for _, questId in Quest.availableFor(ctx.subject, "keeper") do
			local definition = Quest.get(questId)
			table.insert(offers, { id = questId, name = definition.name, summary = definition.summary })
		end

		Net.fire(player, "Quests", {
			turnedIn = turnedIn,
			offers = offers,
			journal = Quest.journal(ctx.subject),
		})
		return { offers = #offers, turnedIn = #turnedIn }
	end)
end

function Keeper.grant(player: Player, rewards: any)
	local subject = subjectOf(player)
	local bag = Inventory.get(subject)

	if rewards.xp then
		Progression.award(Progression.track("reach", subject), rewards.xp)
	end
	if rewards.currency and bag then
		for kind, amount in rewards.currency do
			Inventory.addCurrency(bag, kind, amount)
		end
	end
	if rewards.items and bag then
		for _, entry in rewards.items do
			Inventory.add(bag, entry.id, entry.count)
		end
	end
	Keeper.sync(player)
end

-- ================================== sync ====================================
function Keeper.sync(player: Player)
	local subject = subjectOf(player)
	local bag = Inventory.get(subject)
	local track = Progression.track("reach", subject)
	if not bag then
		return
	end

	Net.fire(player, "StateSync", {
		coin = Inventory.currency(bag, "coin"),
		carried = Inventory.used(bag),
		slots = bag.slots,
		level = track.level,
		progress = Progression.progressFraction(track),
		items = Inventory.list(bag),
		journal = Quest.journal(subject),
	})
end

-- ================================== start ===================================
--[[
	The Keeper walks a round instead of standing still.

	A shopkeeper rooted to one spot is the clearest signal a world is a menu
	with scenery. `Nav` gives this one a patrol over the same navmesh the tide
	shelf already has, and the standoff keeps it from walking into whoever is
	talking to it.

	This is also the second consumer `Nav` needed. Until now it existed only
	for Proving Ground's enemies, which made it that game's chase code with an
	engine address rather than a navigation layer.
]]
local function walkTheRound(model: Model)
	local home = model:GetPivot().Position
	local stops = {
		home,
		home + Vector3.new(18, 0, 6),
		home + Vector3.new(4, 0, 22),
		home + Vector3.new(-14, 0, 10),
	}
	local index = 1

	Nav.follow(model, {
		standoff = 2,
		target = function()
			return stops[index]
		end,
		onArrive = function()
			-- Pause at each stop. A patrol with no dwell reads as pacing.
			task.delay(6, function()
				index = (index % #stops) + 1
			end)
		end,
		parameters = { AgentRadius = 2, AgentHeight = 5, AgentCanJump = false },
	})
end

function Keeper.start()
	registerActions()

	local npcFolder = Workspace:FindFirstChild("Npcs")
	local position = Shore.dock + Vector3.new(6, 0, 4)
	local model = Assets.spawn("Npc.Keeper", CFrame.new(position), npcFolder)

	if model then
		Interaction.register(model, {
			id = "keeper",
			label = "Speak",
			objectLabel = "The Keeper",
			range = 13,
			key = Enum.KeyCode.F,
			onTrigger = function(player)
				local subject = subjectOf(player)
				local track = Progression.track("reach", subject)
				local node = Dialogue.begin(subject, "keeper", { level = track.level })
				if node then
					Net.fire(player, "Dialogue", node)
				end
			end,
		})
	end

	Net.on("DialogueChoice", function(player, payload)
		local node = Dialogue.choose(subjectOf(player), payload.index)
		Net.fire(player, "Dialogue", node or { closed = true })
	end)

	Net.on("AcceptQuest", function(player, payload)
		local subject = subjectOf(player)
		if Quest.accept(subject, payload.quest) then
			local definition = Quest.get(payload.quest)
			Net.fire(player, "Notify", {
				text = "Accepted: " .. definition.name,
				color = Color3.fromRGB(238, 202, 128),
			})
			Keeper.sync(player)
		end
	end)

	-- Progression unlocks and quest completions both want the player told.
	Events.on("progression.levelup", function(payload)
		local player = playerFor(payload.subject)
		if player then
			Net.fire(player, "Notify", {
				text = string.format("The shelf opens further. Level %d.", payload.level),
				color = Color3.fromRGB(150, 220, 255),
			})
			Keeper.sync(player)
		end
	end)

	Events.on("quest.fulfilled", function(payload)
		local player = playerFor(payload.subject)
		if player then
			local definition = Quest.get(payload.quest)
			Net.fire(player, "Notify", {
				text = string.format("%s — ready to hand in.", definition.name),
				color = Color3.fromRGB(150, 220, 170),
			})
		end
	end)

	-- Carrying more should update the satchel readout without the player acting.
	Events.on("inventory.added", function(payload)
		local player = playerFor(payload.subject or "")
		if player then
			Keeper.sync(player)
		end
	end)

	Debug.probe("keeper", function()
		return {
			coinSold = Debug.counter("keeper.sold"),
			dialogueTrees = Dialogue.describe().trees,
		}
	end)

	Debug.info("keeper ready")
end

return Keeper
