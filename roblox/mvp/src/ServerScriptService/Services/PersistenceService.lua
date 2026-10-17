-- Compatibility facade over the shared, session-owned profile store.
local Save = require(game:GetService("ServerScriptService").GameKit.Save)
local PersistenceService = {}
PersistenceService.__index = PersistenceService

function PersistenceService.new(storeName)
    return setmetatable({ storeName = storeName, profiles = nil }, PersistenceService)
end

function PersistenceService:load(player, defaults)
    if self.profiles == nil then
        self.profiles = Save.store(self.storeName, defaults, {
            autoWire = false, keyPrefix = "player_", legacyFlat = true,
        })
        self.persistenceMode = if self.profiles:statistics().persistent then "datastore" else "studio-memory-fallback"
    end
    local profile = self.profiles:load(player)
    return if profile then profile.data else nil
end

function PersistenceService:save(player)
    return self.profiles ~= nil and self.profiles:save(player)
end

function PersistenceService:get(player)
    local profile = if self.profiles then self.profiles:get(player) else nil
    return if profile then profile.data else nil
end

function PersistenceService:clear(player)
    return self.profiles ~= nil and self.profiles:release(player)
end

function PersistenceService:close()
    return if self.profiles then self.profiles:releaseAll() else 0
end

return PersistenceService
