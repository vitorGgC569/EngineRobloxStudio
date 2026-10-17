--!strict
--[[
	JSON, so a harness body can report a result instead of formatting one.

	Every test written against this harness built its output by hand:

		print(string.format('{"ok":%s}', tostring(ok)))

	That works, and it is a trap. `tostring(nil)` is the four characters `nil`,
	which is not JSON -- so the harness's line decoder skips it, the assertion
	silently reads whatever was printed *before*, and the test passes while
	measuring the wrong thing. Nested tables were not expressible at all, which
	is why every test written against this harness asserts only on flat scalars.

	Deliberately small
	------------------

	Arrays and maps are told apart by whether key `1` exists. That is the same
	guess Roblox's own `HttpService:JSONEncode` makes, and it is wrong for
	exactly one case -- an empty table, rendered here as `[]` -- so a test whose
	meaning turns on that distinction should assert on a length instead.

	Keys are sorted, so two runs of the same body print the same line and a
	difference between them is a real difference rather than hash order.
]]

local function encode(value: any): string
	local kind = typeof(value)

	if value == nil then
		return "null"
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind == "number" then
		-- Non-finite numbers are not JSON. Naming them beats emitting `inf`,
		-- which arrives at the reader as a parse error with no clue in it.
		if value ~= value then
			return '"NaN"'
		elseif value == math.huge then
			return '"Infinity"'
		elseif value == -math.huge then
			return '"-Infinity"'
		elseif value % 1 == 0 then
			return string.format("%d", value)
		end
		return string.format("%.10g", value)
	elseif kind == "string" then
		local escaped = value
		escaped = string.gsub(escaped, "\\", "\\\\")
		escaped = string.gsub(escaped, '"', '\\"')
		escaped = string.gsub(escaped, "\n", "\\n")
		escaped = string.gsub(escaped, "\r", "\\r")
		escaped = string.gsub(escaped, "\t", "\\t")
		return '"' .. escaped .. '"'
	elseif kind == "table" then
		if (value :: any)[1] ~= nil or next(value :: any) == nil then
			local items = {}
			for index = 1, #(value :: any) do
				table.insert(items, encode((value :: any)[index]))
			end
			return "[" .. table.concat(items, ",") .. "]"
		end

		local keys = {}
		for key in pairs(value :: any) do
			table.insert(keys, key)
		end
		table.sort(keys, function(left, right)
			return tostring(left) < tostring(right)
		end)

		local items = {}
		for _, key in ipairs(keys) do
			table.insert(items, encode(tostring(key)) .. ":" .. encode((value :: any)[key]))
		end
		return "{" .. table.concat(items, ",") .. "}"
	end

	-- A function, a thread or a shimmed userdata. Named rather than dropped:
	-- a silently absent key is how a test asserts on a field that was never
	-- there and passes.
	return '"<' .. kind .. '>"'
end

return encode
