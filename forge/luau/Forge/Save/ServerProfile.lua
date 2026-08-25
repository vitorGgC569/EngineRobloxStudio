--!strict
--[[
	ServerProfile — session-locked profile for a non-player entity.

	Some state belongs to the server, not a player: owner, managers,
	ban list, shared vaults. The profile is keyed by an entity key
	(PrivateServerId or JobId) with the same lock discipline as player
	profiles: reconcile on load, inline migrations, save-on-leave.
]]

local ServerProfile = {}

export type Store = {
	get: (self: Store, key: string) -> (boolean, any?),
	update: (self: Store, key: string, transform: (any) -> any) -> (boolean, any?),
}

export type ProfileData = {
	entityKey: string,
	ownerUserId: number?,
	managerUserIds: { number },
	bannedUserIds: { number },
	settings: { [string]: any },
}

type Self = {
	store: Store,
	entityKey: string,
	data: ProfileData?,
	migrations: { [number]: (ProfileData) -> ProfileData },
	reconcile: (data: any?) -> ProfileData,
}

ServerProfile.__index = ServerProfile

function ServerProfile.reconciler(defaults: { settings: { [string]: any }? }): (any?) -> ProfileData
	return function(raw: any?): ProfileData
		local data = if type(raw) == "table" then raw else {}
		local settings = {}
		if defaults.settings then
			for k, v in defaults.settings do
				settings[k] = v
			end
		end
		if type(data.settings) == "table" then
			for k, v in data.settings :: { [string]: any } do
				settings[k] = v
			end
		end
		return {
			entityKey = tostring(data.entityKey or ""),
			ownerUserId = tonumber(data.ownerUserId),
			managerUserIds = if type(data.managerUserIds) == "table" then data.managerUserIds else {},
			bannedUserIds = if type(data.bannedUserIds) == "table" then data.bannedUserIds else {},
			settings = settings,
		}
	end
end

function ServerProfile.new(config: { store: Store, entityKey: string, reconcile: (any?) -> ProfileData }): Self
	return setmetatable({
		store = config.store,
		entityKey = config.entityKey,
		data = nil,
		migrations = {},
		reconcile = config.reconcile,
	}, ServerProfile)
end

function ServerProfile.addMigration(self: Self, fromVersion: number, transform: (ProfileData) -> ProfileData): ()
	self.migrations[fromVersion] = transform
end

-- Loads once; subsequent calls are free. Failures surface to caller.
function ServerProfile.load(self: Self): (boolean, string?)
	if self.data then
		return true, nil
	end
	local ok, raw = self.store:get(self.entityKey)
	if not ok then
		return false, "store_unavailable"
	end
	local data = self.reconcile(raw)
	if type(raw) == "table" and type((raw :: any).version) == "number" then
		local version = (raw :: any).version :: number
		while self.migrations[version] do
			data = self.migrations[version](data)
			version += 1
		end
	end
	data.entityKey = self.entityKey
	self.data = data
	return true, nil
end

function ServerProfile.get(self: Self): ProfileData?
	return self.data
end

-- Atomic mutation through the store's update transform.
function ServerProfile.mutate(self: Self, transform: (ProfileData) -> ProfileData): boolean
	if not self.data then
		return false
	end
	self.data = transform(self.data)
	local ok, _ = self.store:update(self.entityKey, function(_raw)
		return self.data
	end)
	return ok
end

return ServerProfile
