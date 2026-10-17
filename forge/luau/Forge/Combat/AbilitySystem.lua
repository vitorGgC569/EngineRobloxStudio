--!strict
--[[
	AbilitySystem — GUID-addressable casts with cast times and cooldowns.

	Every ability execution gets a GUID at cast start; damage events later
	cite that GUID, which is what lets the validator tie a hit to a real,
	timely execution instead of trusting the client's word. States:
	idle -> casting -> executing -> cooldown.
]]

local AbilitySystem = {}

-- `register` stored the caller's table, and `_execute` handed `executionData`
-- back. Setting cooldown after register, or damage on the returned payload,
-- rewrote the next cast while the cooldown clock still used the old number.
local function deepCopy(value: any, seen: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in value :: { [any]: any } do
		copy[key] = deepCopy(item, seen)
	end
	return copy
end

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
	-- An empty id still casts. A later hit then cites an ability with no name.
	assert(type(abilityId) == "string" and #abilityId > 0, "ability id must be a non-empty string")
	assert(not self.defs[abilityId], ("duplicate ability %q"):format(abilityId))
	-- math.huge is at least 0. After one cast the remaining time stays
	-- infinite, so the ability never becomes usable again.
	assert(
		type(def.cooldown) == "number"
			and def.cooldown == def.cooldown
			and def.cooldown >= 0
			and def.cooldown < math.huge,
		"cooldown cannot be negative"
	)
	-- nil stays nil; cast treats that as immediate. math.huge is truthy, so
	-- executeAt would be infinite and tick would never finish the cast.
	if def.castTime ~= nil then
		assert(
			type(def.castTime) == "number"
				and def.castTime == def.castTime
				and def.castTime >= 0
				and def.castTime < math.huge,
			"castTime must be >= 0"
		)
	end
	self.defs[abilityId] = deepCopy(def, {}) :: AbilityDef
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
	local now = self.now()
	-- A NaN clock is not a time. Subtracting it does not produce the stored
	-- cooldown, and this read must not rewrite cooldownUntil.
	if type(now) ~= "number" or now ~= now or not (now > -math.huge and now < math.huge) then
		return self:cooldownOf(abilityId)
	end
	return math.max(0, until_ - now)
end

function AbilitySystem.resetCooldown(self: Self, abilityId: string): ()
	self.cooldownUntil[abilityId] = nil
end

function AbilitySystem.isCasting(self: Self): boolean
	return self.activeCast ~= nil
end

-- Begins a cast; returns the GUID or nil+reason. Fails closed.
function AbilitySystem.cast(self: Self, abilityId: string): (string?, string?)
	local now = self.now()
	-- A NaN clock would store NaN in cooldownUntil. A later real clock then
	-- subtracts from NaN, and the cooldown has vanished.
	if type(now) ~= "number" or now ~= now or not (now > -math.huge and now < math.huge) then
		return nil, "bad_clock"
	end
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
	if not cast then
		return nil, nil
	end
	local now = self.now()
	-- NaN is not less than executeAt, so the cast would finish early and
	-- _execute would store a NaN cooldown. Leave the cast pending.
	if type(now) ~= "number" or now ~= now or not (now > -math.huge and now < math.huge) then
		return nil, nil
	end
	if now < cast.executeAt then
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
	return cast.guid, deepCopy(def.executionData or {}, {}) :: { [string]: any }
end

return AbilitySystem
