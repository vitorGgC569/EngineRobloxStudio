--!strict
--[[
	Cvars — named tunables inspectable by probes.

	Game feel numbers registered once ("combat.hitstop", "move.sprint")
	with types and bounds; LiveConfig can override defaults at boot and
	probes read the live snapshot through the bridge. Set rejects
	out-of-bounds silently-return-false instead of corrupting balance.
]]

local Cvars = {}

export type Cvar = {
	name: string,
	value: number,
	default: number,
	min: number,
	max: number,
	help: string,
}

type Self = {
	vars: { [string]: Cvar },
	order: { string },
}

Cvars.__index = Cvars

function Cvars.new(): Self
	return setmetatable({ vars = {}, order = {} }, Cvars)
end

function Cvars.register(self: Self, name: string, defaultValue: number, min: number, max: number, help: string?): ()
	assert(not self.vars[name], ("cvar %q already registered"):format(name))
	assert(min <= max, ("cvar %q has invalid range"):format(name))
	self.vars[name] = { name = name, value = math.clamp(defaultValue, min, max), default = defaultValue, min = min, max = max, help = help or "" }
	table.insert(self.order, name)
end

function Cvars.get(self: Self, name: string): number?
	local v = self.vars[name]
	return if v then v.value else nil
end

function Cvars.set(self: Self, name: string, value: number): boolean
	local v = self.vars[name]
	if not v then
		return false
	end
	v.value = math.clamp(value, v.min, v.max)
	return true
end

function Cvars.reset(self: Self, name: string): boolean
	local v = self.vars[name]
	if not v then
		return false
	end
	v.value = v.default
	return true
end

function Cvars.snapshot(self: Self): { [string]: number }
	local out: { [string]: number } = {}
	for _, name in self.order do
		out[name] = self.vars[name].value
	end
	return out
end

return Cvars
