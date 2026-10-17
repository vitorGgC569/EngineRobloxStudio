--!strict
-- RQE Studio Bridge - Roblox Studio plugin entry point.
--
-- Turns a running Studio into an addressable, queryable service. The plugin
-- connects to a loopback hub, then loops: poll for typed commands, execute them
-- against the real DataModel, report structured results.
--
-- It re-handshakes whenever the Studio context changes (edit <-> playtest) so
-- the hub always knows whether an answer came from an edited place or a running
-- game. That distinction is the whole point: it is what separates
-- STATICALLY_VALIDATED from RUNTIME_VALIDATED.

local RunService = game:GetService("RunService")
-- Native Play and multiplayer create a client plugin context as well. Only
-- the server can poll HTTP; LocalScripts use the installed client relay.
if RunService:IsRunning() and RunService:IsClient() and not RunService:IsServer() then return end

local Auth = require(script.Auth)
local Config = require(script.Config)
local Dispatcher = require(script.Dispatcher)
local Runtime = require(script.Commands.Runtime)
local Transport = require(script.Transport)

local toolbar = plugin:CreateToolbar("RQE")
local toggleButton = toolbar:CreateButton(
	"Bridge",
	"Connect this Studio to the RQE agent bridge",
	"rbxasset://textures/ui/common/robux.png"
)
toggleButton.ClickableWhenViewportHidden = true

local state = {
	running = false,
	transport = nil :: any,
	context = Runtime.context(),
	commandsHandled = 0,
	lastStatus = "idle",
}

local function hubUrl(): string
	local stored = plugin:GetSetting(Config.SETTING_KEYS.hubUrl)
	if type(stored) == "string" and #stored > 0 then
		return stored
	end
	return Config.DEFAULT_HUB_URL
end

local function setStatus(message: string)
	state.lastStatus = message
	toggleButton:SetActive(state.running)
	print(string.format("[RQE Bridge] %s", message))
end

--- Execute one command envelope and build its response envelope.
local function handle(command: { [string]: any }): { [string]: any }
	local started = os.clock()
	local ok, payload = Dispatcher.execute(command.method, command.params)
	local elapsedMs = (os.clock() - started) * 1000

	state.commandsHandled += 1

	local response: { [string]: any } = {
		id = command.id,
		ok = ok,
		elapsedMs = elapsedMs,
		-- Stamped per response, not per session: a playtest can start between
		-- two commands and the agent must see that in the answer itself.
		context = Runtime.context(),
		place = game.Name,
	}
	if ok then
		response.result = payload
	else
		response.error = payload
	end
	return response
end

--- Flush the in-memory result outbox without losing a completed command when
--- the hub answers ambiguously or the socket drops. Reporting is idempotent at
--- the hub: a duplicate correlation id is rejected rather than re-applied.
---
--- `report` yields. The poll loop and the background flusher both call this.
--- Without the guard, each can clone `pending` before the other clears it and
--- both post the same batch.
local flushing = false

local function flushPending(transport: any, pending: { any }): boolean
	if flushing or #pending == 0 then
		return true
	end
	flushing = true
	local batch = table.clone(pending)
	table.clear(pending)
	local ok, accepted = pcall(function()
		return transport:report(batch)
	end)
	if not ok or accepted ~= true then
		--[[
			An uncodable result must not become a permanent block.

			Measured: one response carrying a value `JSONEncode` cannot
			represent (a buffer, in that case) failed every flush, the loop
			reconnected on each failure, the same batch was retried forever,
			and the bridge never polled again -- one command bricked the
			session. When the failure is encoding, the *response* is the
			problem, so replace it with one that encodes and let the caller
			see an honest error instead of a timeout. Transport failures keep
			the batch for retry: there the response may still be good.
		]]
		local encodeFailure = tostring(transport.lastError or ""):find("could not encode", 1, true) ~= nil
		if encodeFailure then
			local doomed = batch
			batch = {}
			for _, response in ipairs(doomed) do
				table.insert(batch, {
					id = response.id,
					ok = false,
					elapsedMs = response.elapsedMs or 0,
					context = response.context or "unknown",
					place = response.place or game.Name,
					error = {
						code = "E_SERIALIZE",
						message = "response could not be encoded as JSON: "
							.. tostring(transport.lastError),
					},
				})
			end
			pcall(function()
				transport:report(batch)
			end)
			flushing = false
			return true
		end
		-- New command threads may have appended while RequestAsync yielded.
		-- Restore the older batch ahead of them so completion order remains
		-- deterministic. A throw used to leave `flushing` true, and every
		-- later flush then pretended the outbox was empty.
		for index = #batch, 1, -1 do
			table.insert(pending, 1, batch[index])
		end
		flushing = false
		return false
	end
	flushing = false
	return true
