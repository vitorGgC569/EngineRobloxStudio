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

local config = {
	store = "ForgeProfiles",
	template = {},
	version = 1,
	migrations = {},
	autosaveInterval = 120,
	retries = 4,
	sessionLock = true,
	enabled = true,
}

local store: DataStore? = nil
local profiles: { [Player]: any } = {}
local loading: { [Player]: boolean } = {}
local started = false

-- In Studio without API access, DataStore calls fail. Rather than spraying
-- errors, Forge falls back to memory so the whole game still runs — and says
-- so once, loudly, so nobody mistakes it for persistence.
local memoryOnly = false

function Save.configure(options: any)
	for key, value in options do
		config[key] = value
	end
	if config.enabled then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(config.store)
		end)
		store = ok and result or nil
		if not ok then
			memoryOnly = true
			warn("[Save] DataStore unavailable; running in MEMORY-ONLY mode. Nothing will persist.")
		else
			-- `GetDataStore` succeeds even with API access switched off; only the
			-- calls fail. Without this one probe every player load burns the full
			-- retry ladder (~3.5s of backoff) before falling back — which in Studio
			-- reads as the game taking forever to start for no visible reason.
			local reachable = pcall(function()
				(store :: DataStore):GetAsync("__forge_probe")
			end)
			if not reachable then
				memoryOnly = true
				warn("[Save] DataStore is not reachable (Studio API access off?); running in MEMORY-ONLY mode. Nothing will persist.")
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
	if from >= config.version then
		data.__version = config.version
		return
	end
	for v = from + 1, config.version do
		local step = config.migrations[v]
		if step then
			local ok, err = pcall(step, data)
			if not ok then
				warn(string.format("[Save] migration to v%d failed: %s", v, tostring(err)))
			end
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
local jobId = game.JobId ~= "" and game.JobId or "studio"

local function load(player: Player): any
	local data: any = nil

	if store and not memoryOnly then
		local ok, result = retry("load " .. player.Name, function()
			return (store :: DataStore):UpdateAsync(keyFor(player), function(old)
				if old and config.sessionLock and old.__lock then
					-- A lock older than five minutes is a crashed server, not a
					-- live one. Without this check a crash locks a player out.
					local age = os.time() - (old.__lockTime or 0)
					if old.__lock ~= jobId and age < 300 then
						return nil -- refuse: another server holds it
					end
				end
				local next_ = old or {}
				next_.__lock = jobId
				next_.__lockTime = os.time()
				return next_
			end)
		end)
		if ok and result then
			data = result
		elseif ok then
			warn(string.format("[Save] %s is locked by another server; using a temporary profile", player.Name))
		end
	end

	-- Integrity gate. A profile that does not match its own checksum is not
	-- handed to the game: the newest backup that verifies is used instead, and
	-- the damaged copy is kept under `__quarantine` so it can be inspected
	-- rather than overwritten on the next autosave.
	if data and data.__checksum and not verify(data) then
		warn(string.format("[Save] %s: profile failed its checksum", player.Name))
		local recovered = nil
		for _, backup in (data.__backups or {}) do
			if verify(backup) then
				recovered = deepCopy(backup)
				break
			end
		end
		if recovered then
			warn(string.format(
				"[Save] %s: rolled back to a backup from %s",
				player.Name, os.date("!%Y-%m-%d %H:%M", recovered.__savedAt or 0)
			))
			recovered.__quarantine = { reason = "checksum", at = os.time() }
			recovered.__backups = data.__backups
			data = recovered
		else
			warn(string.format("[Save] %s: no usable backup; starting from the template", player.Name))
			data = { __quarantine = { reason = "checksum-nobackup", at = os.time() } }
		end
	end

	data = data or {}
	migrate(data)
	reconcile(data, config.template)
	data.__version = config.version
	return data
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
	if not profile then
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

function Save.write(player: Player, release: boolean?): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	Save.onSaving:Fire(player, profile)

	if memoryOnly or not store then
		return false
	end

	local payload = deepCopy(profile)
	payload.__version = config.version
	payload.__lock = release and nil or jobId
	payload.__lockTime = os.time()
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

	local written = retry("save " .. player.Name, function()
		(store :: DataStore):SetAsync(keyFor(player), payload)
		return true
	end)
	if written then
		profile.__backups = kept
	end
	return written
end

function Save.get(player: Player): any?
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
	return profiles[player] ~= nil
end

-- Waits for the profile, with a timeout. Any system that needs a profile on
-- join should call this rather than assuming load order.
function Save.await(player: Player, timeout: number?): any?
	local deadline = os.clock() + (timeout or 15)
	while os.clock() < deadline do
		local profile = profiles[player]
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
	if profiles[player] or loading[player] then
		return
	end
	loading[player] = true

	local profile = load(player)
	loading[player] = nil

	-- they may have left while we were loading
	if not player.Parent then
		return
	end

	profiles[player] = profile
	Save.onLoaded:Fire(player, profile)
end

local function releasePlayer(player: Player)
	if not profiles[player] then
		return
	end
	Save.write(player, true)
	profiles[player] = nil
	Save.onReleased:Fire(player)
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
		while true do
			task.wait(config.autosaveInterval)
			for player in profiles do
				Save.write(player)
			end
		end
	end)

	game:BindToClose(function()
		for player in profiles do
			task.spawn(releasePlayer, player)
		end
		task.wait(RunService:IsStudio() and 1 or 4)
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
