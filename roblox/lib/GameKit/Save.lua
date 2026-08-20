--!strict
-- L6: session-locked persistence.
--
-- Plain `GetAsync`/`SetAsync` is the standard way Roblox games lose and duplicate
-- player data. Two servers holding the same profile both believe their copy is
-- authoritative, and the last one to write wins -- which is how an item gets
-- duplicated by rejoining fast enough, and how an hour of progress disappears
-- when a server crashes after another already loaded the profile.
--
-- This store takes a **session lock** through `UpdateAsync` before handing out
-- any data. One server owns a profile at a time. A lock left behind by a crashed
-- server goes stale and can be taken over; a lock held by a live server cannot.
--
-- The other half is `BindToClose`. A server that shuts down without releasing
-- its locks strands every profile it held for the whole stale window, so release
-- is wired to shutdown rather than left to whoever remembers.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Save = {}

--- How long a lock stays valid without a heartbeat. Long enough that ordinary
--- DataStore latency never orphans a live session, short enough that a crashed
--- server does not lock a player out for a coffee break.
local LOCK_TIMEOUT_SECONDS = 90
local HEARTBEAT_SECONDS = 30
local AUTOSAVE_SECONDS = 120
local LOAD_ATTEMPTS = 6
local LOAD_RETRY_SECONDS = 5

export type Profile = {
	userId: number,
	data: { [string]: any },
	--- False once released or stolen. Never write through a dead profile.
	active: boolean,
	loadedAt: number,
	saves: number,
}

export type Store = {
	load: (self: Store, player: Player) -> Profile?,
	get: (self: Store, player: Player) -> Profile?,
	save: (self: Store, player: Player) -> boolean,
	release: (self: Store, player: Player) -> boolean,
	releaseAll: (self: Store) -> number,
	statistics: (self: Store) -> { [string]: any },
}

local function fail(message: string): never
	error("[GameKit.Save] " .. message, 3)
end

