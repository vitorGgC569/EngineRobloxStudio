--!strict
--[[
	Tycoon — build-and-earn game primitives.

	Pure planning and bookkeeping for tycoon gameplay: grid placement
	math shared by client ghost and server validation, dropper throughput
	caps, live-item ledgers, layout persistence and plot allocation.

	The server owns the planner; clients render ghosts from the same plan.
]]

return {
	GridPlacement = require(script.Parent.GridPlacement),
	DropperChain = require(script.Parent.DropperChain),
	ThroughputLedger = require(script.Parent.ThroughputLedger),
	BlueprintSerializer = require(script.Parent.BlueprintSerializer),
	PlotAllocator = require(script.Parent.PlotAllocator),
}
