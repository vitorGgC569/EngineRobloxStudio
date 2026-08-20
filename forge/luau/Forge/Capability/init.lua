--!strict
--[[
	Capability — ask Roblox what exists instead of assuming.

	This module exists because of a specific, expensive afternoon.

	`Sky.install` set `Terrain.Decoration = true`. That property does not exist
	in every Roblox version; on 0.735 it throws. Because `install` is a straight
	run of property writes, that one line aborted everything after it — the
	water never got its reflectance and a warning nobody saw never printed. A
	cosmetic nicety silently took out the rest of the function, and the only
	symptom was that the world looked slightly wrong.

	Then the same shape of bug happened three more times in a row with audio:
	invented marketplace ids, then `rbxasset://` names written from memory. Each
	one compiled, passed the doctor, passed the tests, built cleanly, and failed
	at runtime in front of a person.

	The pattern is always the same. Code written from memory about what the
	platform offers is a guess, and a guess that survives every static check.

	--- What this does -----------------------------------------------------

		Capability.has("Terrain.Decoration")   -- false on this build
		Capability.set(Workspace.Terrain, "Decoration", true)  -- safe either way

	`set` writes the property if it exists and records the miss if it does not.
	Nothing throws, nothing aborts the caller, and `Capability.missing()` lists
	everything this build refused so it can be reported rather than discovered.

	--- Where the answers come from ----------------------------------------

	Probes are cheap and cached: the first question about a property costs one
	pcall, every later one is a table lookup. `forge capability probe` runs the
	same checks from outside and writes them to JSON, so an agent can read what
	this Roblox build supports *before* writing code against it — which is the
	whole point.
]]

local RunService = game:GetService("RunService")

local Capability = {}

local answers: { [string]: boolean } = {}
local misses: { [string]: number } = {}

-- ================================= probing ==================================
--[[
	Does `Class.Property` exist on this build?

	Answered by reading the property off a real instance and catching the
	throw. Roblox exposes no reflection to a normal script, so a read that
	does not error is the only available proof that a name is real.
]]
function Capability.hasProperty(instance: Instance, property: string): boolean
	local key = instance.ClassName .. "." .. property
	local cached = answers[key]
	if cached ~= nil then
		return cached
	end
	local ok = pcall(function()
		return (instance :: any)[property]
	end)
	answers[key] = ok
	return ok
end

--[[
	Can this class be created at all?

	New classes appear and old ones are retired. `Instance.new` on a name this
	build does not know throws, which is a slower answer than a lookup but a
	definitive one.
]]
function Capability.hasClass(className: string): boolean
	local key = "class:" .. className
	local cached = answers[key]
	if cached ~= nil then
		return cached
	end
	local ok, created = pcall(function()
		return Instance.new(className :: any)
	end)
	if ok and created then
		(created :: Instance):Destroy()
	end
	answers[key] = ok
	return ok
end

-- Answer for a key already probed, without needing the instance to hand.
function Capability.has(key: string): boolean
	return answers[key] == true
end

-- ================================= writing ==================================
--[[
	Write a property, or record that this build does not have it.

	The replacement for a bare assignment anywhere the property is optional.
	The important part is not that it avoids the error — it is that the caller
	*continues*, so one missing cosmetic property can no longer take out the
	twenty lines after it.

	Returns whether the write landed, for the callers that care.
]]
function Capability.set(instance: Instance, property: string, value: any): boolean
	local key = instance.ClassName .. "." .. property
	if answers[key] == false then
		misses[key] = (misses[key] or 0) + 1
		return false
	end
	local ok = pcall(function()
		(instance :: any)[property] = value
	end)
	answers[key] = ok
	if not ok then
		misses[key] = (misses[key] or 0) + 1
	end
	return ok
end

--[[
	Read a property, or a fallback.

	The read side of the same problem: `Lighting.Technology` cannot be read by
	a plain script at all, and code that assumed it could spent a while
	reporting nonsense about the lighting model.
]]
function Capability.get(instance: Instance, property: string, fallback: any?): any
	local key = instance.ClassName .. "." .. property
	local ok, value = pcall(function()
		return (instance :: any)[property]
	end)
	answers[key] = ok
	if not ok then
		misses[key] = (misses[key] or 0) + 1
		return fallback
	end
	return value
end

-- ================================== report ==================================
--[[
	Everything this build refused.

	Worth surfacing rather than swallowing: a game silently missing its grass
	because one property vanished in a Roblox update is a bug that hides for
	months. This turns it into a line in the snapshot.
]]
function Capability.missing(): { [string]: number }
	return table.clone(misses)
end

function Capability.known(): { [string]: boolean }
	return table.clone(answers)
end

--[[
	Load answers gathered outside the game.

	`forge capability probe` writes a table of what this Roblox build supports;
	feeding it in here means the first frame already knows, instead of learning
	one pcall at a time.
]]
function Capability.prime(table_: { [string]: boolean })
	for key, value in table_ do
		if answers[key] == nil then
			answers[key] = value
		end
	end
end

function Capability.describe(): { [string]: any }
	local probed, supported = 0, 0
	for _, value in answers do
		probed += 1
		if value then
			supported += 1
		end
	end
	return {
		context = RunService:IsServer() and "server" or "client",
		probed = probed,
		supported = supported,
		missing = Capability.missing(),
	}
end

return Capability
