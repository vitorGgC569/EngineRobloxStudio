--!strict
--[[
	LiveOps — changing a running game without shipping a new one.

	A game that can only be changed by publishing is a game whose every
	balance tweak costs a release and whose every mistake costs a rollback.
	Everything here exists so a number can be moved, a feature can be switched
	off, or an experiment can be started, while people are playing.

	Four things, because they are one mechanism wearing four hats:

	  config   a value the server reads instead of a constant
	  flags    a config value that is a boolean, with a kill switch
	  bucket   a config value chosen per player, which is an experiment
	  text     a config value chosen per locale, which is localisation

	--- Where the values come from -----------------------------------------

	A real DataStore, read on an interval, with the last good values kept in
	memory. That ordering matters more than it looks: a DataStore outage must
	never take the game down, so a failed refresh leaves the previous values in
	place and says so. A config system that fails closed turns a Roblox
	incident into your incident.

		LiveOps.define("enemy.maxAlive", 14)
		LiveOps.flag("newLootTable", false)
		LiveOps.experiment("firstSessionLength", { "control", "longer" })

		local cap = LiveOps.get("enemy.maxAlive")
		if LiveOps.enabled("newLootTable") then ... end
		local arm = LiveOps.bucket(player, "firstSessionLength")

	--- Bucketing --------------------------------------------------------------

	Assignment is a hash of the player's id and the experiment name, not a
	random roll. A player therefore lands in the same arm on every server, on
	every session, forever — which is the difference between an experiment and
	noise. It also means no state has to be stored to remember the decision.
]]

