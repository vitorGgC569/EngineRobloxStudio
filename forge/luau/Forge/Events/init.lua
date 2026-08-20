--!strict
--[[
	Events — the spine everything else listens to.

		Events.emit("enemy.killed", { by = player, kind = "orc", at = position })

		Events.on("enemy.killed", function(payload) ... end)
		Events.onAny(function(name, payload) ... end)

	Why a second event system, when Signal exists
	---------------------------------------------
	Signal connects one producer to its consumers. Events is a *namespace*: the
	combat system emits `enemy.killed` without knowing that quests, achievements,
	analytics, the tutorial and a leaderboard are all listening. That is the
	difference between systems that compose and systems that have to import each
	other.

	It is also what makes objective tracking generic. `Quest` does not know what
	a kill is; it knows how to count events matching a filter. Adding a new
	objective type becomes adding a line of data, not a branch in a tracker.

	Every emission is recorded in a ring buffer, so a playtest can be asked what
	actually happened rather than what was supposed to.
]]

local Signal = require(script.Parent.Core.Signal)

local Events = {}

type Listener = {
	fn: (payload: any, name: string) -> (),
	filter: ((payload: any) -> boolean)?,
	once: boolean?,
	id: number,
}

local listeners: { [string]: { Listener } } = {}
local wildcards: { Listener } = {}
local history: { any } = {}
local counts: { [string]: number } = {}
local nextListenerId = 1
local startedAt = os.clock()

Events.config = {
	historyCapacity = 400,
	recordHistory = true,
	warnOnUnheard = false, -- noisy by default; useful when wiring a new system
}

-- ================================ emitting ==================================
function Events.emit(name: string, payload: any?)
	assert(type(name) == "string", "[Events] event name must be a string")
	local data = payload or {}
	counts[name] = (counts[name] or 0) + 1

	if Events.config.recordHistory then
		table.insert(history, { name = name, t = os.clock() - startedAt, payload = data })
		if #history > Events.config.historyCapacity then
			table.remove(history, 1)
		end
	end

	local heard = false

	local direct = listeners[name]
	if direct then
		-- iterate a copy: a listener may unsubscribe itself, and a `once`
		-- listener always does
		for _, listener in table.clone(direct) do
			if listener.filter and not listener.filter(data) then
				continue
			end
			heard = true
			if listener.once then
				Events.off(name, listener.id)
			end
			local ok, err = pcall(listener.fn, data, name)
			if not ok then
				warn(string.format("[Events] listener for '%s' errored: %s", name, tostring(err)))
			end
		end
	end

	for _, listener in table.clone(wildcards) do
		heard = true
		local ok, err = pcall(listener.fn, data, name)
		if not ok then
			warn(string.format("[Events] wildcard listener errored on '%s': %s", name, tostring(err)))
		end
	end

	if not heard and Events.config.warnOnUnheard then
		warn(string.format("[Events] nothing listens to '%s'", name))
	end
end

-- ================================ listening =================================
local function subscribe(name: string, listener: Listener)
	local list = listeners[name]
	if not list then
		list = {}
		listeners[name] = list
	end
	table.insert(list, listener)
end

--[[
	`filter` narrows without a branch in your handler, which is what lets a
	quest say "orcs only" as data:

		Events.on("enemy.killed", tally, function(p) return p.kind == "orc" end)
]]
function Events.on(name: string, fn: (payload: any, name: string) -> (), filter: ((payload: any) -> boolean)?): number
	local id = nextListenerId
	nextListenerId += 1
	subscribe(name, { fn = fn, filter = filter, id = id })
	return id
end

function Events.once(name: string, fn: (payload: any, name: string) -> (), filter: ((payload: any) -> boolean)?): number
	local id = nextListenerId
	nextListenerId += 1
	subscribe(name, { fn = fn, filter = filter, once = true, id = id })
	return id
end

function Events.onAny(fn: (name: string, payload: any) -> ()): number
	local id = nextListenerId
	nextListenerId += 1
	table.insert(wildcards, {
		fn = function(payload, name)
			fn(name, payload)
		end,
		id = id,
	})
	return id
end

function Events.off(name: string, listenerId: number)
	local list = listeners[name]
	if not list then
		return
	end
	for i = #list, 1, -1 do
		if list[i].id == listenerId then
			table.remove(list, i)
			return
		end
	end
end

function Events.offAny(listenerId: number)
	for i = #wildcards, 1, -1 do
		if wildcards[i].id == listenerId then
			table.remove(wildcards, i)
			return
		end
	end
end

function Events.clear(name: string?)
	if name then
		listeners[name] = nil
	else
		table.clear(listeners)
		table.clear(wildcards)
	end
end

-- ============================== introspection ===============================
function Events.count(name: string): number
	return counts[name] or 0
end

function Events.counts(): { [string]: number }
	return table.clone(counts)
end

function Events.history(limit: number?): { any }
	local n = limit or #history
	local out = {}
	for i = math.max(1, #history - n + 1), #history do
		table.insert(out, history[i])
	end
	return out
end

-- Every event name that has ever fired, plus every name anyone listens for.
-- The difference between the two sets is almost always a bug: a listener
-- waiting on an event nobody emits, or an event nobody hears.
function Events.audit(): { [string]: any }
	local emitted: { [string]: boolean } = {}
	for name in counts do
		emitted[name] = true
	end
	local heard: { [string]: boolean } = {}
	for name, list in listeners do
		if #list > 0 then
			heard[name] = true
		end
	end

	local silent, unheard = {}, {}
	for name in heard do
		if not emitted[name] then
			table.insert(silent, name)
		end
	end
	for name in emitted do
		if not heard[name] and #wildcards == 0 then
			table.insert(unheard, name)
		end
	end
	table.sort(silent)
	table.sort(unheard)

	return { listenedButNeverEmitted = silent, emittedButUnheard = unheard }
end

function Events.reset()
	table.clear(history)
	table.clear(counts)
	startedAt = os.clock()
end

function Events.describe(): { [string]: any }
	local listenerCount = 0
	for _, list in listeners do
		listenerCount += #list
	end
	return {
		listeners = listenerCount,
		wildcards = #wildcards,
		distinctEvents = (function()
			local n = 0
			for _ in counts do
				n += 1
			end
			return n
		end)(),
		counts = Events.counts(),
		audit = Events.audit(),
	}
end

return Events