end

--- Responses from commands still running on their own threads.
---
--- Module scope, and it has to be. This was a local inside `loop`, so the
--- `flusher` below — written afterwards, at module level, referring to the
--- same name — resolved a *global* that is nil. `#pending` on nil throws, and
--- it threw every fiftieth of a second for the life of every session: an error
--- in the log of every game this validator has ever looked at, and a flusher
--- that never flushed anything. The name looked in scope and was not.
local pending = {}

local function loop()
	local backoff = Config.RECONNECT_DELAY_SECONDS
	--- Number of commands dispatched by the current session that have not yet
	--- produced a response. A command such as `run.start` changes the Studio
	--- context before its settle window finishes. Re-handshaking while it is
	--- still active would report its eventual response under the successor
	--- session, which defeats the hub's strong dispatch-session correlation.
	local activeCommands = 0

	while state.running do
		local transport = state.transport

		if not transport.connected then
			local connected, detail = transport:connect(Runtime.context())
			if connected then
				state.context = Runtime.context()
				backoff = Config.RECONNECT_DELAY_SECONDS
				setStatus(string.format("connected to %s as %s (%s)", hubUrl(), tostring(detail), state.context))
			else
				setStatus(string.format("hub unreachable (%s); retrying in %ds", tostring(detail), backoff))
				task.wait(backoff)
				backoff = math.min(backoff * 2, Config.MAX_RECONNECT_DELAY_SECONDS)
				continue
			end
		end

		-- Flush completed work before considering a context switch. Every result
		-- must be reported by the exact session that polled its command.
		if not flushPending(transport, pending) then
			-- The hub answers an unknown session with 409 on /bridge/result, the
			-- same as on /bridge/poll. Poll drops the session and the next cycle
			-- handshakes again. Leaving `connected` true here retries that dead
			-- session forever and never reaches poll, so the outbox cannot drain.
			setStatus(string.format("result outbox blocked (%s); reconnecting", tostring(transport.lastError)))
			transport:disconnect()
			task.wait(backoff)
			backoff = math.min(backoff * 2, Config.MAX_RECONNECT_DELAY_SECONDS)
			continue
		end

		-- A context switch invalidates the session's advertised mode. Commands
		-- already dispatched by this session retain completion authority, though,
		-- so stop polling and let them finish before re-registering. This is the
		-- normal path for run.start/run.stop, not an exceptional race.
		local currentContext = Runtime.context()
		if currentContext ~= state.context then
			if activeCommands > 0 or #pending > 0 then
				task.wait()
				continue
			end
			setStatus(string.format("context changed %s -> %s; re-registering", state.context, currentContext))
			transport:disconnect()
			continue
		end

		local ok, commands = transport:poll()
		if not ok then
			setStatus(string.format("poll failed (%s); reconnecting", tostring(transport.lastError)))
			transport:disconnect()
			task.wait(backoff)
			backoff = math.min(backoff * 2, Config.MAX_RECONNECT_DELAY_SECONDS)
			continue
		end

		backoff = Config.RECONNECT_DELAY_SECONDS

		-- Run each command on its own thread and report whatever has finished.
		--
		-- Executing inline blocks the poll loop for as long as the slowest
		-- command takes, and a yielding call freezes the whole bridge:
		-- measured, one `ContentProvider:PreloadAsync` left the plugin
		-- unreachable until Studio was restarted. A command may now hang
		-- without taking everything else with it.
		for _, command in ipairs(commands) do
			activeCommands += 1
			task.spawn(function()
				-- handle is not supposed to throw. If it does, the counter
				-- used to stay raised and a context change waited forever,
				-- because the decrement sat on the success path only.
				local ok, response = pcall(handle, command)
				if not ok then
					response = {
						id = command.id,
						ok = false,
						error = tostring(response),
						elapsedMs = 0,
						context = "unknown",
						place = game.Name,
					}
				end
				table.insert(pending, response)
				activeCommands -= 1
			end)
		end

		if not flushPending(transport, pending) then
			-- Same dead session as the flush before poll. Waiting here leaves
			-- `connected` true, so the background flusher keeps posting it.
			setStatus(string.format("result outbox blocked (%s); reconnecting", tostring(transport.lastError)))
			transport:disconnect()
			task.wait(backoff)
			backoff = math.min(backoff * 2, Config.MAX_RECONNECT_DELAY_SECONDS)
			continue
		end
		-- The outbox is also drained by `flusher` below, on its own clock.

		-- Yield between cycles so a fast hub cannot starve Studio's main thread.
		task.wait()
	end
