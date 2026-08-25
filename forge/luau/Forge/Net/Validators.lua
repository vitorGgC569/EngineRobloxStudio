--!strict
--[[
	Validators — composable remote-payload validation, hostile-input grade.

	Every client->server packet is hostile input. A validator is a pure
	function `(value) -> (boolean, string?)`: `false` always carries a reason
	you can log or feed to anti-cheat. Factories:

		number(min, max)        integer(min, max)      str(minLen, maxLen, pattern?)
		boolean()               oneOf({...})           vector3()
		unitVector3(epsilon)    shape({k = v})         optional(inner)
		array(inner, maxItems)  anyOf({v1, v2, ...})   compose({steps})

	Fail-closed rules: NaN/inf never pass as numbers (or inside Vector3
	components), `shape` rejects unknown keys as well as missing ones, `nil`
	only passes through `optional`, and arrays must be contiguous with no
	stray keys. Pure logic: no services, no remotes.
]]

local Validators = {}

export type Validator = (value: any) -> (boolean, string?)

-- Fail-safe ceiling so a forgotten maxItems cannot turn an array into a
-- memory DoS; pass an explicit bound when you know the real one.
local DEFAULT_ARRAY_ITEMS = 1024

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

function Validators.number(min: number?, max: number?): Validator
	return function(v: any): (boolean, string?)
		if typeof(v) ~= "number" then
			return false, string.format("expected number, got %s", typeof(v))
		end
		if not isFinite(v) then
			return false, "number must be finite (NaN/inf rejected)"
		end
		if min ~= nil and v < min then
			return false, string.format("number %g below minimum %g", v, min)
		end
		if max ~= nil and v > max then
			return false, string.format("number %g above maximum %g", v, max)
		end
		return true, nil
	end
end

function Validators.integer(min: number?, max: number?): Validator
	local isNumber = Validators.number(min, max)
	return function(v: any): (boolean, string?)
		local ok, why = isNumber(v)
		if not ok then
			return false, why
		end
		if v % 1 ~= 0 then
			return false, string.format("expected integer, got %g", v)
		end
		return true, nil
	end
end

function Validators.str(minLen: number?, maxLen: number?, pattern: string?): Validator
	return function(v: any): (boolean, string?)
		if typeof(v) ~= "string" then
			return false, string.format("expected string, got %s", typeof(v))
		end
		if minLen ~= nil and #v < minLen then
			return false, string.format("string shorter than %d characters", minLen)
		end
		if maxLen ~= nil and #v > maxLen then
			return false, string.format("string longer than %d characters", maxLen)
		end
		if pattern ~= nil and string.match(v :: string, pattern) == nil then
			return false, string.format("string does not match pattern %q", pattern)
		end
		return true, nil
	end
end

function Validators.boolean(): Validator
	return function(v: any): (boolean, string?)
		if typeof(v) ~= "boolean" then
			return false, string.format("expected boolean, got %s", typeof(v))
		end
		return true, nil
	end
end

function Validators.oneOf(options: { any }): Validator
	assert(#options > 0, "oneOf needs at least one option")
	local set: { [any]: boolean } = {}
	local listed: { string } = {}
	for _, option in options do
		set[option] = true
		table.insert(listed, tostring(option))
	end
	local expected = table.concat(listed, ", ")
	return function(v: any): (boolean, string?)
		if set[v] == true then
			return true, nil
		end
		return false, string.format("value %s is not one of (%s)", tostring(v), expected)
	end
end

-- Checks each component directly instead of .Magnitude: a single NaN axis
-- makes Magnitude NaN too, but checking axes names the offender.
function Validators.vector3(): Validator
	return function(v: any): (boolean, string?)
		if typeof(v) ~= "Vector3" then
			return false, string.format("expected Vector3, got %s", typeof(v))
		end
		local vec = v :: any
		for _, axis in { "X", "Y", "Z" } do
			local component = vec[axis]
			if typeof(component) ~= "number" or not isFinite(component) then
				return false, string.format("Vector3.%s must be finite (NaN/inf rejected)", axis)
			end
		end
		return true, nil
	end
end

-- Magnitude within `1 +/- epsilon` of unit length (default 0.001).
function Validators.unitVector3(epsilon: number?): Validator
	local tolerance = epsilon or 0.001
	local isVector3 = Validators.vector3()
	return function(v: any): (boolean, string?)
		local ok, why = isVector3(v)
		if not ok then
			return false, why
		end
		local vec = v :: any
		local magnitude = math.sqrt(vec.X * vec.X + vec.Y * vec.Y + vec.Z * vec.Z)
		if math.abs(magnitude - 1) > tolerance then
			return false, string.format("magnitude %.6f is not unit within %g", magnitude, tolerance)
		end
		return true, nil
	end
end

-- shape({a = Validators.number()}) rejects unknown keys and missing keys
-- alike. Declared fields are checked in sorted order so error messages are
-- deterministic for identical payloads.
function Validators.shape(fields: { [string]: Validator }): Validator
	local keys: { string } = {}
	for key in fields do
		table.insert(keys, key)
	end
	table.sort(keys)
	return function(v: any): (boolean, string?)
		if typeof(v) ~= "table" then
			return false, string.format("expected table, got %s", typeof(v))
		end
		local record = v :: { [string]: any }
		for _, key in keys do
			local ok, why = (fields :: { [string]: Validator })[key](record[key])
			if not ok then
				return false, string.format("field %q: %s", key, why or "failed")
			end
		end
		for key in record do
			if fields[key] == nil then
				return false, string.format("unknown field %q rejected (fail-closed)", tostring(key))
			end
		end
		return true, nil
	end
end

function Validators.optional(inner: Validator): Validator
	return function(v: any): (boolean, string?)
		if v == nil then
			return true, nil
		end
		return inner(v)
	end
end

-- A strict array: contiguous 1..n of validated items, no holes, no extra or
-- non-numeric keys. Anything else fails closed.
function Validators.array(inner: Validator, maxItems: number?): Validator
	local ceiling = maxItems or DEFAULT_ARRAY_ITEMS
	return function(v: any): (boolean, string?)
		if typeof(v) ~= "table" then
			return false, string.format("expected array, got %s", typeof(v))
		end
		local list = v :: { any }
		local count = 0
		while count < ceiling do
			local item = list[count + 1]
			if item == nil then
				break
			end
			count += 1
			local ok, why = inner(item)
			if not ok then
				return false, string.format("item [%d]: %s", count, why or "failed")
			end
		end
		if list[count + 1] ~= nil then
			return false, string.format("array exceeds %d items", ceiling)
		end
		for key in list do
			local index = key :: any
			if typeof(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > count then
				return false, string.format("unexpected key %s in array (fail-closed)", tostring(key))
			end
		end
		return true, nil
	end
end

-- Passes if ANY inner validator passes; otherwise reports every reason.
function Validators.anyOf(options: { Validator }): Validator
	assert(#options > 0, "anyOf needs at least one validator")
	return function(v: any): (boolean, string?)
		local reasons: { string } = {}
		for index, inner in options do
			local ok, why = inner(v)
			if ok then
				return true, nil
			end
			reasons[index] = why or "failed"
		end
		return false, "no alternative matched: " .. table.concat(reasons, "; ")
	end
end

-- Runs a fixed pipeline in order and returns the FIRST failure verbatim.
function Validators.compose(steps: { Validator }): Validator
	return function(v: any): (boolean, string?)
		for _, step in steps do
			local ok, why = step(v)
			if not ok then
				return false, why
			end
		end
		return true, nil
	end
end

return Validators