local DataStoreService = game:GetService("DataStoreService")
local LocalizationService = game:GetService("LocalizationService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local LiveOps = {}

export type Experiment = {
	name: string,
	arms: { string },
	weights: { number }?,
	enabled: boolean,
}

LiveOps.config = {
	store = "ForgeLiveOps",
	key = "config/v1",
	refreshSeconds = 60,
	-- A game that cannot reach the store still has to run. It runs on
	-- defaults, loudly.
	failOpen = true,
}

local defaults: { [string]: any } = {}
local remote: { [string]: any } = {}
local experiments: { [string]: Experiment } = {}
local strings: { [string]: { [string]: string } } = {}

local lastRefresh = 0
local lastError: string? = nil
local refreshes, failures = 0, 0
local refreshConn: thread? = nil

-- ================================== config ==================================
--[[
	Declare a value and its default.

	The default is the contract: it is what the game runs on with no network,
	on the first frame, and whenever the store disagrees about types. Declaring
	up front also means `describe()` can list every knob a game has, which is
	what makes this auditable rather than a bag of magic strings.
]]
function LiveOps.define(key: string, default: any)
	defaults[key] = default
	return default
end

function LiveOps.defineMany(table_: { [string]: any })
	for key, value in table_ do
		defaults[key] = value
	end
end

--[[
	Read a value.

	Remote wins over default, but only when it is the same type. A config push
	that turns a number into a string would otherwise propagate a type error
	into gameplay code minutes after the deploy that caused it, which is the
	worst possible place to find it.
]]
function LiveOps.get(key: string): any
	local fallback = defaults[key]
	local value = remote[key]
	if value == nil then
		return fallback
	end
	if fallback ~= nil and typeof(value) ~= typeof(fallback) then
		return fallback
	end
	return value
end

function LiveOps.set(key: string, value: any)
	remote[key] = value
end

-- =================================== flags ==================================
function LiveOps.flag(name: string, default: boolean)
	defaults["flag." .. name] = default
end

function LiveOps.enabled(name: string): boolean
	return LiveOps.get("flag." .. name) == true
end

--[[
	Turn something off right now.

	Local only, and deliberately: a kill switch that has to round-trip to a
	DataStore before it takes effect is not a kill switch. Pushing the same
	value remotely is how it becomes permanent.
]]
function LiveOps.kill(name: string)
	remote["flag." .. name] = false
end

-- ================================ experiments ===============================
function LiveOps.experiment(name: string, arms: { string }, options: any?)
	local opts = options or {}
	experiments[name] = {
		name = name,
		arms = arms,
		weights = opts.weights,
		enabled = opts.enabled ~= false,
	}
end

--[[
	Which arm this player is in.

	FNV-1a over "<userId>:<experiment>". Deterministic, uniform enough for
	bucketing, and identical on every server — a player who reconnects mid
	session does not silently change arms and corrupt the result.
]]
local function hash(text: string): number
	local h = 2166136261
	for i = 1, #text do
		h = bit32.bxor(h, string.byte(text, i))
		h = (h * 16777619) % 4294967296
	end
	return h
end

function LiveOps.bucket(player: Player, name: string): string?
	local experiment = experiments[name]
	if not experiment or not experiment.enabled or #experiment.arms == 0 then
		return nil
	end
	local point = hash(tostring(player.UserId) .. ":" .. name) % 10000 / 10000

	local weights = experiment.weights
	if weights and #weights == #experiment.arms then
		local total = 0
		for _, w in weights do
			total += w
		end
		local cursor = 0
		for index, w in weights do
			cursor += w / total
			if point <= cursor then
				return experiment.arms[index]
			end
		end
	end
	return experiment.arms[math.floor(point * #experiment.arms) + 1]
end

function LiveOps.experiments(): { string }
	local out = {}
	for name in experiments do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- =============================== localisation ===============================
--[[
	Translated text, by locale.

	Not a wrapper over Roblox's translation tables on purpose: those are
	authored in Studio and shipped with the place, which puts a typo fix behind
	a release. These live in the same config the rest of this module reads, so
	a wrong string is fixed in the time it takes to write it.

	`LiveOps.text` always returns something. A missing key returns the key
	itself, which renders as visible nonsense in the UI — far better than an
	empty label, because it is impossible to miss in testing.
]]
function LiveOps.strings(locale: string, table_: { [string]: string })
	strings[locale] = strings[locale] or {}
	for key, value in table_ do
		strings[locale][key] = value
	end
end

function LiveOps.text(key: string, locale: string?): string
	local want = locale or "en-us"
	local table_ = strings[want] or strings[want:sub(1, 2)] or strings["en-us"]
	if table_ and table_[key] then
		return table_[key]
	end
	return key
end

function LiveOps.localeOf(player: Player): string
	local ok, locale = pcall(function()
		return player.LocaleId
	end)
	if ok and typeof(locale) == "string" and locale ~= "" then
		return locale:lower()
	end
	return "en-us"
end

function LiveOps.textFor(player: Player, key: string): string
	return LiveOps.text(key, LiveOps.localeOf(player))
end

-- ================================= refresh ==================================
--[[
	Pull the live values.

	Server only. A client that read config directly would be a client that can
	be told a different config, and every value here is a value somebody would
	like to choose for themselves.
]]
function LiveOps.refresh(): boolean
	if not RunService:IsServer() then
		return false
	end
	local ok, result = pcall(function()
		local store = DataStoreService:GetDataStore(LiveOps.config.store)
		return store:GetAsync(LiveOps.config.key)
	end)

	refreshes += 1
	if not ok then
		failures += 1
		lastError = tostring(result)
		-- Previous values stay in place. An outage must not become a config
		-- reset, which would be far more damaging than stale numbers.
		return false
	end

	lastError = nil
	lastRefresh = os.clock()
	if typeof(result) ~= "table" then
		return true
	end

	local payload = result :: any
	if typeof(payload.values) == "table" then
		for key, value in payload.values do
			remote[key] = value
		end
	end
	if typeof(payload.strings) == "table" then
		for locale, table_ in payload.strings do
			if typeof(table_) == "table" then
				LiveOps.strings(locale, table_)
			end
		end
	end
	if typeof(payload.experiments) == "table" then
		for name, spec in payload.experiments do
			if typeof(spec) == "table" and typeof(spec.arms) == "table" then
				LiveOps.experiment(name, spec.arms, spec)
			end
		end
	end
	return true
end

function LiveOps.start()
	if refreshConn or not RunService:IsServer() then
		return
	end
	refreshConn = task.spawn(function()
		while true do
			LiveOps.refresh()
			task.wait(LiveOps.config.refreshSeconds)
		end
	end)
end

function LiveOps.describe(): { [string]: any }
	local keys = {}
	for key in defaults do
		table.insert(keys, key)
	end
	table.sort(keys)

	local locales = {}
	for locale in strings do
		table.insert(locales, locale)
	end
	table.sort(locales)

	return {
		context = RunService:IsServer() and "server" or "client",
		keys = keys,
		overridden = (function()
			local n = 0
			for _ in remote do
				n += 1
			end
			return n
		end)(),
		experiments = LiveOps.experiments(),
		locales = locales,
		refreshes = refreshes,
		failures = failures,
		lastError = lastError,
		secondsSinceRefresh = lastRefresh > 0 and math.floor(os.clock() - lastRefresh) or nil,
	}
end

return LiveOps
