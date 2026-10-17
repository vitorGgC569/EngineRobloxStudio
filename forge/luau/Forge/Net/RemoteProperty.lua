--!strict
--[[
	RemoteProperty — replicated-property PROTOCOL, transport-free.

	Weaver (and Knit before it) bolt a per-client value store onto a
	RemoteEvent Instance. This module keeps only the decision-making so any
	transport can carry it: the server holds a revision counter and every
	mutation RETURNS the ordered intents to ship,

		[{ kind = "all" | "one", target = string?, value = any, revision = n }]

	while the client replays them through ClientMirror, dropping anything not
	newer than what it already applied. Weaver's semantics survive: `set`
	replaces the default and clears every override, `revokeFor` falls a client
	back to the default, replicated values must be non-nil (replicating "nil"
	is `revokeFor`), and no-op mutations emit nothing.

	Pure: no Instances, no services, no yielding.
]]

export type IntentKind = "all" | "one"

export type Intent = {
	kind: IntentKind,
	target: string?, -- always set when kind == "one"
	value: any,
	revision: number,
}

-- The replay log exists only for diffing recent history; cap it so a chatty
-- property cannot grow without bound.
local LOG_LIMIT = 512

type PropertyImpl = {
	__index: PropertyImpl,
	name: string,
	defaultValue: any,
	overrides: { [string]: any },
	revision: number,
	history: { Intent },

	set: (self: Property, value: any) -> { Intent },
	setFor: (self: Property, clientKey: string, value: any) -> { Intent },
	revokeFor: (self: Property, clientKey: string) -> { Intent },
	get: (self: Property) -> any,
	getFor: (self: Property, clientKey: string) -> any,
	intentsAfter: (self: Property, revision: number) -> { Intent },
}

export type Property = typeof(setmetatable({} :: {
	name: string,
	defaultValue: any,
	overrides: { [string]: any },
	revision: number,
	history: { Intent },
}, {} :: PropertyImpl))

local Property: PropertyImpl = {} :: PropertyImpl
Property.__index = Property

function Property.new(name: string, defaultValue: any): Property
	assert(type(name) == "string" and #name > 0, "name must be a non-empty string")
	return setmetatable({
		name = name,
		defaultValue = defaultValue,
		overrides = {},
		revision = 0,
		history = {},
	}, Property)
end

local function record(self: Property, intent: Intent): ()
	table.insert(self.history, intent)
	if #self.history > LOG_LIMIT then
		table.remove(self.history, 1)
	end
end

local function emit(self: Property, kind: IntentKind, target: string?, value: any): { Intent }
	self.revision += 1
	local intent: Intent = { kind = kind, target = target, value = value, revision = self.revision }
	record(self, intent)
	return { intent }
end

-- Replaces the default for everyone and clears every override (Weaver:Set).
-- Emits nothing when the default already matches and nobody has overrides;
-- equality is shallow (`==`), same as Weaver.
function Property.set(self: Property, value: any): { Intent }
	if self.defaultValue == value and next(self.overrides) == nil then
		return {}
	end
	self.defaultValue = value
	table.clear(self.overrides)
	return emit(self, "all", nil, value)
end

-- Per-client override. Replicating the default itself is treated as a
-- revoke: cheaper state, identical wire result.
function Property.setFor(self: Property, clientKey: string, value: any): { Intent }
	assert(type(clientKey) == "string" and #clientKey > 0, "clientKey must be a non-empty string")
	assert(value ~= nil, "use revokeFor to replicate nil (fall back to the default)")
	if self.overrides[clientKey] == value then
		return {} -- the client would receive exactly what it already has
	end
	if value == self.defaultValue then
		return self:revokeFor(clientKey)
	end
	self.overrides[clientKey] = value
	return emit(self, "one", clientKey, value)
end

-- Drops a per-client override; the client falls back to the current default
-- (Weaver:ClearFor). Emits nothing if there was no override to drop.
function Property.revokeFor(self: Property, clientKey: string): { Intent }
	assert(type(clientKey) == "string" and #clientKey > 0, "clientKey must be a non-empty string")
	if self.overrides[clientKey] == nil then
		return {}
	end
	self.overrides[clientKey] = nil
	return emit(self, "one", clientKey, self.defaultValue)
end

function Property.get(self: Property): any
	return self.defaultValue
end

function Property.getFor(self: Property, clientKey: string): any
	local override = self.overrides[clientKey]
	if override ~= nil then
		return override
	end
	return self.defaultValue
end

-- Simple diffing by revision: everything still in the log newer than
-- `revision`, oldest first. Feed the results back through ClientMirror.
function Property.intentsAfter(self: Property, revision: number): { Intent }
	local pending: { Intent } = {}
	for _, intent in self.history do
		if intent.revision > revision then
			table.insert(pending, intent)
		end
	end
	return pending
end

-- ============================= client side ==================================

type MirrorImpl = {
	__index: MirrorImpl,
	current: any,
	lastRevision: number,

	apply: (self: Mirror, intent: Intent) -> any,
	get: (self: Mirror) -> any,
}

export type Mirror = typeof(setmetatable({} :: { current: any, lastRevision: number }, {} :: MirrorImpl))

local ClientMirror: MirrorImpl = {} :: MirrorImpl
ClientMirror.__index = ClientMirror

function ClientMirror.new(defaultValue: any): Mirror
	return setmetatable({ current = defaultValue, lastRevision = 0 }, ClientMirror)
end

-- Applies one shipped intent and returns the mirror's current value. Stale
-- or duplicated revisions are ignored, as is a malformed packet: intents
-- leave the server ordered, so anything older is a replay, not news.
function ClientMirror.apply(self: Mirror, intent: Intent): any
	if type(intent) ~= "table" or type(intent.revision) ~= "number" then
		return self.current
	end
	if intent.revision <= self.lastRevision then
		return self.current
	end
	self.current = intent.value
	self.lastRevision = intent.revision
	return self.current
end

function ClientMirror.get(self: Mirror): any
	return self.current
end

local RemoteProperty = {
	Property = Property,
	ClientMirror = ClientMirror,
}
table.freeze(RemoteProperty)

return RemoteProperty
