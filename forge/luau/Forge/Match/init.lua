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

return {
	RoundMachine = require(script.Parent.RoundMachine),
	Queue = require(script.Parent.Queue),
	CardCycle = require(script.Parent.CardCycle),
	DeployZone = require(script.Parent.DeployZone),
	WinResolver = require(script.Parent.WinResolver),
	ArenaLayout = require(script.Parent.ArenaLayout),
}