end

--- Drain finished results on their own clock, not the poll's.
---
--- The outbox used to be flushed once per cycle, immediately after commands
--- were spawned. A command that finishes synchronously is already in `pending`
--- by then and goes out at once; a command that *yields* -- every `client.*`
--- goes through `RemoteFunction:InvokeClient` -- finishes after that flush and
--- waits for the next one, which arrives only after the next `poll()`.
---
--- `poll()` is a long poll and holds for `DEFAULT_POLL_HOLD_SECONDS` (20).
--- Measured before this loop existed: `dm.properties` 0.03s, `runtime.errors`
--- 0.04s, `actor.state` 0.03s -- and `client.info` 20.05s, every time, while
--- the client itself answered in 0.02 milliseconds. A five-hundred-fold
--- overhead in one hop, and the whole of it was this scheduling detail.
local function flusher()
	while state.running do
		local transport = state.transport
		-- A disconnect is how a dead session is dropped. Reporting through it
		-- anyway posts a nil session every 50ms until the poll loop wakes.
		-- A failed report has to drop it here too: poll can be blocked for
		-- the whole hold, and the loop will not see this failure until then.
		if transport ~= nil and transport.connected and #pending > 0 then
			if not flushPending(transport, pending) then
				transport:disconnect()
			end
		end
		task.wait(0.05)
	end
end

local function start()
	if state.running then
		return
	end
	state.running = true
	state.transport = Transport.new(hubUrl(), Auth.bearerToken, Auth.installationId)
	setStatus("starting")
	task.spawn(loop)
	task.spawn(flusher)
end

local function stop()
	if not state.running then
		return
	end
	state.running = false
	if state.transport then
		state.transport:disconnect()
	end
	setStatus("stopped")
end

toggleButton.Click:Connect(function()
	if state.running then
		stop()
	else
		start()
	end
end)

plugin.Unloading:Connect(stop)

-- Auto-connect by default: an agentic platform cannot depend on a human
-- clicking a toolbar button before every run.
local autoConnect = plugin:GetSetting(Config.SETTING_KEYS.autoConnect)
if autoConnect == nil then
	plugin:SetSetting(Config.SETTING_KEYS.autoConnect, true)
	autoConnect = true
end

if autoConnect then
	start()
else
	setStatus("idle (auto-connect disabled)")
end
