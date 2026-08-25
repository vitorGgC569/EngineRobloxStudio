--!strict
--[[
	PlotAllocator — one plot per player, lowest free index first.

	The multiplayer tycoon contract: a player owns at most one plot, a
	plot has at most one owner, and leaving releases it. Pure bookkeeping;
	the server maps plot ids to physical rigs.
]]

local PlotAllocator = {}

type Self = {
	plotIds: { string },
	owners: { [string]: string },
	plots: { [string]: string },
	order: { [string]: number },
}

PlotAllocator.__index = PlotAllocator

function PlotAllocator.new(plotIds: { string }): Self
	assert(#plotIds > 0, "PlotAllocator needs plots")
	local order: { [string]: number } = {}
	for index, id in plotIds do
		assert(not order[id], ("duplicate plot %q"):format(id))
		order[id] = index
	end
	return setmetatable({
		plotIds = table.clone(plotIds),
		owners = {},
		plots = {},
		order = order,
	}, PlotAllocator)
end

function PlotAllocator.assign(self: Self, playerKey: string): string?
	if self.owners[playerKey] then
		return nil
	end
	local bestId: string? = nil
	local bestIndex = math.huge
	for _, id in self.plotIds do
		if not self.plots[id] and self.order[id] < bestIndex then
			bestIndex = self.order[id]
			bestId = id
		end
	end
	if not bestId then
		return nil
	end
	self.plots[bestId] = playerKey
	self.owners[playerKey] = bestId
	return bestId
end

function PlotAllocator.release(self: Self, playerKey: string): string?
	local plotId = self.owners[playerKey]
	if not plotId then
		return nil
	end
	self.owners[playerKey] = nil
	self.plots[plotId] = nil
	return plotId
end

function PlotAllocator.plotOf(self: Self, playerKey: string): string?
	return self.owners[playerKey]
end

function PlotAllocator.ownerOf(self: Self, plotId: string): string?
	return self.plots[plotId]
end

function PlotAllocator.isOwner(self: Self, playerKey: string, plotId: string): boolean
	return self.owners[playerKey] == plotId and plotId ~= nil
end

return PlotAllocator
