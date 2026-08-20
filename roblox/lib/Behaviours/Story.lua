--!strict
--- People to talk to, and reasons to go somewhere.
---
--- An RPG is a world plus a reason to cross it, and the reason arrives through
--- somebody who wants something. Dialogue and quests are the same machine seen
--- from two ends: a conversation changes what a player knows, a quest changes
--- what they are doing, and both are state that has to survive them walking
--- away and coming back.
---
--- **A conversation is a graph, not a script.** A line, some replies, and where
--- each reply goes. Anything more elaborate -- conditions on replies, state
--- changes, one-time lines -- is a property of a node rather than a new system.
---
--- **Nothing here draws anything.** Dialogue sets attributes and fires signals;
--- what a screen does with them is the screen's business, and a game with no
--- screen still records that the conversation happened. That separation is why
--- this can be tested without a client.

local Players = game:GetService("Players")

local Core = require(script.Parent.Parent.Core)
local Events, Actions = Core.Events, Core.Actions
local Trove, Timer, Signal = Core.Trove, Core.Timer, Core.Signal

local Story = {}

export type Reply = {
	text: string,
	--- Where this reply goes. Absent ends the conversation.
	goto_: string?,
	--- Only offered when this returns true.
	when: ((Player) -> boolean)?,
	--- Runs when chosen, before moving on.
	does: ((Player) -> ())?,
}

export type Node = {
	says: string,
	replies: { Reply }?,
	--- Runs on arrival. Give an item, start a quest, remember a meeting.
	onEnter: ((Player) -> ())?,
	--- Said once, then never again.
	once: boolean?,
}

--- Talk to somebody.
---
--- `nodes` is the graph, `start` the first line. The handle exposes `advance`
--- so a screen, a keyboard shortcut or a test can drive it identically.
function Story.conversation(part: BasePart, nodes: { [string]: Node },
	options: { [string]: any }?)

	local opts = options or {}
	local trove = Trove.new()
	local began, said, ended = Signal.new("talk.began"), Signal.new("talk.said"),
		Signal.new("talk.ended")
	for _, signal in ipairs({ began, said, ended }) do
		trove:add(signal)
	end

	local start = tostring(opts.start or "start")
	if nodes[start] == nil then
		local names = {}
		for name in pairs(nodes) do
			table.insert(names, name)
		end
		table.sort(names)
		error(("no node %q to start at; have %s"):format(start, table.concat(names, ", ")), 2)
	end

	--- Where each player is in the graph. Per player, because two people can
	--- be mid-conversation with the same character at once and a single
	--- "current node" would put words in one of their mouths.
	local at: { [Player]: string } = {}
	local heard: { [Player]: { [string]: boolean } } = {}

	local function offered(player: Player, node: Node): { Reply }
		local out = {}
		for _, reply in ipairs(node.replies or {}) do
			if reply.when == nil or reply.when(player) then
				table.insert(out, reply)
			end
		end
		return out
	end

	local function publish(player: Player, key: string, node: Node)
		local lines = {}
		for index, reply in ipairs(offered(player, node)) do
			lines[index] = reply.text
		end
		-- Attributes rather than a RemoteEvent: they replicate to that player
		-- for free, a bound HUD follows them, and a headless test can read them.
		Actions.set(player, "TalkingTo", part.Name)
		Actions.set(player, "TalkNode", key)
		Actions.set(player, "TalkSays", node.says)
		Actions.set(player, "TalkReplies", table.concat(lines, "|"))
		said:fire(player, key, node.says, lines)
	end

	local function enter(player: Player, key: string)
		local node = nodes[key]
		if node == nil then
			warn("[Story] no node " .. key)
			return
		end
		local memory = heard[player]
		if memory == nil then
			memory = {}
			heard[player] = memory
		end
		if node.once and memory[key] then
			-- A line marked `once` that has been heard is skipped rather than
			-- repeated: an NPC who greets you as a stranger every time is the
			-- clearest tell that nothing is remembered.
			local replies = offered(player, node)
			if #replies > 0 and replies[1].goto_ ~= nil then
				enter(player, replies[1].goto_ :: string)
				return
			end
		end
		memory[key] = true
		at[player] = key
		if node.onEnter ~= nil then
			local ok, err = pcall(node.onEnter, player)
			if not ok then
				warn("[Story] onEnter " .. key .. ": " .. tostring(err))
			end
		end
		publish(player, key, node)
	end

	local function finish(player: Player)
		at[player] = nil
		Actions.set(player, "TalkingTo", nil)
		Actions.set(player, "TalkNode", nil)
		Actions.set(player, "TalkSays", nil)
		Actions.set(player, "TalkReplies", nil)
		ended:fire(player)
	end

	--- Choose a reply by its position in what was offered.
	local function advance(player: Player, choice: number): boolean
		local key = at[player]
		if key == nil then
			return false
		end
		local replies = offered(player, nodes[key])
		local reply = replies[choice]
		if reply == nil then
			finish(player)
			return false
		end
		if reply.does ~= nil then
			pcall(reply.does, player)
		end
		if reply.goto_ == nil then
			finish(player)
			return true
		end
		enter(player, reply.goto_)
		return true
	end

	trove:add(Events.onPrompt(part, function(player)
		if at[player] ~= nil then
			-- Talking to somebody you are already talking to advances the
			-- conversation, which is what pressing the button again means.
			advance(player, 1)
			return
		end
		began:fire(player)
		enter(player, start)
	end, {
		label = opts.label or part.Name,
		action = opts.action or "Talk",
		range = tonumber(opts.range) or 12,
	}))

	trove:add(Events.onPlayerLeft(function(player)
		at[player] = nil
		heard[player] = nil
	end))

	return {
		began = began, said = said, ended = ended,
		advance = advance,
		talkTo = function(player: Player) enter(player, start) end,
		nodeFor = function(player: Player): string? return at[player] end,
		destroy = function() trove:clean() end,
	}
