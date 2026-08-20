--!strict
--[[
	Data — content tables with a declared shape.

	Balance lives in data, not in code. That is easy to say and hard to keep:
	six weeks in, half the numbers are inline in a system somewhere and the
	other half are in a table nobody validates, so a typo'd `dmg` silently
	becomes `nil` and a sword does zero damage in production.

	Data fixes the second half. You declare the shape once; every entry is
	checked at load with an error that names the file, the id and the field.

		local Data = Forge.Data

		Data.define("weapon", {
			name    = { type = "string" },
			damage  = { type = "number", min = 0 },
			speed   = { type = "number", default = 1 },
			rarity  = { type = "string", oneOf = { "common", "rare", "epic" } },
			onHit   = { type = "table", optional = true },
		})

		Data.load("weapon", require(script.Weapons))

		local sword = Data.get("weapon", "iron_sword")

	`extends` gives variants without copy-paste:

		iron_sword_plus = { extends = "iron_sword", damage = 22 }
]]

local Signal = require(script.Parent.Core.Signal)

local Data = {}

Data.changed = Signal.new() -- (kind: string) fired on load/reload

type Field = {
	type: string?,
	optional: boolean?,
	default: any?,
	min: number?,
	max: number?,
	oneOf: { any }?,
	of: string?, -- element type for arrays
	check: ((any) -> (boolean, string?))?,
}

local schemas: { [string]: { [string]: Field } } = {}
local tables: { [string]: { [string]: any } } = {}
local strict = true

-- In strict mode a bad entry is an error. Turn it off only in a live session
-- where you would rather limp than crash.
function Data.setStrict(value: boolean)
	strict = value
end

function Data.define(kind: string, schema: { [string]: Field })
	schemas[kind] = schema
	tables[kind] = tables[kind] or {}
end

local function fail(message: string)
	if strict then
		error(message, 3)
	else
		warn(message)
	end
end

local function typeOk(value: any, expected: string): boolean
	if expected == "any" then
		return true
	end
	local actual = typeof(value)
	if expected == "number" or expected == "string" or expected == "boolean" or expected == "table" or expected == "function" then
		return type(value) == expected
	end
	return actual == expected
end

local function validateEntry(kind: string, id: string, entry: any)
	local schema = schemas[kind]
	if not schema then
		return
	end

	for field, spec in schema do
		local value = entry[field]

		if value == nil then
			if spec.default ~= nil then
				entry[field] = spec.default
				continue
			end
			if not spec.optional then
				fail(string.format("[Data] %s '%s': missing required field '%s'", kind, id, field))
			end
			continue
		end

		if spec.type and not typeOk(value, spec.type) then
			fail(string.format("[Data] %s '%s': field '%s' should be %s, got %s", kind, id, field, spec.type, typeof(value)))
			continue
		end

		if spec.min and type(value) == "number" and value < spec.min then
			fail(string.format("[Data] %s '%s': field '%s' = %s is below minimum %s", kind, id, field, tostring(value), tostring(spec.min)))
		end
		if spec.max and type(value) == "number" and value > spec.max then
			fail(string.format("[Data] %s '%s': field '%s' = %s is above maximum %s", kind, id, field, tostring(value), tostring(spec.max)))
		end

		if spec.oneOf then
			local found = false
			for _, allowed in spec.oneOf do
				if value == allowed then
					found = true
					break
				end
			end
			if not found then
				fail(string.format("[Data] %s '%s': field '%s' = %s is not one of the allowed values", kind, id, field, tostring(value)))
			end
		end

		if spec.of and type(value) == "table" then
			for i, element in value do
				if not typeOk(element, spec.of) then
					fail(string.format("[Data] %s '%s': field '%s'[%s] should be %s", kind, id, field, tostring(i), spec.of))
				end
			end
		end

		if spec.check then
			local ok, why = spec.check(value)
			if not ok then
				fail(string.format("[Data] %s '%s': field '%s' rejected: %s", kind, id, field, why or "failed check"))
			end
		end
	end

	-- A field nobody declared is almost always a typo of one that exists.
	for field in entry do
		if field ~= "extends" and field ~= "id" and schema[field] == nil then
			warn(string.format("[Data] %s '%s': unknown field '%s' (typo?)", kind, id, field))
		end
	end
end

local function resolveExtends(kind: string, source: { [string]: any })
	local resolved: { [string]: any } = {}
	local resolving: { [string]: boolean } = {}

	local function build(id: string): any
		if resolved[id] then
			return resolved[id]
		end
		local raw = source[id]
		if not raw then
			fail(string.format("[Data] %s '%s': extends a definition that does not exist", kind, id))
			return {}
		end
		if resolving[id] then
			fail(string.format("[Data] %s '%s': circular extends", kind, id))
			return {}
		end
		resolving[id] = true

		local out: { [string]: any }
		if raw.extends then
			out = table.clone(build(raw.extends))
		else
			out = {}
		end
		for k, v in raw do
			if k ~= "extends" then
				out[k] = v
			end
		end
		out.id = id

		resolving[id] = nil
		resolved[id] = out
		return out
	end

	for id in source do
		build(id)
	end
	return resolved
end

function Data.load(kind: string, source: { [string]: any })
	assert(type(source) == "table", "[Data] load expects a table")
	if not schemas[kind] then
		warn(string.format("[Data] loading '%s' with no schema defined; nothing will be validated", kind))
	end

	local resolved = resolveExtends(kind, source)
	for id, entry in resolved do
		validateEntry(kind, id, entry)
	end

	tables[kind] = resolved
	Data.changed:Fire(kind)
	return resolved
end

function Data.get(kind: string, id: string): any
	local t = tables[kind]
	if not t then
		error(string.format("[Data] no content of kind '%s' has been loaded", kind), 2)
	end
	return t[id]
end

-- Same as get, but a missing id is an error rather than nil. Use in systems
-- where a nil would fail three call frames later with no useful message.
function Data.expect(kind: string, id: string): any
	local entry = Data.get(kind, id)
	if not entry then
		error(string.format("[Data] %s '%s' does not exist", kind, tostring(id)), 2)
	end
	return entry
end

function Data.all(kind: string): { [string]: any }
	return tables[kind] or {}
end

function Data.ids(kind: string): { string }
	local out = {}
	for id in (tables[kind] or {}) do
		table.insert(out, id)
	end
	table.sort(out)
	return out
end

function Data.query(kind: string, predicate: (entry: any, id: string) -> boolean): { any }
	local out = {}
	for id, entry in (tables[kind] or {}) do
		if predicate(entry, id) then
			table.insert(out, entry)
		end
	end
	table.sort(out, function(a, b)
		return tostring(a.id) < tostring(b.id)
	end)
	return out
end

function Data.kinds(): { string }
	local out = {}
	for kind in tables do
		table.insert(out, kind)
	end
	table.sort(out)
	return out
end

-- A snapshot a validator can diff between builds to see what balance changed.
function Data.snapshot(): { [string]: any }
	local out: { [string]: any } = {}
	for kind, entries in tables do
		local count = 0
		for _ in entries do
			count += 1
		end
		out[kind] = { count = count, ids = Data.ids(kind) }
	end
	return out
end

-- Debug.snapshot() collects `describe` from every module; without this one the
-- entire content layer would be invisible to a validator.
function Data.describe(): { [string]: any }
	return Data.snapshot()
end

return Data
