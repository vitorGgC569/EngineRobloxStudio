--!strict
--[[
	BehaviorTree — minimal SEQUENCE / FALLBACK tree with RUNNING status.

	Three combinators cover most NPC logic: all-children-succeed
	(SEQUENCE), first-success (FALLBACK), and leaf actions that may keep
	running across ticks. Statuses are numeric (-1 fail, 0 running,
	1 success) exactly like the tiny production trees.
]]

local BehaviorTree = {}

export type Status = number -- -1 FAILURE | 0 RUNNING | 1 SUCCESS

export type LeafContext = {
	blackboard: { [string]: any },
	dt: number,
}

export type Node = ((ctx: LeafContext) -> Status) | { children: { Node } }

BehaviorTree.FAILURE = -1
BehaviorTree.RUNNING = 0
BehaviorTree.SUCCESS = 1

function BehaviorTree.action(run: (ctx: LeafContext) -> Status): Node
	return run
end

-- Succeeds when every child succeeds; running propagates; any failure stops.
function BehaviorTree.sequence(children: { Node }): Node
	return function(ctx: LeafContext): Status
		for _, child in children do
			local status = (child :: any)(ctx)
			if status ~= BehaviorTree.SUCCESS then
				return status
			end
		end
		return BehaviorTree.SUCCESS
	end
end

-- Succeeds at the first success; fails only when every child failed.
function BehaviorTree.fallback(children: { Node }): Node
	return function(ctx: LeafContext): Status
		for _, child in children do
			local status = (child :: any)(ctx)
			if status == BehaviorTree.RUNNING then
				return BehaviorTree.RUNNING
			elseif status == BehaviorTree.SUCCESS then
				return BehaviorTree.SUCCESS
			end
		end
		return BehaviorTree.FAILURE
	end
end

-- Inverts a leaf's result; running stays running.
function BehaviorTree.invert(child: Node): Node
	return function(ctx: LeafContext): Status
		local status = (child :: any)(ctx)
		if status == BehaviorTree.SUCCESS then
			return BehaviorTree.FAILURE
		elseif status == BehaviorTree.FAILURE then
			return BehaviorTree.SUCCESS
		end
		return status
	end
end

function BehaviorTree.run(root: Node, blackboard: { [string]: any }, dt: number): Status
	return (root :: any)({ blackboard = blackboard, dt = dt })
end

return BehaviorTree
