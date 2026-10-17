--!strict
-- Introspection of the bridge itself: liveness, capabilities and Studio identity.

local Config = require(script.Parent.Parent.Config)
local Runtime = require(script.Parent.Runtime)
local EncodingService = game:GetService("EncodingService")

local BridgeCommands = {}

--[[
	`EncodingService:ComputeStringHash` is a minefield on this Studio build,
	measured twice over.

	First, the enum member is `Sha256`, not `SHA256` -- the members here are
	Blake2b, Blake3, Md5, Sha1, Sha256. The wrong spelling raised, and
	`bridge.capabilities` answered E_EXEC for every caller.

	Second, the result is the *raw 32-byte digest*, not a hex string. SHA-256
	of "alpha" came back as 32 bytes whose hex is
	8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccdda1ed4018e8f2223f8 --
	the true digest, unencoded. Those bytes are almost never valid UTF-8, and
	`HttpService:JSONEncode` rejects strings that are not valid UTF-8, so the
	response to the first caller poisoned the plugin's result outbox: every
	flush failed to encode, the session reconnected, the same batch was
	retried, and the bridge looped forever without polling a single command.
	One unencodable response bricked the whole bridge. Hex everything.
]]
local function hexBytes(bytes: string): string
	local out = {}
	for index = 1, #bytes do
		table.insert(out, string.format("%02x", string.byte(bytes, index)))
	end
	return table.concat(out)
end

local function hashText(value: any): string
	if type(value) == "string" then
		return hexBytes(value)
	end
	if typeof(value) == "buffer" then
		local bytes = {}
		for index = 0, buffer.len(value) - 1 do
			table.insert(bytes, string.format("%02x", buffer.readu8(value, index)))
		end
		return table.concat(bytes)
	end
	return tostring(value)
end

local function capabilityIdentity(methods: { string }): string
	return hashText(EncodingService:ComputeStringHash(
		table.concat(methods, "\n"),
		Enum.HashAlgorithm.Sha256
	))
end

--- bridge.ping: proves the whole chain is alive, end to end.
---
--- A pong that reaches the agent means the hub queued a command, Studio's
--- plugin polled it, executed it against a real DataModel and answered. There
--- is no way to produce this response without a live Studio.
function BridgeCommands.ping(params: { [string]: any }): any
	return {
		pong = true,
		protocol = Config.PROTOCOL,
		pluginVersion = Config.PLUGIN_VERSION,
		pluginBuildId = Config.PLUGIN_BUILD_ID,
		context = Runtime.context(),
		placeName = game.Name,
		serverTime = os.time(),
		clock = os.clock(),
		echo = params.echo,
	}
end

--- bridge.capabilities: what this plugin build can actually do.
---
--- Agents must be able to discover the command surface at runtime instead of
--- assuming it, so an older plugin against a newer engine degrades explicitly.
function BridgeCommands.capabilities(_params: { [string]: any }): any
	local Dispatcher = require(script.Parent.Parent.Dispatcher)
	local methods = Dispatcher.methods()
	return {
		protocol = Config.PROTOCOL,
		pluginVersion = Config.PLUGIN_VERSION,
		pluginBuildId = Config.PLUGIN_BUILD_ID,
		capabilityHash = capabilityIdentity(methods),
		methods = methods,
		context = Runtime.context(),
	}
end

--- studio.info: which Studio, which place, which mode.
function BridgeCommands.info(_params: { [string]: any }): any
	local studioVersion = "unknown"
	local ok, value = pcall(function()
		return version()
	end)
	if ok and type(value) == "string" then
		studioVersion = value
	end

	local services = {}
	for _, name in ipairs({ "Workspace", "Players", "Lighting", "ReplicatedStorage", "ServerScriptService", "StarterGui", "StarterPlayer", "SoundService", "Teams" }) do
		local serviceOk, service = pcall(function()
			return game:GetService(name :: any)
		end)
		if serviceOk and service then
			services[name] = #service:GetChildren()
		end
	end

	return {
		studioVersion = studioVersion,
		placeName = game.Name,
		placeId = game.PlaceId,
		gameId = game.GameId,
		jobId = game.JobId,
		context = Runtime.context(),
		isRunning = game:GetService("RunService"):IsRunning(),
		serviceChildCounts = services,
		workspaceDescendants = #workspace:GetDescendants(),
	}
end

return BridgeCommands
