local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local PersistenceService = {}
PersistenceService.__index = PersistenceService

function PersistenceService.new(storeName)
	local self = setmetatable({}, PersistenceService)
	self.store = nil
	self.memoryStore = {}
	self.persistenceMode = "datastore"
	local success, store = pcall(function()
		return DataStoreService:GetDataStore(storeName)
	end)
	if success then
		self.store = store
	elseif RunService:IsStudio() then
		-- Unpublished local places cannot access DataStore. Keep the same
		-- server-authoritative API with an in-session store for Studio QA only.
		self.persistenceMode = "studio-memory-fallback"
	else
		error("DataStore unavailable outside Studio: " .. tostring(store))
	end
	self.cache = {}
	return self
end

function PersistenceService:load(player, defaults)
	local key = "player_" .. player.UserId
	if self.store == nil then
		local value = self.memoryStore[key]
		if type(value) == "table" then
			self.cache[player.UserId] = table.clone(value)
		else
			self.cache[player.UserId] = table.clone(defaults)
		end
		return self.cache[player.UserId]
	end
	local success, value = pcall(function()
		return self.store:GetAsync(key)
	end)
	if success and type(value) == "table" then
		self.cache[player.UserId] = value
	else
		self.cache[player.UserId] = table.clone(defaults)
	end
	return self.cache[player.UserId]
end

function PersistenceService:save(player)
	local value = self.cache[player.UserId]
	if value == nil then
		return false
	end
	local key = "player_" .. player.UserId
	if self.store == nil then
		self.memoryStore[key] = table.clone(value)
		return true
	end
	local success = pcall(function()
		self.store:UpdateAsync(key, function()
			return value
		end)
	end)
	return success
end

function PersistenceService:get(player)
	return self.cache[player.UserId]
end

function PersistenceService:clear(player)
	self.cache[player.UserId] = nil
end

return PersistenceService
