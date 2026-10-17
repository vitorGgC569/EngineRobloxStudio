--!strict
-- Relay from the plugin (server DataModel) into the client instrumentation.
--
-- The client half cannot talk to the hub -- `HttpService` is server-only, so a
-- LocalScript has no way to reach it. The plugin does have HTTP and does have
-- `RemoteFunction:InvokeClient`, so every `client.*` command is answered by
-- asking the player's own client and returning what it says.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Parent.Errors)
local Resolve = require(script.Parent.Parent.Resolve)
local Serialize = require(script.Parent.Parent.Serialize)

local ClientCommands = {}

local CHANNEL_NAME = "RQEClientChannel"

--- How long to wait for the client before giving up on one command.
---
--- Under the hub's own 15s default this has to be shorter, so the plugin
--- returns a diagnosis rather than letting the caller see a bare bridge
--- timeout that names the wrong half of the system.
local CLIENT_INVOKE_TIMEOUT = 8

--- The RemoteFunction both halves meet on, created on demand.
local function channel(): RemoteFunction
	local existing = ReplicatedStorage:FindFirstChild(CHANNEL_NAME)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local remote = Instance.new("RemoteFunction")
	remote.Name = CHANNEL_NAME
	remote.Parent = ReplicatedStorage
	return remote
end

local function targetPlayer(params: { [string]: any }): Player
	if params.player ~= nil then
		local found = Players:FindFirstChild(tostring(params.player))
		if found == nil or not found:IsA("Player") then
			Errors.raise(Errors.NOT_FOUND, "no such player", { player = params.player })
		end
		return found :: Player
	end
	local players = Players:GetPlayers()
	if #players > 1 then
		Errors.raise(Errors.BAD_PARAMS, "multiple players are present; select an explicit player")
	end
	local first = players[1]
	if first == nil then
		Errors.raise(
			Errors.UNSUPPORTED_CONTEXT,
			"no Player is in the game; client commands need a play session",
			{ hint = "run 'rqe studio play_solo' -- run.start gives physics but no Player" }
		)
	end
	return first
end

--- Ensure the channel exists before a play session needs it.
function ClientCommands.ensureChannel(_params: { [string]: any }): any
	local remote = channel()
	return { channel = remote:GetFullName(), created = true, isRunning = RunService:IsRunning() }
end

--- Ask the client to run one command and return its answer verbatim.
function ClientCommands.invoke(method: string, params: { [string]: any }): any
	if not RunService:IsRunning() then
		Errors.raise(
			Errors.UNSUPPORTED_CONTEXT,
			string.format("client.%s needs a running play session", method),
			{ context = "edit" }
		)
	end

	local player = targetPlayer(params)
	local remote = channel()

	-- Bounded, because `InvokeClient` is not.
	--
	-- A RemoteFunction whose client has no `OnClientInvoke` handler does not
	-- error and does not return -- it yields for the lifetime of the session.
	-- The plugin answers commands one at a time, so a single such call wedges
	-- the whole session: after one hung `client.camera_release`, `run.state`
	-- and `runtime.metrics` timed out too and the session looked dead while the
	-- poll loop was still running. Giving up after a deadline loses this one
	-- answer and keeps every later command working.
	local finished = false
	local response: any = nil
	local ok = true
	task.spawn(function()
		local succeeded, value = pcall(function()
			return remote:InvokeClient(player, { method = method, params = params })
		end)
		ok, response, finished = succeeded, value, true
	end)

	local deadline = os.clock() + CLIENT_INVOKE_TIMEOUT
	while not finished and os.clock() < deadline do
		task.wait(0.05)
	end
	if not finished then
		Errors.raise(
			Errors.TIMEOUT,
			string.format(
				"the client did not answer client.%s within %.0fs; the client half "
				.. "is not installed or not running",
				method, CLIENT_INVOKE_TIMEOUT
			),
			{
				player = player.Name,
				channel = remote:GetFullName(),
				hint = "install it with bridge.install_client in edit context, then "
					.. "start Play Solo -- a session started before the install has "
					.. "no client half",
			}
		)
	end

	if not ok then
		Errors.raise(Errors.EXEC, "the client did not answer: " .. tostring(response), {
			player = player.Name,
			hint = "install the client bridge with bridge.install_client, then restart the play session",
		})
	end

	if type(response) ~= "table" then
		Errors.raise(Errors.EXEC, "the client returned a malformed response", { received = typeof(response) })
	end

	if response.ok then
		local result = response.result
		if type(result) == "table" then
			result.player = player.Name
			result.elapsedMsClient = response.elapsedMs
			-- The installed client script cannot require Serialize. InvokeClient
			-- still returns Vector3 attributes and other Roblox values, and
			-- JSONEncode throws on those when the command result is reported.
			result = Serialize.value(result)
		end
		return result
	end

	local err = response.error or {}
	Errors.raise(
		tostring(err.code or Errors.EXEC),
		tostring(err.message or "the client reported an unspecified failure"),
		if type(err.details) == "table" then err.details else {}
	)
	error("unreachable")
end

function ClientCommands.info(params: { [string]: any }): any
	return ClientCommands.invoke("info", params)
end

