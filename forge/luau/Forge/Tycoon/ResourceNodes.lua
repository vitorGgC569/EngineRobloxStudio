--!strict
--[[
	ResourceNodes — depleting resource nodes with replenish timers.

	Ore veins, trees, fishing spots: harvest N times then go dormant and
	replenish after a period. Ownership-free; the ledger is keyed by node
	id and safe to persist.
]]

local ResourceNodes = {}

type Node = {
	id: string,
	harvestsRemaining: number,
	maxHarvests: number,
	replenishSeconds: number,
	availableAt: number,
}

type Self = {
	nodes: { [string]: Node },
	clock: () -> number,
}

ResourceNodes.__index = ResourceNodes

function ResourceNodes.new(clock: (() -> number)?): Self
	return setmetatable({ nodes = {}, clock = clock or os.time }, ResourceNodes)
end

function ResourceNodes.define(self: Self, id: string, maxHarvests: number, replenishSeconds: number): ()
	assert(type(id) == "string" and #id > 0, "id must be a non-empty string")
	assert(not self.nodes[id], ("duplicate node %q"):format(id))
	assert(maxHarvests >= 1 and replenishSeconds >= 0)
	self.nodes[id] = { id = id, harvestsRemaining = maxHarvests, maxHarvests = maxHarvests, replenishSeconds = replenishSeconds, availableAt = 0 }
end

function ResourceNodes.harvest(self: Self, id: string): (boolean, string?)
	local node = self.nodes[id]
	if not node then
		return false, "unknown_node"
	end
	if node.harvestsRemaining <= 0 and self.clock() < node.availableAt then
		return false, "depleted"
	end
	if node.harvestsRemaining <= 0 then
		node.harvestsRemaining = node.maxHarvests
	end
	node.harvestsRemaining -= 1
	if node.harvestsRemaining <= 0 then
		node.availableAt = self.clock() + node.replenishSeconds
	end
	return true, nil
end

function ResourceNodes.isAvailable(self: Self, id: string): boolean
	local node = self.nodes[id]
	if not node then
		return false
	end
	if node.harvestsRemaining > 0 then
		return true
	end
	return self.clock() >= node.availableAt
end

return ResourceNodes
