--!strict
-- Native subtree serialization for low-round-trip snapshots, rollback and
-- cross-session copy. SerializationService preserves Roblox instance state far
-- more faithfully than rebuilding a hierarchy property by property over JSON.

local EncodingService = game:GetService("EncodingService")
local RunService = game:GetService("RunService")
local SerializationService = game:GetService("SerializationService")

local Errors = require(script.Parent.Parent.Errors)
local History = require(script.Parent.Parent.History)
local Refs = require(script.Parent.Parent.Refs)
local Resolve = require(script.Parent.Parent.Resolve)

local SerializationCommands = {}

-- MCP requests are capped at 4 MiB. Base64 expands by ~4/3, so a 2 MiB raw
-- snapshot leaves ample room for JSON framing and metadata in both directions.
local MAX_RAW_BYTES = 2 * 1024 * 1024
local MAX_INSTANCES = 10000
local MAX_ROOTS = 64

local function describe(instance: Instance): { [string]: any }
	return {
		ref = Refs.of(instance),
		name = instance.Name,
		className = instance.ClassName,
		path = instance:GetFullName(),
	}
end

local function destroyAll(instances: { Instance })
	for _, instance in ipairs(instances) do
		pcall(function()
			instance:Destroy()
		end)
	end
end

local function countTree(roots: { Instance }): number
	local count = 0
	for _, root in ipairs(roots) do
		count += 1 + #root:GetDescendants()
		if count > MAX_INSTANCES then
			return count
		end
	end
	return count
end

local function validateRoots(raw: any): { Instance }
	if type(raw) ~= "table" or #raw < 1 or #raw > MAX_ROOTS then
		Errors.raise(
			Errors.BAD_PARAMS,
			string.format("paths must contain between 1 and %d instance paths or refs", MAX_ROOTS)
		)
	end

	local roots: { Instance } = {}
	local seen: { [Instance]: boolean } = {}
	for index, path in ipairs(raw) do
		if type(path) ~= "string" or path == "" then
			Errors.raise(
				Errors.BAD_PARAMS,
				string.format("paths[%d] must be a non-empty instance path or ref", index)
			)
		end

		local instance = Resolve.instance(path)
		if instance == game or instance.Parent == game then
			Errors.raise(
				Errors.BAD_PARAMS,
				"DataModel and service roots cannot be serialized; choose content below a service",
				{ path = path }
			)
		end
		if seen[instance] then
			Errors.raise(Errors.BAD_PARAMS, "paths contains the same instance more than once")
		end
		seen[instance] = true
		table.insert(roots, instance)
	end

	-- Parent + child would serialize the same subtree twice and make restore
	-- semantics ambiguous, so reject overlap before any expensive work.
	for left = 1, #roots do
		for right = left + 1, #roots do
			if roots[left]:IsAncestorOf(roots[right]) or roots[right]:IsAncestorOf(roots[left]) then
				Errors.raise(
					Errors.BAD_PARAMS,
					"serialized roots must not contain ancestor/descendant overlap",
					{ left = roots[left]:GetFullName(), right = roots[right]:GetFullName() }
				)
			end
		end
	end

	local total = countTree(roots)
	if total > MAX_INSTANCES then
		Errors.raise(
			Errors.BAD_PARAMS,
			string.format("snapshot contains %d instances; maximum is %d", total, MAX_INSTANCES)
		)
	end

	return roots
end

function SerializationCommands.serialize(params: { [string]: any }): any
	local roots = validateRoots(params.paths)

	local ok, rawOrError = pcall(function()
		return SerializationService:SerializeInstancesAsync(roots)
	end)
	if not ok then
		Errors.raise(
			Errors.EXEC,
			"SerializationService:SerializeInstancesAsync failed: " .. tostring(rawOrError)
		)
	end

	local raw = rawOrError :: buffer
	local bytes = buffer.len(raw)
	if bytes > MAX_RAW_BYTES then
		Errors.raise(
			Errors.BAD_PARAMS,
			string.format(
				"serialized payload is %d bytes; maximum is %d bytes for bridge transport",
				bytes,
				MAX_RAW_BYTES
			)
		)
	end

	local encoded = EncodingService:Base64Encode(raw)
	local dataBase64 = buffer.tostring(encoded)
	local described = {}
	for _, instance in ipairs(roots) do
		table.insert(described, describe(instance))
	end

	return {
		format = "roblox-serialization-buffer-v1",
		bytes = bytes,
		base64Bytes = #dataBase64,
		instanceCount = countTree(roots),
		rootCount = #roots,
		roots = described,
		dataBase64 = dataBase64,
		source = "SerializationService.SerializeInstancesAsync",
	}
end

function SerializationCommands.deserialize(params: { [string]: any }): any
	if RunService:IsRunning() then
		Errors.raise(
			Errors.UNSUPPORTED_CONTEXT,
			"instance.deserialize is edit-mode only because it mutates persistent place content"
		)
	end

	local dataBase64 = params.dataBase64
	if type(dataBase64) ~= "string" or dataBase64 == "" then
		Errors.raise(Errors.BAD_PARAMS, "dataBase64 must be a non-empty base64 string")
	end
	-- Conservative encoded bound before allocating/decoding.
	if #dataBase64 > math.ceil(MAX_RAW_BYTES * 4 / 3) + 16 then
		Errors.raise(Errors.BAD_PARAMS, "dataBase64 exceeds the bridge serialization limit")
	end

	local decodedOk, rawOrError = pcall(function()
		return EncodingService:Base64Decode(buffer.fromstring(dataBase64))
	end)
	if not decodedOk then
		Errors.raise(Errors.BAD_PARAMS, "dataBase64 is not valid base64: " .. tostring(rawOrError))
	end
	local raw = rawOrError :: buffer
	if buffer.len(raw) > MAX_RAW_BYTES then
		Errors.raise(Errors.BAD_PARAMS, "decoded serialization payload exceeds the bridge limit")
	end

	local deserializedOk, rootsOrError = pcall(function()
		return SerializationService:DeserializeInstancesAsync(raw)
	end)
	if not deserializedOk then
		Errors.raise(
			Errors.BAD_PARAMS,
			"SerializationService:DeserializeInstancesAsync rejected the payload: "
				.. tostring(rootsOrError)
		)
	end

	local roots = rootsOrError :: { Instance }
	if #roots < 1 or #roots > MAX_ROOTS then
		destroyAll(roots)
		Errors.raise(
			Errors.BAD_PARAMS,
			string.format("deserialized root count must be between 1 and %d", MAX_ROOTS)
		)
	end

	local instanceCount = countTree(roots)
	if instanceCount > MAX_INSTANCES then
		destroyAll(roots)
		Errors.raise(
			Errors.BAD_PARAMS,
			string.format(
				"deserialized payload expands to %d instances; maximum is %d",
				instanceCount,
				MAX_INSTANCES
			)
		)
	end

	local parent = Resolve.instance(params.parent)
	local applied: { Instance } = {}
	local ok, resultOrError = pcall(function()
		return History.record("RQE instance.deserialize", function()
			for _, instance in ipairs(roots) do
				instance.Parent = parent
				table.insert(applied, instance)
			end

			local described = {}
			for _, instance in ipairs(roots) do
				table.insert(described, describe(instance))
			end
			return {
				created = described,
				rootCount = #roots,
				instanceCount = instanceCount,
				parent = describe(parent),
				source = "SerializationService.DeserializeInstancesAsync",
			}
		end)
	end)

	if not ok then
		destroyAll(roots)
		error(resultOrError, 0)
	end

	return resultOrError
end

return SerializationCommands
