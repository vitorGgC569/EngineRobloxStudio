--!strict
--[[
	StatusEffects — pure stack of timed status effects.

	Each application lives on its own timer: two slows stack and expire
	separately, exactly like Fighting-game's Effect instances but without the
	Instances. tick(dt) advances a private clock, emits "tick" pulses for
	effects carrying ticksPerSecond and "expired" events when durations end.
	modsFor multiplies modifier keys together so stacking slows compose
	naturally (0.5 x 0.5 = 0.25 walk speed); absent keys mean 1.

	snapshot/restore capture the full state as plain data for persistence.
	Effects attach to caller-chosen target ids; nothing here touches the game.
]]

local StatusEffects = {}
StatusEffects.__index = StatusEffects

export type ApplyOptions = {
	duration: number,
	ticksPerSecond: number?,
	mods: { [string]: number }?,
}

export type EffectEvent = {
	targetId: any,
	effectId: string,
	type: "tick" | "expired",
}

type Entry = {
	effectId: string,
	expires: number,
	nextTick: number?,
	interval: number?,
	mods: { [string]: number },
}

-- ============================== helpers ======================================

local function shallowCopyMods(mods: { [string]: number }?): { [string]: number }
	local copy = {}
	if mods ~= nil then
		for key, value in mods do
			copy[key] = value
		end
	end
	return copy
end

local function copyEntry(entry: Entry): Entry
	return {
		effectId = entry.effectId,
		expires = entry.expires,
		nextTick = entry.nextTick,
		interval = entry.interval,
		mods = shallowCopyMods(entry.mods),
	}
end

-- ============================== lifecycle ====================================

function StatusEffects.new()
	return setmetatable({
		_clock = 0,
		_targets = {} :: { [any]: { Entry } },
	}, StatusEffects)
end

function StatusEffects:apply(targetId: any, effectId: string, options: ApplyOptions): Entry
	assert(type(effectId) == "string" and #effectId > 0, "StatusEffects.apply: effectId must be a non-empty string")
	assert(type(options) == "table", "StatusEffects.apply: options must be a table")
	assert(type(options.duration) == "number" and options.duration > 0, "StatusEffects.apply: duration must be a positive number")

	local ticksPerSecond = options.ticksPerSecond
	local interval = nil :: number?
	if ticksPerSecond ~= nil then
		assert(type(ticksPerSecond) == "number" and ticksPerSecond > 0, "StatusEffects.apply: ticksPerSecond must be positive")
		interval = 1 / ticksPerSecond
	end

	local entry: Entry = {
		effectId = effectId,
		expires = self._clock + options.duration,
		nextTick = if interval then self._clock + interval else nil,
		interval = interval,
		mods = shallowCopyMods(options.mods),
	}

	local list = self._targets[targetId]
	if list == nil then
		list = {}
		self._targets[targetId] = list
	end
	table.insert(list, entry)
	return entry
end

function StatusEffects:tick(dt: number): { EffectEvent }
	local events: { EffectEvent } = {}
	if dt <= 0 then
		return events
	end

	self._clock += dt
	local now = self._clock
	local drained = {}

	for targetId, list in self._targets do
		local alive: { Entry } = {}
		for _, entry in list do
			while entry.nextTick ~= nil and entry.nextTick <= now and entry.nextTick < entry.expires do
				table.insert(events, { targetId = targetId, effectId = entry.effectId, type = "tick" })
				entry.nextTick += entry.interval :: number
			end
			if now >= entry.expires then
				table.insert(events, { targetId = targetId, effectId = entry.effectId, type = "expired" })
			else
				table.insert(alive, entry)
			end
		end
		if #alive == 0 then
			table.insert(drained, targetId)
		else
			self._targets[targetId] = alive
		end
	end

	for _, targetId in drained do
		self._targets[targetId] = nil
	end

	return events
end

-- Multiplicative product across every live effect on the target; missing
-- keys mean no effect touched them.
function StatusEffects:modsFor(targetId: any): { [string]: number }
	local aggregated: { [string]: number } = {}
	for _, entry in self._targets[targetId] or {} do
		for key, value in entry.mods do
			aggregated[key] = (aggregated[key] or 1) * value
		end
	end
	return aggregated
end

function StatusEffects:clear(targetId: any): boolean
	local had = self._targets[targetId] ~= nil
	self._targets[targetId] = nil
	return had
end

-- ============================== persistence ==================================

function StatusEffects:snapshot()
	local targets: { [any]: { Entry } } = {}
	for targetId, list in self._targets do
		local copies: { Entry } = {}
		for _, entry in list do
			table.insert(copies, copyEntry(entry))
		end
		targets[targetId] = copies
	end
	return {
		clock = self._clock,
		targets = targets,
	}
end

function StatusEffects:restore(snapshot: { clock: number, targets: { [any]: { Entry } } })
	assert(type(snapshot) == "table", "StatusEffects.restore: snapshot must be a table")
	assert(type(snapshot.clock) == "number", "StatusEffects.restore: snapshot.clock must be a number")
	assert(type(snapshot.targets) == "table", "StatusEffects.restore: snapshot.targets must be a table")

	local rebuilt: { [any]: { Entry } } = {}
	for targetId, list in snapshot.targets do
		assert(type(list) == "table", "StatusEffects.restore: target entries must be a table")
		local entries: { Entry } = {}
		for _, entry in list do
			assert(type(entry.effectId) == "string" and type(entry.expires) == "number", "StatusEffects.restore: malformed entry")
			table.insert(entries, copyEntry(entry))
		end
		rebuilt[targetId] = entries
	end

	self._clock = snapshot.clock
	self._targets = rebuilt
end

return StatusEffects
