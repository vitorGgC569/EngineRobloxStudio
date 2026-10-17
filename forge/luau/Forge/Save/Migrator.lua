--!strict
--[[
	Migrator — versioned, side-effect-free profile upgrades.

	Saved data outlives code. The moment a field changes meaning instead of
	being added, every returning profile is misread in ways that look like
	unrelated bugs — unless each old shape has an explicit step to the next.
	Migrator runs those steps in ascending order from the stored version and
	then reconciles the template so no field is ever nil where the game expects
	a value.

		local migrator = Migrator.new({
			version = 3,
			migrations = {
				[2] = function(data) return data end,
			},
			defaults = { level = 1, wallet = { gold = 0 } },
		})
		local result = migrator:migrate(loadedData)

	Returns `{ data, fromVersion, toVersion }`. Profiles written by a NEWER
	build are reconciled but never downgraded or re-stamped — this server does
	not know what those fields mean yet.

	Pure: the input table is copied first, transforms receive the copy, and
	nothing here touches DataStores (the adapter owns that).
]]

export type Migration = (data: any) -> any

export type Config = {
	version: number,
	migrations: { [number]: Migration },
	defaults: any?,
}

type Instance = {
	_version: number,
	_migrations: { [number]: Migration },
	_defaults: any,
}

local Migrator = {}
Migrator.__index = Migrator

-- Structural copy of plain-data tables. `seen` guards against cycles so a
-- pathological template cannot hang a load.
local function deepCopy(value: any, seen: { [any]: boolean }): any
	if typeof(value) ~= "table" then
		return value
	end
	if seen[value] then
		return value
	end
	seen[value] = true
	local copy = {}
	for key, item in value :: { [any]: any } do
		copy[key] = deepCopy(item, seen)
	end
	return copy
end

-- Fill missing keys in `data` from `defaults`, recursively.
--
-- Rules that matter: an existing value always wins (a default never
-- overwrites real saved state); nil defaults are skipped entirely, so
-- reconciliation can never erase a field; and when both sides are tables the
-- merge descends instead of replacing, so adding one key to a nested template
-- does not discard what the player already had.
local function mergeDefaults(defaults: any, data: { [any]: any })
	if typeof(defaults) ~= "table" then
		return
	end
	for key, defaultValue in defaults :: { [any]: any } do
		if defaultValue == nil then
			continue
		end
		local current = data[key]
		if current == nil then
			data[key] = deepCopy(defaultValue, {})
		elseif typeof(current) == "table" and typeof(defaultValue) == "table" then
			mergeDefaults(defaultValue, current :: { [any]: any })
		end
	end
end

function Migrator.new(config: Config)
	local self: Instance = {
		_version = math.floor(math.max(config.version or 1, 1)),
		_migrations = if typeof(config.migrations) == "table" then config.migrations else {},
		_defaults = config.defaults,
	}
	return setmetatable(self :: any, Migrator)
end

function Migrator:migrate(data: any, defaults: any?): { data: any, fromVersion: number, toVersion: number }
	local migrator = self :: Instance
	local working = if typeof(data) == "table" then deepCopy(data, {}) else {}

	local declared = tonumber((working :: any).version)
	local fromVersion = if declared then math.floor(declared) else 0
	local target = migrator._version

	if fromVersion > target then
		-- Written by a newer build: reconcile fields we do understand, but
		-- keep its version stamp so a rollback cannot downgrade real data.
		mergeDefaults(defaults or migrator._defaults, working)
		return { data = working, fromVersion = fromVersion, toVersion = fromVersion }
	end

	-- Apply each step keyed by the version it upgrades FROM. A gap (missing
	-- transform) skips rather than errors: additive-only schemas need none.
	for step = fromVersion, target - 1 do
		local transform: Migration? = migrator._migrations[step]
		if transform then
			local migrated = transform(working)
			-- Nil is the in-place form: the step already edited `working`.
			-- A non-table return is not a profile either. Substituting {}
			-- and then stamping the target version made that wipe permanent.
			if typeof(migrated) == "table" then
				working = migrated
			end
		end
	end

	working.version = target
	mergeDefaults(defaults or migrator._defaults, working)

	return { data = working, fromVersion = fromVersion, toVersion = target }
end

return Migrator
