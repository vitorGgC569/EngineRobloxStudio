--!strict
--- The standard library: the pieces you reach for every ten lines.
---
--- Everything above this line in the stack — WorldKit, GameKit, the behaviours,
--- the skeletons — is built on these, and so is whatever you write. They are
--- not a framework: nothing here calls your code, decides your structure, or
--- has to be used at all.
---
---     Core.Signal          your own events, without a BindableEvent each
---     Core.Trove           one place to put everything to clean up
---     Core.Timer           delays, intervals, cooldowns, debounce, throttle
---     Core.StateMachine    states, and the rules about moving between them
---     Core.Zone            volumes that know who is inside, correctly
---     Core.Spatial         raycasts, overlaps, nearest, line of sight, paths
---     Core.Pool            reuse instances instead of churning them
---     Core.Curve           easing, progression ladders, seeded randomness
---     Core.Events          everything that can happen, as functions
---     Core.Actions         everything you can do, as functions
---
--- **The rule this library follows:** it saves you time, it never becomes the
--- only way. Every function here is Luau you could have written, and the source
--- is right there to read when you want to write a better one.

local Core = {}

Core.Signal = require(script.Signal)
Core.Trove = require(script.Trove)
Core.Timer = require(script.Timer)
Core.StateMachine = require(script.StateMachine)
Core.Zone = require(script.Zone)
Core.Spatial = require(script.Spatial)
Core.Pool = require(script.Pool)
Core.Curve = require(script.Curve)
Core.Events = require(script.Events)
Core.Actions = require(script.Actions)
Core.Asset = require(script.Asset)

Core.VERSION = "1.0.0"

--- What is in here, for a caller who has not read the source.
function Core.surface(): { [string]: { string } }
	local out: { [string]: { string } } = {}
	for name, module in pairs(Core) do
		if type(module) == "table" then
			local names = {}
			for key, value in pairs(module) do
				if type(value) == "function" and string.sub(key, 1, 1) ~= "_" then
					table.insert(names, key)
				end
			end
			table.sort(names)
			out[name] = names
		end
	end
	return out
end

return Core
