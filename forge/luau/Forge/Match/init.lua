--!strict
--[[
	Match — competitive match primitives for Forge games.

	Everything a round-based game needs before gameplay starts and after
	it ends, as pure modules: the phase clock (RoundMachine), the waiting
	list (Queue), deterministic card rotation (CardCycle), authoritative
	placement regions (DeployZone), the end-of-match cascade (WinResolver)
	and declarative arena geometry (ArenaLayout).

	None of these touch Players or Workspace; the server wires effects.
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

local _Match = {
	RoundMachine = require(script.RoundMachine),
	Queue = require(script.Queue),
	CardCycle = require(script.CardCycle),
	DeployZone = require(script.DeployZone),
	WinResolver = require(script.WinResolver),
	ArenaLayout = require(script.ArenaLayout),
}

return setmetatable(_Match, {
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
