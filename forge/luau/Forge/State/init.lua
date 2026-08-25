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

return State
