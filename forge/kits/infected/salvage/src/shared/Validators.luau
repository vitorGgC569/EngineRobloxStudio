--!strict
-- Composable payload validators. Every RemoteEvent handler validates its payload with
-- these before touching it — remotes are hostile input. Pure (typeof exists in Luau
-- everywhere, including Lune), so the shape logic is unit-testable.

export type Validator = (value: any) -> boolean

local Validators = {}

function Validators.number(min: number?, max: number?): Validator
	return function(v: any): boolean
		if type(v) ~= "number" or v ~= v then -- reject NaN
			return false
		end
		if v == math.huge or v == -math.huge then
			return false
		end
		if min ~= nil and v < min then
			return false
		end
		if max ~= nil and v > max then
			return false
		end
		return true
	end
end

function Validators.integer(min: number?, max: number?): Validator
	local num = Validators.number(min, max)
	return function(v: any): boolean
		return num(v) and v % 1 == 0
	end
end

function Validators.str(maxLen: number?): Validator
	return function(v: any): boolean
		return type(v) == "string" and (maxLen == nil or #v <= maxLen)
	end
end

function Validators.oneOf(options: { string }): Validator
	local set = {}
	for _, opt in options do
		set[opt] = true
	end
	return function(v: any): boolean
		return type(v) == "string" and set[v] == true
	end
end

function Validators.vector3(maxMagnitude: number?): Validator
	return function(v: any): boolean
		if typeof(v) ~= "Vector3" then
			return false
		end
		local m = (v :: Vector3).Magnitude
		if m ~= m or m == math.huge then -- NaN/inf components
			return false
		end
		return maxMagnitude == nil or m <= maxMagnitude
	end
end

function Validators.unitVector3(): Validator
	local v3 = Validators.vector3(1.001)
	return function(v: any): boolean
		return v3(v) and (v :: Vector3).Magnitude > 0.999
	end
end

-- shape({a = Validators.number()}) — rejects unknown keys and missing keys alike.
function Validators.shape(fields: { [string]: Validator }): Validator
	return function(v: any): boolean
		if type(v) ~= "table" then
			return false
		end
		for key, validate in fields do
			if not validate((v :: any)[key]) then
				return false
			end
		end
		for key in v :: any do
			if fields[key] == nil then
				return false
			end
		end
		return true
	end
end

function Validators.optional(inner: Validator): Validator
	return function(v: any): boolean
		return v == nil or inner(v)
	end
end

return Validators
