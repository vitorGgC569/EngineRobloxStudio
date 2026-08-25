--!strict
--[[
	Tycoon — build-and-earn game primitives.

	Pure planning and bookkeeping for tycoon gameplay: grid placement
	math shared by client ghost and server validation, dropper throughput
	caps, live-item ledgers, layout persistence and plot allocation.

	The server owns the planner; clients render ghosts from the same plan.
]]

--[[
	Siblings, and the reference that was wrong.

	These were written `require(script.Parent.X)`. Inside a family's own
	`init.lua`, `script` *is* the family — so `script.Parent` is `Forge`, and
	every one of these was looking for a module one level too high. Requiring
	this family at all would have thrown; nothing did, because every caller so
	far reached past it to the child directly.

	Corrected to `script.X`, and given the same lazy resolver as the rest so a
	module added tomorrow is reachable without editing this list.
]]

local _Tycoon = {
	GridPlacement = require(script.GridPlacement),
	DropperChain = require(script.DropperChain),
	ThroughputLedger = require(script.ThroughputLedger),
	BlueprintSerializer = require(script.BlueprintSerializer),
	PlotAllocator = require(script.PlotAllocator),
}

return setmetatable(_Tycoon, {
	__index = function(self, key: string): any
		local child = script:FindFirstChild(key)
		if not child or not child:IsA("ModuleScript") then
			return nil
		end
		local module = require(child) :: any
		rawset(self, key, module)
		return module
	end,
})