--- Deep copy, so a template is never shared between players by reference.
---
--- The bug this prevents is subtle and total: one player's inventory table
--- handed to every profile means every player edits the same inventory.
local function clone(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in pairs(value) do
		copy[key] = clone(item)
	end
	return copy
end

--- Fill in keys a template gained since a profile was written.
local function reconcile(data: { [string]: any }, template: { [string]: any })
	for key, value in pairs(template) do
		if data[key] == nil then
			data[key] = clone(value)
		elseif type(value) == "table" and type(data[key]) == "table" then
			reconcile(data[key], value)
		end
	end
end

local function sessionTag(): { jobId: string, placeId: number, at: number }
	return {
		-- In Studio every run shares an empty JobId, so a stable synthetic id is
		-- used instead; without it two Studio sessions look like one server and
		-- the lock never protects anything during development.
		jobId = if game.JobId ~= "" then game.JobId else "studio-" .. tostring(RunService:IsRunning()),
		placeId = game.PlaceId,
		at = os.time(),
	}
end

local function lockIsMine(record: any): boolean
	local mine = sessionTag()
	return type(record) == "table"
		and type(record.lock) == "table"
		and record.lock.jobId == mine.jobId
		and record.lock.placeId == mine.placeId
end

local function lockIsStale(record: any, now: number): boolean
	if type(record) ~= "table" or type(record.lock) ~= "table" then
		return true
	end
	local at = record.lock.at
	return type(at) ~= "number" or (now - at) > LOCK_TIMEOUT_SECONDS
end

function Save.store(name: string, template: { [string]: any }, options: { [string]: any }?): Store
	if type(name) ~= "string" or name == "" then
		fail("store name must be a non-empty string")
	end
	if type(template) ~= "table" then
		fail("store template must be a table")
	end
	local opts = options or {}

	-- DataStore is unavailable in an unpublished place, and `GetDataStore` throws
	-- rather than returning nil. Left unguarded it takes the whole module down on
	-- require, which means every game the factory builds is untestable in Studio
	-- until somebody publishes it -- exactly backwards.
	--
	-- Degraded rather than silent: the store works in memory and says so, so a
	-- session can be played and nobody mistakes a local run for proof that
	-- persistence works.
	local ok, dataStore = pcall(function()
		return DataStoreService:GetDataStore(name)
	end)
	local persistent = ok and dataStore ~= nil
	if not persistent then
		dataStore = nil
		warn(string.format(
			"[GameKit.Save] %q is running in memory: DataStore is unavailable, which is "
			.. "normal in an unpublished place. Nothing here survives a restart, and a "
			.. "local session is not evidence that saving works.", name))
	end
	local profiles: { [number]: Profile } = {}
	local statistics = {
		loads = 0,
        loadFailures = 0,
		saves = 0,
		saveFailures = 0,
		stolenLocks = 0,
		refusedLoads = 0,
	}

	local store = {} :: any

	local function key(userId: number): string
		return "profile_" .. tostring(userId)
	end

	--- Take the lock and read the data in one atomic transaction.
	local function acquire(userId: number): ({ [string]: any }?, string?)
		local claimed: { [string]: any }? = nil
		local refusal: string? = nil

		local ok, failure = pcall(function()
			if not persistent then return end
			dataStore:UpdateAsync(key(userId), function(record)
				local now = os.time()
				if record ~= nil and not lockIsMine(record) and not lockIsStale(record, now) then
					-- Someone live owns it. Returning nil aborts the write, which
					-- is what keeps this honest: we neither read nor damage a
					-- profile another server is using.
					refusal = "profile is locked by another server"
					return nil
				end
				if record ~= nil and not lockIsMine(record) and lockIsStale(record, now) then
					statistics.stolenLocks += 1
				end

				local data = if type(record) == "table" and type(record.data) == "table"
					then record.data
					else clone(template)
				reconcile(data, template)
				claimed = data
				return { data = data, lock = sessionTag() }
			end)
		end)

		if not ok then
			return nil, tostring(failure)
		end
		return claimed, refusal
	end

	function store:load(player: Player): Profile?
		if profiles[player.UserId] ~= nil then
			return profiles[player.UserId]
		end

		for attempt = 1, LOAD_ATTEMPTS do
			local data, refusal = acquire(player.UserId)
			if data ~= nil then
				local profile: Profile = {
					userId = player.UserId,
					data = data,
					active = true,
					loadedAt = os.clock(),
					saves = 0,
				}
				profiles[player.UserId] = profile
				statistics.loads += 1
				return profile
			end
			if refusal == nil then
				statistics.loadFailures += 1
			end
			if attempt < LOAD_ATTEMPTS then
				task.wait(LOAD_RETRY_SECONDS)
			end
			-- A player who left while we retried no longer needs the profile,
			-- and continuing would take a lock nobody will release.
			if player.Parent == nil then
				return nil
			end
		end

		statistics.refusedLoads += 1
		return nil
	end

	function store:get(player: Player): Profile?
		return profiles[player.UserId]
	end

	function store:save(player: Player): boolean
		local profile = profiles[player.UserId]
		if profile == nil or not profile.active then
			return false
		end
		local ok, failure = pcall(function()
			if not persistent then return end
			dataStore:UpdateAsync(key(profile.userId), function(record)
				if record ~= nil and not lockIsMine(record) then
					-- The lock moved on. Writing now would overwrite whatever the
					-- new owner has done, which is precisely the data loss this
					-- store exists to prevent.
					return nil
				end
				return { data = profile.data, lock = sessionTag() }
			end)
		end)
		if ok then
			profile.saves += 1
			statistics.saves += 1
			return true
		end
		statistics.saveFailures += 1
		if RunService:IsStudio() then
			warn("[GameKit.Save] save failed for " .. tostring(profile.userId) .. ": " .. tostring(failure))
		end
		return false
	end

	function store:release(player: Player): boolean
		local profile = profiles[player.UserId]
		if profile == nil then
			return false
		end
		local ok = pcall(function()
			if not persistent then return end
			dataStore:UpdateAsync(key(profile.userId), function(record)
				if record ~= nil and not lockIsMine(record) then
					return nil
				end
				return { data = profile.data, lock = nil }
			end)
		end)
		profile.active = false
		profiles[player.UserId] = nil
		if ok then
			statistics.saves += 1
		else
			statistics.saveFailures += 1
		end
		return ok
	end

	function store:releaseAll(): number
		local count = 0
		for userId in pairs(profiles) do
			local player = Players:GetPlayerByUserId(userId)
			if player ~= nil then
				store:release(player)
			else
				profiles[userId] = nil
			end
			count += 1
		end
		return count
	end

	function store:statistics(): { [string]: any }
		local held = 0
		for _ in pairs(profiles) do
			held += 1
		end
		local report = table.clone(statistics)
		report.heldProfiles = held
		return report
	end

	if opts.autoWire ~= false then
		Players.PlayerRemoving:Connect(function(player)
			store:release(player)
		end)

		-- Heartbeat: refresh the lock so a long-lived session is never mistaken
		-- for a crashed one, and autosave so a crash costs minutes, not hours.
		task.spawn(function()
			local sinceSave = 0
			while true do
				task.wait(HEARTBEAT_SECONDS)
				sinceSave += HEARTBEAT_SECONDS
				local shouldSave = sinceSave >= AUTOSAVE_SECONDS
				if shouldSave then
					sinceSave = 0
				end
				for userId in pairs(profiles) do
					local player = Players:GetPlayerByUserId(userId)
					if player ~= nil and shouldSave then
						store:save(player)
					end
				end
			end
		end)

		-- Without this, every profile this server holds stays locked for the
		-- full stale window after a shutdown.
		game:BindToClose(function()
			store:releaseAll()
		end)
	end

	return store :: Store
end

Save.LOCK_TIMEOUT_SECONDS = LOCK_TIMEOUT_SECONDS
Save.AUTOSAVE_SECONDS = AUTOSAVE_SECONDS

--- Adapt a profile store into the shape `Economy` wants.
function Save.economyStore(store: Store): { get: (number, string) -> number?, set: (number, string, number) -> () }
	return {
		-- nil means "never written", which `Economy` needs in order to seed a
		-- starting balance exactly once. Returning 0 here would re-seed every
		-- time a player went broke.
		get = function(userId: number, currency: string): number?
			local player = Players:GetPlayerByUserId(userId)
			local profile = if player then store:get(player) else nil
			if profile == nil then
				return nil
			end
			local wallet = profile.data.wallet
			return if type(wallet) == "table" then wallet[currency] else nil
		end,
		set = function(userId: number, currency: string, value: number)
			local player = Players:GetPlayerByUserId(userId)
			local profile = if player then store:get(player) else nil
			if profile == nil then
				return
			end
			if type(profile.data.wallet) ~= "table" then
				profile.data.wallet = {}
			end
			profile.data.wallet[currency] = value
		end,
	}
end

return Save
