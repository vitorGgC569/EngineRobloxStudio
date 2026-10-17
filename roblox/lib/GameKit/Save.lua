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
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Save = {}

--- How long a lock stays valid without a heartbeat. Long enough that ordinary
--- DataStore latency never orphans a live session, short enough that a crashed
--- server does not lock a player out for a coffee break.
local LOCK_TIMEOUT_SECONDS = 90
local HEARTBEAT_SECONDS = 30
local AUTOSAVE_SECONDS = HEARTBEAT_SECONDS
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

local function sessionTag(token: string, fence: number): any
	return { jobId = token, placeId = game.PlaceId, at = os.time(), fence = fence }
end

local function lockIsMine(record: any, token: string, fence: number?): boolean
	return type(record) == "table" and type(record.lock) == "table"
		and record.lock.jobId == token and (fence == nil or record.lock.fence == fence)
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
	local keyPrefix = opts.keyPrefix or "profile_"
	assert(type(keyPrefix) == "string" and #keyPrefix > 0, "invalid key prefix")
	local closing = false

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
	if not persistent and not RunService:IsStudio() then
		fail("DataStore unavailable outside Studio")
	end
	if not persistent then
		dataStore = nil
		warn(string.format(
			"[GameKit.Save] %q is running in memory: DataStore is unavailable, which is "
			.. "normal in an unpublished place. Nothing here survives a restart, and a "
			.. "local session is not evidence that saving works.", name))
	end
	local profiles: { [number]: Profile } = {}
	local leases: { [number]: any } = {}
	local loading: { [number]: boolean } = {}
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
		return keyPrefix .. tostring(userId)
	end

	--[[
		Where a memory-mode profile actually lives.

		This did not exist, and its absence made the whole degraded mode a lie.
		`acquire` began `if not persistent then return end` -- returning from
		the *inner* function, so `claimed` stayed nil, `load` read that as a
		failed read, retried three times and returned nil. Every game in an
		unpublished place therefore had no profile at all, while the warning
		above told the developer it was "running in memory".

		Nothing caught it because nothing called `load`. It surfaced the first
		time a feature needed a profile to exist -- a daily login streak -- and
		it surfaced as a button reading "come back tomorrow" on a new save.
	]]
	local memory: { [number]: { [string]: any } } = {}

	--- Take the lock and read the data in one atomic transaction.
	local function acquire(userId: number): ({ [string]: any }?, string?)
		local refusal: string? = nil

		--: No lock and no transaction, because there is no second server to
		--: race with. The table is the store.
		if not persistent then
			local data = memory[userId] or clone(template)
			reconcile(data, template)
			memory[userId] = data
			return data, nil
		end

		local lease = leases[userId]
		local ok, committed = pcall(function()
			return dataStore:UpdateAsync(key(userId), function(record)
				local now = os.time()
				-- Explicit compatibility adapter for stores that previously saved
				-- flat data at the same key. Conversion and acquisition are atomic.
				if opts.legacyFlat == true and type(record) == "table" and record.data == nil
					and record.lock == nil and record.fence == nil then
					record = { data = clone(record) }
				end
				if record ~= nil and (type(record) ~= "table" or type(record.data) ~= "table") then
					refusal = "corrupt profile; explicit recovery required"
					return nil
				end
				if record ~= nil and not lockIsMine(record, lease.token) and not lockIsStale(record, now) then
					refusal = "profile is locked by another server"
					return nil
				end
				local data = if record then clone(record.data) else clone(template)
				reconcile(data, template)
				local fence = if lockIsMine(record, lease.token) then record.lock.fence
					else ((record and record.fence) or 0) + 1
				return { data = data, lock = sessionTag(lease.token, fence), fence = fence }
			end)
		end)
		if not ok then return nil, tostring(committed) end
		if not lockIsMine(committed, lease.token) then return nil, refusal or "lock not acquired" end
		lease.fence = committed.fence
		return committed.data, nil
	end

	function store:load(player: Player): Profile?
		if closing then return nil end
		if profiles[player.UserId] ~= nil then
			return if profiles[player.UserId].active then profiles[player.UserId] else nil
		end
		if loading[player.UserId] then return nil end
		loading[player.UserId] = true
		leases[player.UserId] = { token = HttpService:GenerateGUID(false), busy = false }

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
				loading[player.UserId] = nil
				if not player.Parent or closing then store:release(player); return nil end
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
				loading[player.UserId] = nil
				return nil
			end
		end

		loading[player.UserId] = nil
		statistics.refusedLoads += 1
		return nil
	end

	function store:get(player: Player): Profile?
		local profile = profiles[player.UserId]
		return if profile and profile.active then profile else nil
	end

	function store:save(player: Player): boolean
		local profile = profiles[player.UserId]
		if profile == nil or not profile.active then
			return false
		end
		--: Memory mode writes to the table `acquire` reads from, so a profile
		--: saved and loaded again inside one session round-trips. It still
		--: does not survive a restart, and the warning at construction is the
		--: only promise made about that.
		if not persistent then
			memory[profile.userId] = profile.data
			profile.saves += 1
			statistics.saves += 1
			return true
		end

		local lease = leases[player.UserId]
		if not lease or lease.busy then return false end
		lease.busy = true
		local payload = clone(profile.data)
		local ok, committed = pcall(function()
			return dataStore:UpdateAsync(key(profile.userId), function(record)
				if not lockIsMine(record, lease.token, lease.fence) then return nil end
				return { data = payload, lock = sessionTag(lease.token, lease.fence), fence = lease.fence }
			end)
		end)
		lease.busy = false
		if ok and lockIsMine(committed, lease.token, lease.fence) then
			profile.saves += 1
			statistics.saves += 1
			return true
		end
		profile.active = false
		statistics.saveFailures += 1
		return false
	end

	function store:release(player: Player): boolean
		local profile = profiles[player.UserId]
		if not profile or not profile.active then return false end
		local lease = leases[player.UserId]
		local deadline = os.clock() + 20
		while lease and lease.busy and os.clock() < deadline do task.wait(0.05) end
		if lease and lease.busy then return false end
		if not persistent then
			memory[player.UserId] = clone(profile.data)
			profile.active = false
			profiles[player.UserId] = nil
			return true
		end
		lease.busy = true
		local releaseId = HttpService:GenerateGUID(false)
		local payload = clone(profile.data)
		local ok, committed = pcall(function()
			return dataStore:UpdateAsync(key(profile.userId), function(record)
				if not lockIsMine(record, lease.token, lease.fence) then return nil end
				return { data = payload, fence = lease.fence, releaseId = releaseId }
			end)
		end)
		lease.busy = false
		local released = ok and type(committed) == "table" and committed.releaseId == releaseId
		profile.active = false
		if released then
			profiles[player.UserId] = nil
			leases[player.UserId] = nil
			statistics.saves += 1
		else
			statistics.saveFailures += 1
		end
		return released
	end

	function store:releaseAll(): number
		closing = true
		local count, pending = 0, 0
		for userId in pairs(profiles) do
			pending += 1
			task.spawn(function()
				-- Release by identity even if PlayerRemoving already detached it.
				local ok, released = pcall(function()
					return store:release({ UserId = userId } :: any)
				end)
				if ok and released then count += 1 end
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while (pending > 0 or next(loading) ~= nil) and os.clock() < deadline do task.wait(0.05) end
		statistics.shutdownPending = pending
		return count
	end

	function store:statistics(): { [string]: any }
		local held = 0
		for _ in pairs(profiles) do
			held += 1
		end
		local report = table.clone(statistics)
		report.heldProfiles = held
		report.persistent = persistent
		report.closing = closing
		return report
	end

	if opts.autoWire ~= false then
		Players.PlayerRemoving:Connect(function(player)
			store:release(player)
		end)

		-- Heartbeat: refresh the lock so a long-lived session is never mistaken
		-- for a crashed one, and autosave so a crash costs minutes, not hours.
		task.spawn(function()
			while not closing do
				task.wait(HEARTBEAT_SECONDS)
				if closing then break end
				for userId in pairs(profiles) do
					local player = Players:GetPlayerByUserId(userId)
					if player ~= nil then
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
