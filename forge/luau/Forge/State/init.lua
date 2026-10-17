--!strict
--[[
	State — the session's own truth, and who is allowed to see it.

	Three layers of state in this engine, and they are different things:

	  `Data`   content. True before anybody joins, never changes at runtime.
	  `Save`   what persists. Survives the server.
	  `State`  the session. Who is in which room, what the score is, whose
	           turn it is — gone when the server is, and the layer that
	           otherwise ends up as private tables in twelve modules that
	           disagree with each other.

	Extracted from a game built entirely on this pattern, where the whole of
	both halves — server and client — is one store, a set of reducers, and a
	middleware that decides what crosses the wire.
]]

local State = {}

State.Store = require(script.Store)
State.Replication = require(script.Replication)

--[[
	Siblings, resolved on the first thing that asks for one.

	One convention for the whole engine, because half the families had this and
	half did not, and in the half that did not a module beside this file was
	reachable only by requiring the instance directly. Two conventions in one
	engine is not a style difference; it is `attempt to index nil` in the first
	game that trusts the wrong one.

	Lazy rather than eager, matching `Forge` itself. Touching one family must
	not drag in every module it contains -- several build tables and open
	connections at load, and paying for all of that to read one constant is how
	a require graph becomes a frame budget.
]]
return setmetatable(State, {
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
