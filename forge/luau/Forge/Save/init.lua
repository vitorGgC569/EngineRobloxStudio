--!strict
--[[
	Save — player profiles that survive, migrate and do not corrupt.

	Three failures this exists to prevent, all of which are invisible in Studio
	and expensive in production:

	1. No session lock. Two servers hold the same profile, the second one saves
	   last, and a player loses an evening of progress.
	2. No migration. You add a field, every returning player has `nil` where a
	   number should be, and a dozen systems break in ways that look unrelated.
	3. No retry, no BindToClose. The server shuts down mid-write and the save
	   is simply gone.

		Save.configure({
			store = "Profiles_v1",
			template = { level = 1, gold = 0, inventory = {} },
			migrations = {
				[2] = function(data) data.attributes = data.attributes or {} end,
			},
			version = 2,
		})

		Save.onLoaded:Connect(function(player, profile) ... end)
		local profile = Save.get(player)
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Core.Signal)

local Save = {}

Save.onLoaded = Signal.new() -- (player, profile)
Save.onSaving = Signal.new() -- (player, profile) — last chance to write into it
Save.onReleased = Signal.new() -- (player)
Save.onFailed = Signal.new() -- (player, reason); no writable fallback on failure

local config = {
	store = "ForgeProfiles",
	template = {},
	version = 1,
	migrations = {},
	autosaveInterval = 120,
	retries = 4,
	sessionLock = true,
	enabled = true,
	allowStudioMemory = true,
	lockTimeout = 300,
	shutdownTimeout = 25,
}

local store: DataStore? = nil
local profiles: { [Player]: any } = {}
local loading: { [Player]: boolean } = {}
local started = false
local closing = false
local sessions: { [Player]: any } = {}
local failures: { [Player]: string } = {}

-- In Studio without API access, DataStore calls fail. Rather than spraying
-- errors, Forge falls back to memory so the whole game still runs — and says
-- so once, loudly, so nobody mistakes it for persistence.
local memoryOnly = false

function Save.configure(options: any)
	assert(not started, "[Save] configure must run before start")
	for key, value in options do
		config[key] = value
	end
	assert(config.autosaveInterval < config.lockTimeout / 2, "[Save] autosave must renew the lock before expiry")
	memoryOnly = not config.enabled
	store = nil
	if config.enabled then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(config.store)
		end)
		store = ok and result or nil
		if not ok then
			memoryOnly = RunService:IsStudio() and config.allowStudioMemory == true
			warn(if memoryOnly then "[Save] Studio MEMORY-ONLY mode. Nothing will persist." else "[Save] DataStore unavailable; profile loads will be refused.")
		else
			-- `GetDataStore` succeeds even with API access switched off; only the
			-- calls fail. Without this one probe every player load burns the full
			-- retry ladder (~3.5s of backoff) before falling back — which in Studio
			-- reads as the game taking forever to start for no visible reason.
			local reachable = pcall(function()
				(store :: DataStore):GetAsync("__forge_probe")
			end)
			if not reachable then
				memoryOnly = RunService:IsStudio() and config.allowStudioMemory == true
				warn(if memoryOnly then "[Save] Studio MEMORY-ONLY mode. Nothing will persist." else "[Save] DataStore probe failed; loads require a successful transaction.")
			end
		end
	else
		memoryOnly = true
	end
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

-- Fills in anything the template has and the saved data does not. This is what
-- makes adding a field to the template safe for existing players.
local function reconcile(data: any, template: any)
	for key, value in template do
		if data[key] == nil then
			data[key] = deepCopy(value)
		elseif type(value) == "table" and type(data[key]) == "table" then
			reconcile(data[key], value)
		end
	end
end

local function migrate(data: any)
	local from = data.__version or 1
	assert(type(from) == "number" and from % 1 == 0 and from >= 1, "invalid profile version")
	assert(from <= config.version, "profile was written by a newer schema; upgrade required")
	if from == config.version then
		return
	end
	for v = from + 1, config.version do
		local step = config.migrations[v]
		if step then
			step(data) -- exceptions abort UpdateAsync; never stamp partial migrations
		end
	end
	data.__version = config.version
end

