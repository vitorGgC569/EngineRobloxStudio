--!strict
--[[
	GlobalEffects — something is true for the whole server, for a while.

	Double coins for an hour. A boss is loose and everyone's damage is up ten
	percent. A weekend event. The shape is always the same: a named effect with
	a deadline, several of them at once, and every system that multiplies a
	number needing to know the current total *without* asking each effect in
	turn.

		GlobalEffects.define("double_coins", { coin = 2 })
		GlobalEffects.apply("double_coins", 3600, "weekend event")

		GlobalEffects.aggregate("coin")   --> 2, already multiplied out

	Aggregates, not a list
	----------------------

	The mistake is exposing the active effects and letting each caller fold
	them. Then the payout code multiplies, the HUD multiplies slightly
	differently, and the two disagree in front of the player. One folded number
	per axis, recomputed when the set changes, means there is nothing to
	disagree about.

	Multiplicative by default, and deliberately
	------------------------------------------

	Two effects that each say "double coins" give four times, not three. That
	is what a player expects from two doublers and it is what makes stacking
	events feel like an event. Additive axes exist for the cases where they do
	not — a flat `+5 luck` should be `+10`, not `+25`.

	Expiry is checked, never trusted to a timer
	------------------------------------------

	A `task.delay` per effect is a timer that a server restart forgets and a
	long effect outlives. Each effect stores an absolute instant and a single
	sweep retires whatever is past it, so an effect is over when its time has
	passed rather than when a callback happens to run.
]]

local Clock = require(script.Parent.Parent.Core.Clock)
local Signal = require(script.Parent.Parent.Core.Signal)

local GlobalEffects = {}

export type Definition = {
	axes: { [string]: number },
	mode: string?,
	label: string?,
}

type Active = {
	id: string,
	expiresAt: number,
	reason: string,
	startedAt: number,
}

local definitions: { [string]: Definition } = {}
local active: { [string]: Active } = {}
local aggregates: { [string]: number } = {}

GlobalEffects.changed = Signal.new() -- (aggregates)

--: How each axis folds. Anything not named here multiplies.
local additive: { [string]: boolean } = {}
GlobalEffects.additive = additive

-- ================================= defining =================================
--[[
	Declare what an effect does, separately from turning it on.

	The split matters: the definition is content and belongs in a config; the
	activation is an operational decision made at eleven at night when a queue
	is backed up. Anything that requires editing a table to run an event will
	not be run.
]]
function GlobalEffects.define(id: string, axes: { [string]: number }, options: any?)
	local opts = options or {}
	definitions[id] = {
		axes = axes,
		mode = opts.mode,
		label = opts.label or id,
	}
end

function GlobalEffects.defineMany(table_: { [string]: { [string]: number } })
	for id, axes in table_ do
		GlobalEffects.define(id, axes)
	end
end

--: Mark an axis as adding rather than multiplying.
function GlobalEffects.addsUp(axis: string)
	additive[axis] = true
end

-- ================================ activating ================================
local function recompute()
	table.clear(aggregates)
	for id in active do
		local definition = definitions[id]
		if not definition then
			continue
		end
		for axis, amount in definition.axes do
			if additive[axis] then
				aggregates[axis] = (aggregates[axis] or 0) + amount
			else
				aggregates[axis] = (aggregates[axis] or 1) * amount
			end
		end
	end
	GlobalEffects.changed:Fire(table.clone(aggregates))
end

--[[
	Turn an effect on for a number of seconds.

	Re-applying an effect that is already running **extends** it to whichever
	deadline is later rather than stacking a second copy. Two admins pressing
	the same button should not double the event, and a scheduled effect
	overlapping a manual one should not either.
]]
function GlobalEffects.apply(id: string, seconds: number, reason: string?): boolean
	if not definitions[id] then
		warn(string.format("[GlobalEffects] '%s' is not defined", id))
		return false
	end

	local expiresAt = Clock.expiresIn(seconds)
	local existing = active[id]
	if existing then
		existing.expiresAt = math.max(existing.expiresAt, expiresAt)
		existing.reason = reason or existing.reason
		return true
	end

	active[id] = {
		id = id,
		expiresAt = expiresAt,
		reason = reason or "unspecified",
		startedAt = Clock.now(),
	}
	recompute()
	return true
end

function GlobalEffects.remove(id: string): boolean
	if not active[id] then
		return false
	end
	active[id] = nil
	recompute()
	return true
end

function GlobalEffects.clear()
	table.clear(active)
	recompute()
end

--[[
	Retire whatever has run out.

	Returns what it retired, so a caller can announce the end of an event
	rather than have it stop silently. Call it on a slow loop — every few
	seconds is ample for something measured in minutes.
]]
function GlobalEffects.sweep(): { string }
	local expired: { string } = {}
	for id, entry in active do
		if Clock.hasExpired(entry.expiresAt) then
			table.insert(expired, id)
		end
	end
	if #expired > 0 then
		for _, id in expired do
			active[id] = nil
		end
		recompute()
	end
	return expired
end

function GlobalEffects.start(everySeconds: number?)
	task.spawn(function()
		while true do
			task.wait(everySeconds or 5)
			GlobalEffects.sweep()
		end
	end)
end

-- ================================= reading ==================================
--[[
	The multiplier for one axis, right now.

	One returned for an unmultiplied axis and zero for an unadded one, so a
	caller can multiply or add unconditionally without checking whether any
	event is running.
]]
function GlobalEffects.aggregate(axis: string): number
	local value = aggregates[axis]
	if value then
		return value
	end
	return additive[axis] and 0 or 1
end

function GlobalEffects.isActive(id: string): boolean
	local entry = active[id]
	return entry ~= nil and not Clock.hasExpired(entry.expiresAt)
end

--: What is running, soonest to finish first — the order a UI wants.
function GlobalEffects.list(): { any }
	local out = {}
	for id, entry in active do
		local definition = definitions[id]
		table.insert(out, {
			id = id,
			label = definition and definition.label or id,
			axes = definition and definition.axes or {},
			reason = entry.reason,
			remaining = Clock.remaining(entry.expiresAt),
			remainingText = Clock.format(Clock.remaining(entry.expiresAt)),
		})
	end
	table.sort(out, function(a, b)
		return a.remaining < b.remaining
	end)
	return out
end

function GlobalEffects.describe(): { [string]: any }
	return {
		defined = (function()
			local n = 0
			for _ in definitions do
				n += 1
			end
			return n
		end)(),
		active = GlobalEffects.list(),
		aggregates = table.clone(aggregates),
	}
end

function GlobalEffects.reset()
	table.clear(definitions)
	table.clear(active)
	table.clear(aggregates)
	table.clear(additive)
end

return GlobalEffects
