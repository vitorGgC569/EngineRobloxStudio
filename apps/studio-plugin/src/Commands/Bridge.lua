--!strict
-- Introspection of the bridge itself: liveness, capabilities and Studio identity.

local Config = require(script.Parent.Parent.Config)
local Runtime = require(script.Parent.Runtime)

local BridgeCommands = {}

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
	return {
		protocol = Config.PROTOCOL,
		pluginVersion = Config.PLUGIN_VERSION,
		methods = Dispatcher.methods(),
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
