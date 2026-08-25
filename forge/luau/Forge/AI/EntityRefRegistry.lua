--!strict
--[[
	EntityRefRegistry — stable keys to entities across systems and realms.

	UserId, Part name or any string key maps to an entity id that survives
	system iteration order. The registry owns cleanup: keys whose owner
	released them are swept on the next tick, so despawned mobs cannot
	leak entries.
]]

local EntityRefRegistry = {}

type Self = {
	keyToEntity: { [string]: number },
	entityToKeys: { [number]: { string } },
	nextEntity: number,
}

EntityRefRegistry.__index = EntityRefRegistry

function EntityRefRegistry.new(): Self
	return setmetatable({
		keyToEntity = {},
		entityToKeys = {},
		nextEntity = 1,
	}, EntityRefRegistry)
end

-- Same key always returns the same entity id.
function EntityRefRegistry.get(self: Self, key: string): number
	local existing = self.keyToEntity[key]
	if existing then
		return existing
	end
	local entity = self.nextEntity
	self.nextEntity += 1
	self.keyToEntity[key] = entity
	self.entityToKeys[entity] = { key }
	return entity
end

function EntityRefRegistry.bind(self: Self, key: string, entity: number): ()
	local previous = self.keyToEntity[key]
	if previous == entity then
		return
	end
	if previous then
		local keys = self.entityToKeys[previous]
		if keys then
			local index = table.find(keys, key)
			if index then
				table.remove(keys, index)
			end
		end
	end
	self.keyToEntity[key] = entity
	self.entityToKeys[entity] = self.entityToKeys[entity] or {}
	table.insert(self.entityToKeys[entity] :: { string }, key)
end

function EntityRefRegistry.releaseKey(self: Self, key: string): boolean
	local entity = self.keyToEntity[key]
	if not entity then
		return false
	end
	self.keyToEntity[key] = nil
	local keys = self.entityToKeys[entity]
	if keys then
		local index = table.find(keys, key)
		if index then
			table.remove(keys, index)
		end
		if #keys == 0 then
			self.entityToKeys[entity] = nil
		end
	end
	return true
end

-- Sweeps entities left with no live keys (called periodically).
function EntityRefRegistry.sweep(self: Self): number
	local removed = 0
	for entity, keys in self.entityToKeys do
		if #keys == 0 then
			self.entityToKeys[entity] = nil
			removed += 1
		end
	end
	return removed
end

return EntityRefRegistry
