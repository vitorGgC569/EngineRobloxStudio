--!strict
--[[
	ServerProfile — session-locked profile for a non-player entity.

	Some state belongs to the server, not a player: owner, managers,
	ban list, shared vaults. The profile is keyed by an entity key
	(PrivateServerId or JobId) with the same lock discipline as player
	profiles: reconcile on load, inline migrations, save-on-leave.

	The schema version is part of the saved record. A migration step
	that already ran must not run again on the next load.
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
	version: number,
}

type Self = {
	store: Store,
	entityKey: string,
	data: ProfileData?,
	migrations: { [number]: (ProfileData) -> ProfileData },
	reconcile: (data: any?) -> ProfileData,
}

ServerProfile.__index = ServerProfile

-- A missing settings key is copied from the default. `seen` keeps a cyclic
-- template from looping. The copy is so filling a key does not alias the
-- template the next profile will read.
local function copySettings(value: any, seen: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in value :: { [any]: any } do
		copy[key] = copySettings(item, seen)
	end
	return copy
end

-- Saved settings win, including a scalar that sits where the default has a
-- table. When both sides are tables the merge descends, so a new nested
-- default appears without replacing the table the player already saved.
-- A nil saved value is skipped, which leaves the default in place. This is
-- settings only; id lists are copied through unchanged by the caller.
local function mergeSettings(defaultValue: any, savedValue: any): any
	if type(savedValue) == "table" and type(defaultValue) == "table" then
		local merged: { [any]: any } = {}
		for key, item in savedValue :: { [any]: any } do
			if item ~= nil then
				local childDefault = (defaultValue :: { [any]: any })[key]
				if type(item) == "table" and type(childDefault) == "table" then
					merged[key] = mergeSettings(childDefault, item)
				else
					merged[key] = item
				end
			end
		end
		for key, item in defaultValue :: { [any]: any } do
			if item ~= nil and merged[key] == nil then
				merged[key] = copySettings(item, {})
			end
		end
		return merged
	end
	if savedValue ~= nil then
		return savedValue
	end
	return copySettings(defaultValue, {})
end

function ServerProfile.reconciler(defaults: { settings: { [string]: any }? }): (any?) -> ProfileData
	return function(raw: any?): ProfileData
		local data = if type(raw) == "table" then raw else {}
		local savedSettings = if type(data.settings) == "table" then data.settings else nil
		local mergedSettings = mergeSettings(defaults.settings, savedSettings)
		local settings: { [string]: any } = if type(mergedSettings) == "table" then mergedSettings else {}
		local declaredVersion = tonumber(data.version)
		return {
			entityKey = tostring(data.entityKey or ""),
			ownerUserId = tonumber(data.ownerUserId),
			managerUserIds = if type(data.managerUserIds) == "table" then data.managerUserIds else {},
			bannedUserIds = if type(data.bannedUserIds) == "table" then data.bannedUserIds else {},
			settings = settings,
			-- A missing stamp is 0, not 1. Profiles already saved without a
			-- version must not look like they still qualify for the first step.
			version = if declaredVersion and declaredVersion == declaredVersion then math.floor(declaredVersion) else 0,
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
	-- Reconcile builds a fresh table. The loop used to advance a local and
	-- then discard it, so the save omitted the only record of which grants
	-- had already run. Read the stamp from the raw record (a reconcile that
	-- drops unknown fields cannot hide it) and write the post-migration
	-- version back onto the profile the store will persist.
	local declared = if type(raw) == "table" then tonumber((raw :: any).version) else nil
	local version = if declared and declared == declared then math.floor(declared) else 0
	while self.migrations[version] do
		data = self.migrations[version](data)
		version += 1
	end
	data.version = version
	data.entityKey = self.entityKey
	self.data = data
	return true, nil
end

function ServerProfile.get(self: Self): ProfileData?
	return self.data
end

-- Atomic mutation through the store's update transform.
--
-- The store passes the latest record into the callback. Reconcile that
-- record first, so a settings key the session has never seen is still
-- there, then lay the unsaved session settings over it. A load migration
-- may have changed the session and not been saved yet; those values stay,
-- and a stored key the session lacks is not wiped. The caller's transform
-- runs once, on that record, inside the update. A failed update leaves the
-- previous session profile where it was.
function ServerProfile.mutate(self: Self, transform: (ProfileData) -> ProfileData): boolean
	if not self.data then
		return false
	end
	local previous = self.data
	local ok, written = self.store:update(self.entityKey, function(raw)
		local reconciled = self.reconcile(raw)
		local sessionSettings = if type(previous.settings) == "table" then previous.settings else nil
		local storedSettings = if type(reconciled.settings) == "table" then reconciled.settings else nil
		local merged = mergeSettings(storedSettings, sessionSettings)
		local settings: { [string]: any } = if type(merged) == "table" then merged else {}
		local version = if type(previous.version) == "number" then previous.version else reconciled.version
		local base: ProfileData = {
			entityKey = self.entityKey,
			ownerUserId = reconciled.ownerUserId,
			managerUserIds = reconciled.managerUserIds,
			bannedUserIds = reconciled.bannedUserIds,
			settings = settings,
			version = version,
		}
		local updated = transform(base)
		-- The annotation says the return has `version`. A rebuilt table
		-- often does not, and the checker would delete a direct test.
		local record: any = updated
		if type(record) == "table" and type(record.version) ~= "number" then
			record.version = version
		end
		return record
	end)
	if not ok then
		return false
	end
	if type(written) == "table" then
		self.data = written :: ProfileData
	end
	return true
end

return ServerProfile
