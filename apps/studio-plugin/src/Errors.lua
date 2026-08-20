--!strict
-- Structured errors shared with the Python side.
--
-- A command failure must reach the agent as a code it can branch on, not as a
-- Luau traceback string. The codes mirror rqe/hub/protocol.py::ErrorCode.

local Errors = {}

Errors.UNKNOWN_METHOD = "E_UNKNOWN_METHOD"
Errors.BAD_PARAMS = "E_BAD_PARAMS"
Errors.NOT_FOUND = "E_NOT_FOUND"
Errors.EXEC = "E_EXEC"
Errors.UNSUPPORTED_CONTEXT = "E_UNSUPPORTED_CONTEXT"
--- The plugin gave up waiting on something inside Studio.
---
--- Distinct from the hub's own timeout on the plugin: this one names which half
--- stopped answering, which the hub cannot know.
Errors.TIMEOUT = "E_TIMEOUT"

local MARKER = "__rqe_error__"

export type StructuredError = {
	code: string,
	message: string,
	details: { [string]: any },
}

--- Throw a structured error. The dispatcher recognises the marker and forwards
--- code/message/details instead of stringifying a traceback.
function Errors.raise(code: string, message: string, details: { [string]: any }?): ()
	error({
		[MARKER] = true,
		code = code,
		message = message,
		details = details or {},
	}, 0)
end

--- Normalise anything pcall produced into a wire-ready error table.
function Errors.normalize(thrown: any): StructuredError
	if type(thrown) == "table" and thrown[MARKER] then
		return {
			code = thrown.code,
			message = thrown.message,
			details = thrown.details or {},
		}
	end
	return {
		code = Errors.EXEC,
		message = tostring(thrown),
		details = {},
	}
end

--- Assert a parameter is present and of the expected type.
function Errors.expect(params: { [string]: any }, key: string, expectedType: string): any
	local value = params[key]
	if value == nil then
		Errors.raise(Errors.BAD_PARAMS, string.format("parameter '%s' is required", key), { expected = expectedType })
	end
	if typeof(value) ~= expectedType then
		Errors.raise(
			Errors.BAD_PARAMS,
			string.format("parameter '%s' must be a %s, got %s", key, expectedType, typeof(value)),
			{ expected = expectedType, actual = typeof(value) }
		)
	end
	return value
end

--- Read a Vector3 from a {x, y, z} array parameter.
function Errors.expectVector(params: { [string]: any }, key: string): Vector3
	local value = params[key]
	if typeof(value) ~= "table" or #value < 3 then
		Errors.raise(Errors.BAD_PARAMS, string.format("parameter '%s' must be a [x, y, z] array", key), { actual = typeof(value) })
	end
	return Vector3.new(tonumber(value[1]) or 0, tonumber(value[2]) or 0, tonumber(value[3]) or 0)
end

return Errors
