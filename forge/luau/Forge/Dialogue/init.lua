--!strict
--[[
	Dialogue — conversation as a graph of data.

		Dialogue.define("elder", {
			start = "greet",
			nodes = {
				greet = {
					text = "You still breathe. That is more than I expected.",
					choices = {
						{ text = "Any work for me?", goto = "work" },
						{ text = "What happened here?", goto = "lore",
						  condition = function(ctx) return ctx.trust > 2 end },
						{ text = "Later.", action = "close" },
					},
				},
				work = { text = "...", action = "quests" },
			},
		})

		local node = Dialogue.begin("player:1", "elder")
		node = Dialogue.choose("player:1", 2)

	Conditions gate choices, so a line that should not exist yet simply is not
	offered — rather than being offered and then refused, which reads as a bug
	to a player. Actions are names, not functions: the game registers what
	`"quests"` or `"shop"` means once, and every NPC reuses it.
]]

local Events = require(script.Parent.Events)

local Dialogue = {}

type Choice = {
	text: string,
	goto: string?,
	action: string?,
	condition: ((ctx: any) -> boolean)?,
	once: boolean?,
	[string]: any,
}

type Node = {
	text: string,
	choices: { Choice }?,
	action: string?,
	onEnter: ((ctx: any) -> ())?,
	[string]: any,
}

type Tree = {
	start: string,
	nodes: { [string]: Node },
	[string]: any,
}

local trees: { [string]: Tree } = {}
local actions: { [string]: (ctx: any) -> any } = {}
local sessions: { [string]: any } = {}

function Dialogue.define(id: string, tree: Tree)
	assert(type(tree.nodes) == "table", "[Dialogue] tree needs nodes")
	tree.start = tree.start or "start"
	assert(tree.nodes[tree.start], string.format("[Dialogue] '%s' has no start node '%s'", id, tree.start))

	-- A goto pointing at a node that does not exist is a dead end the player
	-- discovers instead of you. Check it once, at definition time.
	for nodeId, node in tree.nodes do
		for _, choice in (node.choices or {}) do
			if choice.goto and not tree.nodes[choice.goto] then
				warn(string.format("[Dialogue] '%s'.%s points at missing node '%s'", id, nodeId, choice.goto))
			end
		end
	end

	trees[id] = tree
end

function Dialogue.defineMany(table_: { [string]: Tree })
	for id, tree in table_ do
		Dialogue.define(id, tree)
	end
end

-- The game teaches Forge what an action name means, once.
function Dialogue.action(name: string, fn: (ctx: any) -> any)
	actions[name] = fn
end

function Dialogue.get(id: string): Tree?
	return trees[id]
end

-- ================================ sessions ==================================
local function present(subject: string, treeId: string, nodeId: string): any
	local tree = trees[treeId]
	local node = tree.nodes[nodeId]
	if not node then
		return nil
	end

	local session = sessions[subject]
	local ctx = session and session.context or {}
	ctx.subject = subject
	ctx.tree = treeId
	ctx.node = nodeId

	if node.onEnter then
		pcall(node.onEnter, ctx)
	end

	local offered = {}
	for index, choice in (node.choices or {}) do
		local visible = true
		if choice.condition then
			local ok, result = pcall(choice.condition, ctx)
			visible = ok and result == true
		end
		if visible and choice.once and session and session.taken[treeId .. ":" .. nodeId .. ":" .. index] then
			visible = false
		end
		if visible then
			table.insert(offered, { index = index, text = choice.text, action = choice.action })
		end
	end

	if session then
		session.node = nodeId
		session.offered = offered
	end

	local payload = {
		tree = treeId,
		node = nodeId,
		text = node.text,
		choices = offered,
		action = node.action,
	}

	-- A node may act on entry (a shop that opens immediately, for instance).
	if node.action and actions[node.action] then
		payload.actionResult = actions[node.action](ctx)
	end

	Events.emit("dialogue.node", { subject = subject, tree = treeId, node = nodeId })
	return payload
end

function Dialogue.begin(subject: string, treeId: string, context: any?): any
	local tree = trees[treeId]
	if not tree then
		warn(string.format("[Dialogue] no tree named '%s'", treeId))
		return nil
	end
	local previous = sessions[subject]
	sessions[subject] = {
		tree = treeId,
		node = tree.start,
		context = context or {},
		taken = previous and previous.tree == treeId and previous.taken or {},
	}
	Events.emit("dialogue.started", { subject = subject, tree = treeId })
	return present(subject, treeId, tree.start)
end

--[[
	`index` is the index the client was *shown*, taken from the offered list —
	not the raw index in the definition. A client that sends a raw index could
	otherwise pick a choice its own conditions hid, which is a trivial exploit
	in every dialogue system that forgets it.
]]
function Dialogue.choose(subject: string, index: number): any
	local session = sessions[subject]
	if not session then
		return nil
	end
	local offered = session.offered or {}
	local chosen = offered[index]
	if not chosen then
		Events.emit("dialogue.invalid", { subject = subject, tree = session.tree, index = index })
		return nil
	end

	local tree = trees[session.tree]
	local node = tree.nodes[session.node]
	local choice = (node.choices or {})[chosen.index]
	if not choice then
		return nil
	end

	session.taken[session.tree .. ":" .. session.node .. ":" .. chosen.index] = true

	Events.emit("dialogue.choice", {
		subject = subject,
		tree = session.tree,
		node = session.node,
		choice = choice.text,
		action = choice.action,
	})

	if choice.action == "close" then
		Dialogue.finish(subject)
		return nil
	end

	if choice.action and actions[choice.action] then
		local ctx = session.context
		ctx.subject = subject
		ctx.tree = session.tree
		ctx.choice = choice
		local result = actions[choice.action](ctx)
		if choice.goto then
			local payload = present(subject, session.tree, choice.goto)
			if payload then
				payload.actionResult = result
			end
			return payload
		end
		return { tree = session.tree, node = session.node, action = choice.action, actionResult = result }
	end

	if choice.goto then
		return present(subject, session.tree, choice.goto)
	end

	Dialogue.finish(subject)
	return nil
end

function Dialogue.current(subject: string): any
	local session = sessions[subject]
	if not session then
		return nil
	end
	return { tree = session.tree, node = session.node, choices = session.offered }
end

function Dialogue.finish(subject: string)
	local session = sessions[subject]
	if session then
		Events.emit("dialogue.ended", { subject = subject, tree = session.tree })
		sessions[subject] = nil
	end
end

function Dialogue.describe(): { [string]: any }
	local treeIds, nodeTotal = {}, 0
	for id, tree in trees do
		table.insert(treeIds, id)
		for _ in tree.nodes do
			nodeTotal += 1
		end
	end
	table.sort(treeIds)

	local actionNames = {}
	for name in actions do
		table.insert(actionNames, name)
	end
	table.sort(actionNames)

	local open = 0
	for _ in sessions do
		open += 1
	end

	return { trees = treeIds, nodes = nodeTotal, actions = actionNames, openSessions = open }
end

return Dialogue
