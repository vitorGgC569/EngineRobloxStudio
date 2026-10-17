--!strict
--[[
	ClassRegistry — declarative class movesets with fail-loud validation.

	Mines Fighting-game's ClassData (walk speeds, health pools, staminas,
	ability names with cooldowns) into one registrable shape. register()
	rejects malformed definitions immediately — a nil cooldown discovered
	mid-fight costs far more than an assert at boot. Registering the same
	class id twice is treated as programmer error, never a silent overwrite.

	Pure data: no Instances, no services.
]]

local ClassRegistry = {}
ClassRegistry.__index = ClassRegistry

-- register and get used to hand back the stored definition. Setting health
-- or a move cooldown on that table rewrote the registry.
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

export type MoveDefinition = {
	cooldown: number,
	stacks: number,
}

export type ClassDefinition = {
	walkSpeed: number,
	health: number,
	stamina: number,
	moves: { [string]: MoveDefinition },
}

export type RawMove = {
	cooldown: number?,
	stacks: number?,
}

export type RawClass = {
	walkSpeed: number?,
	health: number?,
	stamina: number?,
	moves: { [string]: RawMove }?,
}

function ClassRegistry.new()
	return setmetatable({
		_classes = {} :: { [string]: ClassDefinition },
	}, ClassRegistry)
end

function ClassRegistry:register(classId: string, definition: RawClass): ClassDefinition
	assert(type(classId) == "string" and #classId > 0, "ClassRegistry.register: classId must be a non-empty string")
	assert(type(definition) == "table", "ClassRegistry.register: definition for '" .. classId .. "' must be a table")
	assert(self._classes[classId] == nil, "ClassRegistry.register: class '" .. classId .. "' is already registered")

	local walkSpeed = definition.walkSpeed
	assert(type(walkSpeed) == "number" and walkSpeed > 0, "ClassRegistry.register: '" .. classId .. "' walkSpeed must be a positive number")

	local health = definition.health
	assert(type(health) == "number" and health > 0, "ClassRegistry.register: '" .. classId .. "' health must be a positive number")

	local stamina = definition.stamina
	assert(type(stamina) == "number" and stamina >= 0, "ClassRegistry.register: '" .. classId .. "' stamina must be a non-negative number")

	assert(type(definition.moves) == "table", "ClassRegistry.register: '" .. classId .. "' moves must be a table")

	local moves: { [string]: MoveDefinition } = {}
	for moveName, move in definition.moves do
		assert(type(moveName) == "string" and #moveName > 0, "ClassRegistry.register: '" .. classId .. "' has a move with an empty name")
		assert(type(move) == "table", "ClassRegistry.register: move '" .. moveName .. "' of '" .. classId .. "' must be a table")

		local cooldown = move.cooldown
		assert(type(cooldown) == "number" and cooldown >= 0, "ClassRegistry.register: move '" .. moveName .. "' of '" .. classId .. "' needs a non-negative cooldown")

		local stacks = move.stacks or 1
		assert(type(stacks) == "number" and stacks >= 1 and stacks % 1 == 0, "ClassRegistry.register: move '" .. moveName .. "' of '" .. classId .. "' stacks must be an integer >= 1")

		moves[moveName] = {
			cooldown = cooldown :: number,
			stacks = stacks :: number,
		}
	end

	local normalized: ClassDefinition = {
		walkSpeed = walkSpeed :: number,
		health = health :: number,
		stamina = stamina :: number,
		moves = moves,
	}
	self._classes[classId] = normalized
	return deepCopy(normalized, {}) :: ClassDefinition
end

function ClassRegistry:get(classId: string): ClassDefinition?
	local definition = self._classes[classId]
	if definition == nil then
		return nil
	end
	return deepCopy(definition, {}) :: ClassDefinition
end

function ClassRegistry:has(classId: string): boolean
	return self._classes[classId] ~= nil
end

function ClassRegistry:cooldownOf(classId: string, moveName: string): number?
	local definition = self._classes[classId]
	if definition == nil then
		return nil
	end
	local move = definition.moves[moveName]
	if move == nil then
		return nil
	end
	return move.cooldown
end

return ClassRegistry