--- Resolve `ref:` addressing before crossing into the client.
---
--- Refs live in the plugin's registry, which is a different VM from the
--- client's. Resolving here and forwarding the full path keeps `ref:` working
--- uniformly for callers instead of failing only on client commands.
local function resolveForClient(params: { [string]: any }, key: string): { [string]: any }
	local value = params[key]
	if type(value) == "string" and string.match(value, "^ref:") then
		local instance = Resolve.instance(value)
		local forwarded = table.clone(params)
		forwarded[key] = instance:GetFullName()
		return forwarded
	end
	return params
end

function ClientCommands.promptTrigger(params: { [string]: any }): any
	Errors.expect(params, "path", "string")
	return ClientCommands.invoke("prompt_trigger", resolveForClient(params, "path"))
end

--[[
	The client's DataModel, forwarded.

	Same parameters and same answer shape as the server's `dm.tree` and
	`dm.properties`, so the only difference at the call site is which side of
	the wire is being asked.
]]
function ClientCommands.tree(params: { [string]: any }): any
	return ClientCommands.invoke("tree", params)
end

function ClientCommands.properties(params: { [string]: any }): any
	return ClientCommands.invoke("properties", params)
end

function ClientCommands.guiTree(params: { [string]: any }): any
	return ClientCommands.invoke("gui_tree", params)
end

--- Click a GUI button by delivering real pointer input.
---
--- The press is sent from the *plugin*, not from the client script: measured,
--- `VirtualInputManager:SendMouseButtonEvent` from a LocalScript is refused
--- with "lacking capability RobloxScript". The plugin asks the client where the
--- button is on screen, then drives the mouse itself.
function ClientCommands.guiClick(params: { [string]: any }): any
	Errors.expect(params, "path", "string")
	local forwarded = resolveForClient(params, "path")

	local located = ClientCommands.invoke("gui_locate", forwarded)
	if located == nil or located.found ~= true then
		return located or { success = false, reason = "not_found" }
	end
	if located.clickable ~= true then
		return located
	end

	local watching = ClientCommands.invoke("gui_watch", forwarded)
	if watching == nil or watching.watching ~= true then
		return watching or { success = false, reason = "could_not_watch" }
	end

	local pressOk, pressErr = pcall(function()
		local delivered = ClientCommands.invoke("input", {
			action = "click", x = located.x, y = located.y, player = params.player,
		})
		if not delivered or delivered.delivered ~= true then error("input was not delivered") end
	end)
	task.wait(0.45)

	local result = ClientCommands.invoke("gui_watch_result", forwarded)
	result = result or {}
	result.clickedAt = { located.x, located.y }
	result.inputError = if pressOk then nil else tostring(pressErr)
	result.success = result.activated == true
	result.reason = if result.activated then nil
		elseif not pressOk then "virtual_input_refused"
		else "button_did_not_activate"
	return result
end

function ClientCommands.guiLocate(params: { [string]: any }): any
	Errors.expect(params, "path", "string")
	return ClientCommands.invoke("gui_locate", resolveForClient(params, "path"))
end

function ClientCommands.invokeBindable(params: { [string]: any }): any
	Errors.expect(params, "path", "string")
	return ClientCommands.invoke("invoke_bindable", resolveForClient(params, "path"))
end

function ClientCommands.fireRemote(params: { [string]: any }): any
	Errors.expect(params, "path", "string")
	return ClientCommands.invoke("fire_remote", resolveForClient(params, "path"))
end

function ClientCommands.probeImages(params: { [string]: any }): any
	return ClientCommands.invoke("probe_images", params)
end

function ClientCommands.logs(params: { [string]: any }): any
	return ClientCommands.invoke("logs", params)
end

function ClientCommands.prediction(params: { [string]: any }): any
	return ClientCommands.invoke("prediction", params)
end

--- The UI family. Every one of these has to run client-side: a GUI's effective
--- state does not exist on the server, so reading it there returns whatever the
--- server believes rather than what a player can see.
function ClientCommands.guiText(params: { [string]: any }): any
	Errors.expect(params, "path", "string")
	return ClientCommands.invoke("gui_text", resolveForClient(params, "path"))
end

function ClientCommands.guiScroll(params: { [string]: any }): any
	Errors.expect(params, "path", "string")
	return ClientCommands.invoke("gui_scroll", resolveForClient(params, "path"))
end

function ClientCommands.viewport(params: { [string]: any }): any
	return ClientCommands.invoke("viewport", params)
end

--- Move the camera the running game renders.
---
--- Relayed to the client rather than run in the plugin, because the plugin
--- lives in the edit DataModel: `camera.set` there reports applied, moves an
--- off-screen camera, and every capture comes back from wherever the player
--- camera happened to be. Two captures at different requested positions came
--- back byte-identical and only the capture's own pose check noticed.
function ClientCommands.cameraSet(params: { [string]: any }): any
	return ClientCommands.invoke("camera_set", params)
end

function ClientCommands.cameraGet(params: { [string]: any }): any
	return ClientCommands.invoke("camera_get", params)
end

function ClientCommands.input(params: { [string]: any }): any
	return ClientCommands.invoke("input", params)
end

--- Hand the camera back. A camera left Scriptable after a capture looks to a
--- player like the game has frozen.
function ClientCommands.cameraRelease(params: { [string]: any }): any
	return ClientCommands.invoke("camera_release", params)
end

function ClientCommands.guiSnapshot(params: { [string]: any }): any
	return ClientCommands.invoke("gui_snapshot", resolveForClient(params, "path"))
end

function ClientCommands.playerState(params: { [string]: any }): any
	return ClientCommands.invoke("player_state", params)
end

return ClientCommands
