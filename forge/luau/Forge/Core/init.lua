--!strict
--[[
	Core — primitives with no Roblox opinions in them.

	Everything here is testable without a DataModel, which is why it is
	separate. If a module in this folder reaches for a service, it is in the
	wrong folder.

	Every file beside this one is listed below, deliberately by hand. Four of
	them were not, and the omission is invisible until something asks: `Boot`
	sat on disk, compiled, specced and unreachable, and the first game written
	against it died on `attempt to index nil with 'declareMany'`. A folder is
	not an index.
]]

local Core = {}

Core.Signal = require(script.Signal)
Core.Trove = require(script.Trove)
Core.Spring = require(script.Spring)
Core.Ease = require(script.Ease)
Core.Rng = require(script.Rng)
Core.Sched = require(script.Sched)
Core.Boot = require(script.Boot)
Core.Clock = require(script.Clock)
Core.Cvars = require(script.Cvars)
Core.SparseSet = require(script.SparseSet)

return Core