local function keyFor(player: Player): string
	return "p_" .. player.UserId
end

--[[
	Integrity and backups.

	A DataStore does not corrupt data on its own; games corrupt it — a half
	written table from a crashed coroutine, a migration that threw halfway, a
	field set to NaN that JSON cannot round-trip. The failure is silent until a
	player logs in to an empty profile.

	So every write carries a checksum of its own contents and a short history of
	previous good versions. A load that fails the checksum falls back to the
	newest backup that passes, and says so loudly instead of handing the game an
	empty table.
]]
local BACKUP_KEEP = 3
local BACKUP_MAX_BYTES = 180000 -- keep history only while the profile is small

local function stableEncode(value: any): string
	-- Key order must not vary between the write and the check, so keys are
	-- sorted. `JSONEncode` alone would produce a different string for the same
	-- table on a different run and every checksum would fail.
	local kind = type(value)
	if kind ~= "table" then
		if kind == "number" and value ~= value then
			return "null" -- NaN: not representable, and a real source of corruption
		end
		return HttpService:JSONEncode(value)
	end

	local keys = {}
	for key in value do
		if type(key) == "string" or type(key) == "number" then
			table.insert(keys, key)
		end
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)

	local parts = {}
	for _, key in keys do
		if string.sub(tostring(key), 1, 2) == "__" then
			continue -- metadata never feeds its own checksum
		end
		table.insert(parts, HttpService:JSONEncode(tostring(key)) .. ":" .. stableEncode(value[key]))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function checksum(data: any): string
	local text = stableEncode(data)
	-- FNV-1a: deterministic across machines, which a table address is not.
	local hash = 2166136261
	for index = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, index))
		hash = (hash * 16777619) % 4294967296
	end
	return string.format("%08x:%d", hash, #text)
end

Save.checksum = checksum

--[[
	Does this payload's checksum match its contents?

	Public because it is the single most important decision `Save` makes and it
	was, until now, untestable: a corrupted profile has to be treated as absent,
	since loading half of one leaves a player with their level and none of their
	inventory. Exposing it lets a live suite stage a deliberately corrupt record
	and prove the refusal actually happens.
]]
local function verify(data: any): boolean
	if type(data) ~= "table" or type(data.__checksum) ~= "string" then
		return false -- pre-checksum saves: treated as unverified, not as corrupt
	end
	return checksum(data) == data.__checksum
end

Save.verify = verify

local function retry<T>(label: string, fn: () -> T): (boolean, T?)
	local delaySeconds = 0.5
	for attempt = 1, config.retries do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		if attempt == config.retries then
			warn(string.format("[Save] %s failed after %d attempts: %s", label, attempt, tostring(result)))
			return false, nil
		end
		task.wait(delaySeconds)
		delaySeconds *= 2
	end
	return false, nil
end

-- =============================== load / save ================================
local function failProfile(player: Player, reason: string)
	failures[player] = reason
	warn(string.format("[Save] %s: %s", player.Name, reason))
	Save.onFailed:Fire(player, reason)
end

local function load(player: Player): any
	if memoryOnly then
		local data = deepCopy(config.template)
		data.__version = config.version
		return data
	end
	if not store then
		failProfile(player, "DATASTORE_UNAVAILABLE")
		return nil
	end
	local token = HttpService:GenerateGUID(false)
	local reason = "LOAD_FAILED"
	local ok, result = retry("load " .. player.Name, function()
		return (store :: DataStore):UpdateAsync(keyFor(player), function(old)
			if old ~= nil and type(old) ~= "table" then
				reason = "CORRUPT_RECORD"
				return nil
			end
			if old and old.__lock and old.__lock ~= token
				and os.time() - (old.__lockTime or 0) < config.lockTimeout then
				reason = "SESSION_LOCKED"
				return nil
			end
			local next_ = deepCopy(old or {})
			-- Leave corrupt data intact for explicit support recovery. Automatic
			-- rollback can also undo paid rewards while retaining their receipts.
			if next_.__checksum and not verify(next_) then
				reason = "CHECKSUM_FAILED"
				return nil
			end
			local migrated, migrationError = pcall(migrate, next_)
			if not migrated then
				reason = "MIGRATION_REFUSED: " .. tostring(migrationError)
				return nil
			end
			reconcile(next_, config.template)
			next_.__fence = if next_.__lock == token then next_.__fence else (next_.__fence or 0) + 1
			next_.__lock = token
			next_.__lockTime = os.time()
			next_.__checksum = checksum(next_)
			return next_
		end)
	end)
	if not ok or not result or result.__lock ~= token then
		failProfile(player, reason)
		return nil
	end
	sessions[player] = { token = token, fence = result.__fence, active = true, busy = false }
	failures[player] = nil
	return result
end

--[[
	Backups a game can offer to a player or a moderator.

	Returned newest first, with the timestamp and whether each one still
	verifies — a backup that fails its own checksum is worse than none, because
	restoring it looks like it worked.
]]
function Save.backups(player: Player): { any }
	local profile = profiles[player]
	local out = {}
	for index, backup in ((profile and profile.__backups) or {}) do
		table.insert(out, {
			index = index,
			savedAt = backup.__savedAt,
			verified = verify(backup),
			version = backup.__version,
		})
	end
	table.sort(out, function(a, b)
		return (a.savedAt or 0) > (b.savedAt or 0)
	end)
	return out
end

--[[
	Restore one. The current profile becomes a backup first, so a rollback is
	itself undoable — a rollback that destroys the thing it replaced is how a
	support ticket becomes two.
]]
function Save.rollback(player: Player, index: number): boolean
	local profile = profiles[player]
	if not profile or (sessions[player] and sessions[player].busy) then
		return false
	end
	local backup = (profile.__backups or {})[index]
	if not backup then
		return false
	end
	if not verify(backup) then
		warn(string.format("[Save] %s: backup %d does not verify; refusing", player.Name, index))
		return false
	end
	-- A backup predating a paid grant cannot undo the reward and keep the
	-- receipt consumed, or erase the receipt and permit a duplicate purchase.
	if HttpService:JSONEncode(profile.__receipts or {}) ~= HttpService:JSONEncode(backup.__receipts or {}) then
		return false
	end
	if backup.__version ~= config.version then
		return false
	end

	local history = profile.__backups or {}
	local previous = deepCopy(profile)
	previous.__backups = nil
	previous.__savedAt = os.time()
	previous.__checksum = checksum(previous)

	local restored = deepCopy(backup)
	restored.__backups = history
	table.insert(restored.__backups, 1, previous)
	while #restored.__backups > BACKUP_KEEP do
		table.remove(restored.__backups)
	end

	reconcile(restored, config.template)
	profiles[player] = restored
	warn(string.format("[Save] %s: rolled back to backup %d", player.Name, index))
	Save.onLoaded:Fire(player, restored)
	return true
end

local function writeUnlocked(player: Player, release: boolean?, override: any?): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	local session = sessions[player]
	if memoryOnly or not store or not session or not session.active then
		return false
	end

	local payload = deepCopy(override or profile)
	payload.__version = config.version
	if release then
		payload.__lock = nil
		payload.__lockTime = nil
	else
		payload.__lock = session.token
		payload.__lockTime = os.time()
	end
	payload.__fence = session.fence
	payload.__writeId = HttpService:GenerateGUID(false)
	payload.__savedAt = os.time()

	-- Rotate history, then checksum. The checksum covers the profile's own
	-- fields only (stableEncode skips `__` keys), so adding a backup does not
	-- invalidate the hash of the thing it is backing up.
	local history = profile.__backups
	payload.__backups = nil
	payload.__checksum = checksum(payload)

	local snapshot = deepCopy(payload)
	snapshot.__lock = nil
	snapshot.__lockTime = nil

	local kept = {}
	table.insert(kept, snapshot)
	for _, backup in (history or {}) do
		if #kept >= BACKUP_KEEP then
			break
		end
		table.insert(kept, backup)
	end

	-- History is a luxury, not a requirement: a profile close to the 4 MB key
	-- limit gets none rather than failing every write from here on.
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if ok and #encoded < BACKUP_MAX_BYTES then
		payload.__backups = kept
	else
		payload.__backups = nil
		if ok then
			warn(string.format("[Save] %s: profile is %d bytes; keeping no backups", player.Name, #encoded))
		end
	end

	local written, result = retry("save " .. player.Name, function()
		return (store :: DataStore):UpdateAsync(keyFor(player), function(old)
			-- Retry after an uncertain response returns the committed operation.
			if type(old) == "table" and old.__writeId == payload.__writeId then
				return old
			end
			if type(old) ~= "table" or old.__lock ~= session.token or old.__fence ~= session.fence then
				return nil
			end
			return deepCopy(payload)
		end)
	end)
	if written and result and result.__writeId == payload.__writeId then
		profile.__backups = kept
		if release then
			session.active = false
		end
		return true
	end
	-- After an uncertain write, allowing another snapshot could erase a
	-- purchase that did commit. Require recovery through a fresh load.
	session.active = false
	failProfile(player, if written then "SESSION_LOST" else "WRITE_UNCERTAIN")
	return false
end

function Save.write(player: Player, release: boolean?): boolean
	local session = sessions[player]
	if not session or not session.active or session.busy then
		return false
	end
	session.busy = true
	local ok, written = pcall(function()
		Save.onSaving:Fire(player, profiles[player])
		return writeUnlocked(player, release)
	end)
	session.busy = false
	if not ok then
		failProfile(player, "WRITE_FAILED: " .. tostring(written))
	end
	return ok and written == true
end

-- Reducers may run more than once. They must only edit their argument, must
-- not yield, and must not grant instances, fire remotes or mutate other state.
local function reduce(fn: (any) -> any, data: any): boolean
	local thread = coroutine.create(fn)
	local ok, accepted = coroutine.resume(thread, data)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return false
	end
	return ok and accepted ~= false
end

function Save.commitReceipt(player: Player, receiptId: string, reducer: (any) -> any): (boolean, boolean)
	local profile = profiles[player]
	local session = sessions[player]
	if type(receiptId) ~= "string" or receiptId == "" or not profile or not session
		or not session.active or session.busy or memoryOnly then
		return false, false
	end
	if (profile.__receipts or {})[receiptId] then
		return true, false
	end
	session.busy = true
	local ok, committed = pcall(function()
		Save.onSaving:Fire(player, profile)
		local payload = deepCopy(profile)
		if not reduce(reducer, payload) then
			return false
		end
		payload.__receipts = payload.__receipts or {}
		payload.__receipts[receiptId] = { at = os.time() }
		if not writeUnlocked(player, false, payload) then
			return false
		end
		-- Gameplay may have accumulated more unsaved progress while the store
		-- yielded. Apply the same pure reward to that current state, preserving
		-- the profile reference held by systems observing Save.onLoaded.
		if not reduce(reducer, profile) then
			session.active = false
			profiles[player] = nil
			failProfile(player, "RECEIPT_LOCAL_RECONCILIATION_FAILED")
			return false
		end
		profile.__receipts = deepCopy(payload.__receipts)
		return true
	end)
	session.busy = false
	if not ok then
		failProfile(player, "RECEIPT_FAILED: " .. tostring(committed))
	end
	return ok and committed == true, ok and committed == true
end

function Save.status(player: Player): any
	local session = sessions[player]
	return {
		loaded = profiles[player] ~= nil,
		persistent = session ~= nil and session.active and not memoryOnly,
		busy = session ~= nil and session.busy,
		memoryOnly = memoryOnly,
		error = failures[player],
	}
end

function Save.get(player: Player): any?
	if sessions[player] and not sessions[player].active then
		return nil
	end
	return profiles[player]
end

--[[
	Connect to onLoaded AND replay it for everyone already loaded.

	This exists because of a bug that cost a session: in Studio the local player
	joins at server start, so `Save.start()` loads and fires `onLoaded` while the
	bootstrap is still setting up. A listener connected forty lines later — after
	terrain generation, say — never hears it, no character ever spawns, and the
	game looks like it simply did not run.

	`onLoaded:Connect` has that hazard by construction. `observe` does not, so
	prefer it for anything that must happen once per player.
]]
function Save.observe(fn: (Player, any) -> ()): any
	local connection = Save.onLoaded:Connect(fn)
	for player, profile in profiles do
		task.spawn(fn, player, profile)
	end
	return connection
end

function Save.isLoaded(player: Player): boolean
	return Save.get(player) ~= nil
end

-- Waits for the profile, with a timeout. Any system that needs a profile on
-- join should call this rather than assuming load order.
function Save.await(player: Player, timeout: number?): any?
	local deadline = os.clock() + (timeout or 15)
	while os.clock() < deadline do
		local profile = Save.get(player)
		if profile then
			return profile
		end
		if not player.Parent then
			return nil
		end
		task.wait(0.1)
	end
	warn(string.format("[Save] timed out waiting for %s's profile", player.Name))
	return nil
end

-- ============================== lifecycle ===================================
local function handlePlayer(player: Player)
	if closing or profiles[player] or loading[player] then
		return
	end
	loading[player] = true

	local profile = load(player)
	loading[player] = nil

	-- they may have left while we were loading
	if not profile then
		return
	end

	profiles[player] = profile
	if not player.Parent or closing then
		Save.write(player, true)
		profiles[player] = nil
		return
	end
	Save.onLoaded:Fire(player, profile)
end

local function releasePlayer(player: Player)
	if not profiles[player] then
		return
	end
	local deadline = os.clock() + config.shutdownTimeout
	while sessions[player] and sessions[player].busy and os.clock() < deadline do
		task.wait(0.05)
	end
	if memoryOnly or Save.write(player, true) then
		profiles[player] = nil
		sessions[player] = nil
		Save.onReleased:Fire(player)
	end
end

function Save.flush(timeoutSeconds: number?): any
	closing = true
	local deadline = os.clock() + (timeoutSeconds or config.shutdownTimeout)
	local pending = 0
	local failed = 0
	for player in profiles do
		pending += 1
		task.spawn(function()
			releasePlayer(player)
			if profiles[player] then
				failed += 1
			end
			pending -= 1
		end)
	end
	while (pending > 0 or next(loading) ~= nil) and os.clock() < deadline do
		task.wait(0.05)
	end
	return { complete = pending == 0 and failed == 0 and next(loading) == nil, pending = pending, failed = failed }
end

function Save.start()
	if started then
		return
	end
	started = true

	Players.PlayerAdded:Connect(handlePlayer)
	-- Players who joined before this ran — routine in Studio, where world
	-- generation delays the bootstrap past the local player's arrival.
	for _, player in Players:GetPlayers() do
		task.spawn(handlePlayer, player)
	end

	Players.PlayerRemoving:Connect(releasePlayer)

	task.spawn(function()
		while not closing do
			task.wait(config.autosaveInterval)
			if closing then break end
			for player in profiles do
				Save.write(player)
			end
		end
	end)

	game:BindToClose(function()
		local result = Save.flush()
		if not result.complete then
			warn("[Save] shutdown did not flush every profile before its deadline")
		end
	end)
end

function Save.describe(): { [string]: any }
	local count = 0
	for _ in profiles do
		count += 1
	end
	return {
		store = config.store,
		version = config.version,
		loadedProfiles = count,
		memoryOnly = memoryOnly,
		sessionLock = config.sessionLock,
	}
end


--[[
	Siblings, resolved on the first thing that asks for one.

	This family holds modules beside this file, and until now the only way to
	reach them was to require the instance directly — so `Forge.Save.DataStoreAdapter`
	was nil while `require(ReplicatedStorage.Forge.Save.DataStoreAdapter)` worked. Two
	conventions in one engine, and the inconsistency is the defect: the first
	game written against `Forge.Core.Boot` died on `attempt to index nil`.

	Lazy rather than eager, matching `Forge` itself. Touching one family must
	not drag in every module it contains — several of them build tables and
	open connections at load, and paying for all of that to read one constant
	is how a require graph becomes a frame budget.
]]
return setmetatable(Save, {
	__index = function(self, key: string): any
		local child = script:FindFirstChild(key)
		if not child or not child:IsA("ModuleScript") then
			return nil
		end
		local module = require(child) :: any
		rawset(self, key, module)
		return module
	end,
})
