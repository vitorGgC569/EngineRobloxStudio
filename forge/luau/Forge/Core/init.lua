--!strict
-- Core — primitives with no Roblox opinions in them.
-- Everything here is testable without a DataModel, which is why it is separate.

local Core = {}

Core.Signal = require(script.Signal)
Core.Trove = require(script.Trove)
Core.Spring = require(script.Spring)
Core.Ease = require(script.Ease)
Core.Rng = require(script.Rng)
Core.Sched = require(script.Sched)

return Core
