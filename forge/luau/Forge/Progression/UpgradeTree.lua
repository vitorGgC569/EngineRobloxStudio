--!strict
--[[
	UpgradeTree — a pure DAG of repeatable upgrades behind prerequisite gates.

	Mined from bocchi-upgrade-tree: buttons stay hidden until every root is
	owned (ButtonController.IsVisible) and cost a curve of the next level
	(Info.Cost(nextAmount)). Here the tree is data, not Instances, so tests
	and save files need nothing but tables.

		local tree = UpgradeTree.new({
			nodes = {
				B1 = { cost = function(level) return 10 ^ level end, maxLevel = 5 },
				B2 = { roots = { "B1" }, cost = function(level) return 50 * level end },
			},
		})

		tree:canBuy(state, "B2", balance)          -- false, "hidden"
		local delta = tree:buy(state, "B2")        -- { id = "B2", level = 1 } or nil
		state = UpgradeTree.apply(state, delta)

	Design note: `buy` is PURE. It never mutates `state` and never sees the
	wallet; it returns a delta `{ id, level }` (nil when structurally blocked)
	and affordability stays the caller's job via `canBuy`. Apply the delta
	with `apply` for an immutable new state, or assign it yourself for speed.
]]

local UpgradeTree = {}
UpgradeTree.__index = UpgradeTree

export type CostCurve = (level: number) -> number

export type NodeSpec = {
	cost: CostCurve?,
	maxLevel: number?,
	roots: { string }?,
}

export type Node = {
	cost: CostCurve,
	maxLevel: number,
	roots: { string },
}

export type State = { [string]: number }

export type Delta = {
	id: string,
	level: number,
}

type Internal = {
	nodes: { [string]: Node },
}

export type Tree = typeof(setmetatable({} :: Internal, UpgradeTree))

local DEFAULT_MAX_LEVEL = 1

local function resolveNode(spec: NodeSpec): Node
	return {
		cost = spec.cost or function(_level: number)
			return 0
		end,
		maxLevel = spec.maxLevel or DEFAULT_MAX_LEVEL,
		roots = spec.roots or {},
	}
end

local function assertAcyclic(nodes: { [string]: Node })
	local VISITING, DONE = 1, 2
	local marks: { [string]: number } = {}

	local function visit(id: string, trail: { string })
		if marks[id] == DONE then
			return
		end
		assert(marks[id] ~= VISITING, string.format("[UpgradeTree] cycle through '%s': %s", id, table.concat(trail, " -> ")))
		marks[id] = VISITING
		table.insert(trail, id)
		for _, root in nodes[id].roots do
			visit(root, trail)
		end
		table.remove(trail)
		marks[id] = DONE
	end

	for id in pairs(nodes) do
		visit(id, {})
	end
end

function UpgradeTree.new(config: {
	nodes: { [string]: NodeSpec },
}): Tree
	local self: Internal = setmetatable({}, UpgradeTree)
	self.nodes = {}

	for id, spec in pairs(config.nodes) do
		assert(self.nodes[id] == nil, string.format("[UpgradeTree] duplicate node '%s'", id))
		self.nodes[id] = resolveNode(spec)
	end

	for id, node in pairs(self.nodes) do
		for _, root in node.roots do
			assert(self.nodes[root] ~= nil, string.format("[UpgradeTree] node '%s' roots unknown node '%s'", id, root))
		end
	end

	assertAcyclic(self.nodes)
	return self :: any
end

function UpgradeTree.levelOf(self: Tree, state: State, id: string): number
	assert(self.nodes[id], string.format("[UpgradeTree] unknown node '%s'", id))
	return state[id] or 0
end

function UpgradeTree.cost(self: Tree, state: State, id: string): number
	local node = self.nodes[id]
	assert(node, string.format("[UpgradeTree] unknown node '%s'", id))
	return node.cost((state[id] or 0) + 1)
end

function UpgradeTree.visible(self: Tree, state: State, id: string): boolean
	local node = self.nodes[id]
	assert(node, string.format("[UpgradeTree] unknown node '%s'", id))
	for _, root in node.roots do
		if (state[root] or 0) < 1 then
			return false
		end
	end
	return true
end

function UpgradeTree.canBuy(self: Tree, state: State, id: string, balance: number): (boolean, string?)
	local node = self.nodes[id]
	assert(node, string.format("[UpgradeTree] unknown node '%s'", id))
	if not self:visible(state, id) then
		return false, "hidden"
	end
	local level = state[id] or 0
	if level >= node.maxLevel then
		return false, "maxed"
	end
	if balance < node.cost(level + 1) then
		return false, "cost"
	end
	return true, nil
end

function UpgradeTree.buy(self: Tree, state: State, id: string): Delta?
	local node = self.nodes[id]
	assert(node, string.format("[UpgradeTree] unknown node '%s'", id))
	if not self:visible(state, id) then
		return nil
	end
	local level = state[id] or 0
	if level >= node.maxLevel then
		return nil
	end
	return { id = id, level = level + 1 }
end

function UpgradeTree.apply(state: State, delta: Delta): State
	local nextState = {}
	for id, level in pairs(state) do
		nextState[id] = level
	end
	nextState[delta.id] = delta.level
	return nextState
end

function UpgradeTree.levelsOf(self: Tree, state: State): State
	local levels = {}
	for id in pairs(self.nodes) do
		levels[id] = state[id] or 0
	end
	return levels
end

return UpgradeTree