end

-- -- quests ---------------------------------------------------------------------

export type Step = {
	id: string,
	text: string,
	count: number?,
}

--- A quest: steps, progress per player, and a reward.
---
--- Progress lives in attributes so it replicates, survives a screen that does
--- not exist yet, and can be saved with everything else.
function Story.quest(id: string, steps: { Step }, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local started, advanced, completed =
		Signal.new("quest.started"), Signal.new("quest.advanced"), Signal.new("quest.completed")
	for _, signal in ipairs({ started, advanced, completed }) do
		trove:add(signal)
	end

	local function key(step: string): string
		return ("Quest_%s_%s"):format(id, step)
	end

	local function isActive(player: Player): boolean
		return Actions.get(player, "Quest_" .. id, "none") == "active"
	end

	local function give(player: Player)
		if Actions.get(player, "Quest_" .. id, "none") ~= "none" then
			return false
		end
		Actions.set(player, "Quest_" .. id, "active")
		for _, step in ipairs(steps) do
			Actions.set(player, key(step.id), 0)
		end
		started:fire(player)
		Actions.notify(player, opts.startMessage or ("New quest: " .. (opts.title or id)))
		return true
	end

	local function progress(player: Player, stepId: string, by: number?): boolean
		if not isActive(player) then
			return false
		end
		local step
		for _, candidate in ipairs(steps) do
			if candidate.id == stepId then
				step = candidate
			end
		end
		if step == nil then
			warn(("[Story] quest %s has no step %s"):format(id, stepId))
			return false
		end

		local target = step.count or 1
		local now = math.min((Actions.get(player, key(stepId), 0) :: number) + (by or 1), target)
		Actions.set(player, key(stepId), now)
		advanced:fire(player, stepId, now, target)

		for _, candidate in ipairs(steps) do
			if (Actions.get(player, key(candidate.id), 0) :: number) < (candidate.count or 1) then
				return true
			end
		end

		Actions.set(player, "Quest_" .. id, "done")
		if opts.reward ~= nil then
			pcall(opts.reward, player)
		end
		completed:fire(player)
		Actions.notify(player, opts.doneMessage or ("Completed: " .. (opts.title or id)))
		return true
	end

	return {
		id = id,
		started = started, advanced = advanced, completed = completed,
		give = give,
		progress = progress,
		isActive = isActive,
		isDone = function(player: Player): boolean
			return Actions.get(player, "Quest_" .. id, "none") == "done"
		end,
		summary = function(player: Player): { string }
			local out = {}
			for _, step in ipairs(steps) do
				local target = step.count or 1
				local now = Actions.get(player, key(step.id), 0) :: number
				table.insert(out, ("%s (%d/%d)"):format(step.text, now, target))
			end
			return out
		end,
		destroy = function() trove:clean() end,
	}
end

--- A character who stands somewhere, says things, and hands out work.
---
--- Ties the pieces together: a body, a name over its head, a conversation, and
--- an idle animation so it does not read as furniture.
function Story.npc(model: Model, nodes: { [string]: Node }, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()

	local anchor = model.PrimaryPart
		or model:FindFirstChild("HumanoidRootPart")
		or model:FindFirstChildWhichIsA("BasePart")
	if anchor == nil then
		error(model.Name .. " has no part to talk from", 2)
	end

	local WorldKit = require(script.Parent.Parent.WorldKit)
	if opts.label ~= false then
		pcall(function()
			WorldKit.Interact.label(anchor, {
				text = opts.name or model.Name,
				size = 1.6,
				maxDistance = 80,
			})
		end)
	end

	-- Standing perfectly still is what makes an NPC read as scenery.
	local GameKit = require(script.Parent.Parent.GameKit)
	pcall(function()
		GameKit.Motion.play(model, { gait = opts.gait or "idle", rate = 0.7 })
	end)
	trove:add(function()
		pcall(GameKit.Motion.stop, model)
	end)

	local talk = Story.conversation(anchor, nodes, {
		label = opts.name or model.Name,
		action = opts.action or "Talk",
		start = opts.start,
		range = opts.range,
	})
	trove:add(talk)

	return {
		talk = talk,
		model = model,
		destroy = function() trove:clean() end,
	}
end

return Story
