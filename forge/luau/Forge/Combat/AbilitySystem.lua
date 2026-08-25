--!strict
--[[
	AbilitySystem — GUID-addressable casts with cast times and cooldowns.

	Every ability execution gets a GUID at cast start; damage events later
	cite that GUID, which is what lets the validator tie a hit to a real,
	timely execution instead of trusting the client's word. States:
	idle -> casting -> executing -> cooldown.
]]

local AbilitySystem = {}

export type AbilityDef = {
	name: string,
	castTime: number?,
	cooldown: number,
	executionData: { [string]: any }?,
}

type Cast = {
	guid: string,
	abilityId: string,
	startedAt: number,
	executeAt: number,
}

type Self = {
	defs: { [string]: AbilityDef },
	cooldownUntil: { [string]: number },
	activeCast: Cast?,
	executions: { Cast },
	now: () -> number,
	guidFactory: () -> string,
}

AbilitySystem.__index = AbilitySystem

function AbilitySystem.new(config: { now: (() -> number)?, guidFactory: (() -> string)? }): Self
	return setmetatable({
		defs = {},
		cooldownUntil = {},
		activeCast = nil,
		executions = {},
		now = config.now or os.clock,
		guidFactory = config.guidFactory or function()
			return tostring(os.clock()) .. "-" .. math.random(1e6)
		end,
	}, AbilitySystem)
end

function AbilitySystem.register(self: Self, abilityId: string, def: AbilityDef): ()
	assert(not self.defs[abilityId], ("duplicate ability %q"):format(abilityId))
	assert(def.cooldown >= 0, "cooldown cannot be negative")
	self.defs[abilityId] = def
end

function AbilitySystem.cooldownOf(self: Self, abilityId: string): number
	local def = self.defs[abilityId]
	assert(def, "unknown ability")
	return def.cooldown
end

function AbilitySystem.remainingCooldown(self: Self, abilityId: string): number
	local until_ = self.cooldownUntil[abilityId]
	if not until_ then
		return 0
	end
	return math.max(0, until_ - self.now())
end

function AbilitySystem.resetCooldown(self: Self, abilityId: string): ()
	self.cooldownUntil[abilityId] = nil
end

function AbilitySystem.isCasting(self: Self): boolean
	return self.activeCast ~= nil
end

-- Begins a cast; returns the GUID or nil+reason. Fails closed.
function AbilitySystem.cast(self: Self, abilityId: string): (string?, string?)
	local def = self.defs[abilityId]
	if not def then
		return nil, "unknown_ability"
	end
	if self.activeCast then
		return nil, "already_casting"
	end
	if self:remainingCooldown(abilityId) > 0 then
		return nil, "cooldown"
	end
	local now = self.now()
	local cast: Cast = {
		guid = self.guidFactory(),
		abilityId = abilityId,
		startedAt = now,
		executeAt = now + (def.castTime or 0),
	}
	if (def.castTime or 0) > 0 then
		self.activeCast = cast
	else
		return self:_execute(cast)
	end
	return cast.guid, nil
end

-- Completes the pending cast when its time has elapsed.
function AbilitySystem.tick(self: Self): (string?, { [string]: any }?)
	local cast = self.activeCast
	if not cast or self.now() < cast.executeAt then
		return nil, nil
	end
	self.activeCast = nil
	local data = self:_execute(cast)
	return cast.guid, data
end

function AbilitySystem._execute(self: Self, cast: Cast): (string, { [string]: any })
	local def = self.defs[cast.abilityId] :: AbilityDef
	self.cooldownUntil[cast.abilityId] = self.now() + def.cooldown
	table.insert(self.executions, cast)
	return cast.guid, def.executionData or {}
end

return AbilitySystem
