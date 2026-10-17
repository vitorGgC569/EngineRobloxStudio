--!strict
-- Simulation control and the guarded execution escape hatch.
--
-- `run.start` uses RunService:Run() for a bare-server simulation. Real
-- Play, Run and multiplayer sessions are controlled separately through
-- StudioTestService, so neither path needs keyboard focus or Studio shortcuts.

local RunService = game:GetService("RunService")
local ScriptEditorService = game:GetService("ScriptEditorService")

local Errors = require(script.Parent.Parent.Errors)
local History = require(script.Parent.Parent.History)
local Runtime = require(script.Parent.Runtime)

local SessionCommands = {}

--- run.start: begin simulating the current place.
---
--- Studio's Run mode does **not** roll the DataModel back on stop: whatever the
--- game's scripts built stays in the edit place. Running twice therefore layers
--- a second generated world on top of the first (measured: 372 -> 742
--- descendants), and every count, overlap and budget measured afterwards is
--- contaminated. So the baseline is reported on every start, and a caller that
--- cares can refuse to measure a dirty place.
--- run.server / run.client: the two halves of a real multiplayer session.
---
--- `run.start` uses `RunService:Run()`, which is Studio's "Run" -- a server with
--- no player in it. That is the right context for measuring world generation and
--- the wrong one for measuring anything a player does, because there is no
--- character, no PlayerGui and no client at all.
---
--- These name the distinction instead of leaving a caller to discover it from an
--- empty `run.players`. Neither can synthesise a second machine: Studio decides
--- what a play session contains, and a request it cannot honour is reported
--- rather than approximated.
local function sessionShape(): { [string]: any }
	local players = game:GetService("Players")
	return {
		running = RunService:IsRunning(),
		isServer = RunService:IsServer(),
		isClient = RunService:IsClient(),
		isStudio = RunService:IsStudio(),
		playerCount = #players:GetPlayers(),
		context = Runtime.context(),
	}
end

function SessionCommands.serverShape(_params: { [string]: any }): any
	local shape = sessionShape()
	local problems: { string } = {}

	if not shape.running then
		table.insert(problems, "the place is not running; start a session first")
	elseif shape.playerCount > 0 then
		-- Not an error. A server that also holds a player is Play Solo, and a
		-- caller asking for the server half should know which one it got.
		table.insert(problems, string.format(
			"this session holds %d player(s), so it is a Play Solo session rather than a bare server",
			shape.playerCount
		))
	end

	shape.serverOnly = shape.running and shape.playerCount == 0
	shape.problems = problems
	shape.conclusive = true
	return shape
end

function SessionCommands.clientShape(_params: { [string]: any }): any
	local shape = sessionShape()
	local players = game:GetService("Players")
	local problems: { string } = {}

	if not shape.running then
		table.insert(problems, "the place is not running; nothing client-side exists yet")
	elseif shape.playerCount == 0 then
		table.insert(problems,
			"this session has no player, so it is a bare server: there is no character, "
			.. "no PlayerGui and nothing a UI requirement could be measured against")
	end

	local named: { any } = {}
	for _, player in ipairs(players:GetPlayers()) do
		table.insert(named, {
			name = player.Name,
			userId = player.UserId,
			hasCharacter = player.Character ~= nil,
			hasPlayerGui = player:FindFirstChildOfClass("PlayerGui") ~= nil,
		})
	end

	shape.players = named
	shape.clientReady = shape.running and shape.playerCount > 0
	shape.problems = problems
	shape.conclusive = true
	return shape
end

function SessionCommands.start(params: { [string]: any }): any
	if RunService:IsRunning() then
		return {
			started = false,
			alreadyRunning = true,
			context = Runtime.context(),
		}
	end

	local baseline = #workspace:GetDescendants()
	local maxBaseline = tonumber(params.requireBaselineBelow)
	if maxBaseline ~= nil and baseline >= maxBaseline then
		Errors.raise(
			Errors.UNSUPPORTED_CONTEXT,
			string.format(
				"place already holds %d Workspace descendants (limit %d): it looks like a world was already generated here",
				baseline,
				maxBaseline
			),
			{
				baselineDescendants = baseline,
				requireBaselineBelow = maxBaseline,
				hint = "reopen the place before measuring; Run mode does not undo what game scripts build",
			}
		)
	end

	local ok, err = pcall(function()
		RunService:Run()
	end)
	if not ok then
		Errors.raise(Errors.EXEC, "RunService:Run() was refused: " .. tostring(err), {
			hint = "simulation control requires a plugin context with script injection permission",
		})
	end

	-- Server scripts build the world asynchronously; give them a settling
	-- window so the caller measures a generated world, not an empty one.
	local settle = math.clamp(tonumber(params.settleSeconds) or 2, 0, 30)
	local deadline = os.clock() + settle
	while os.clock() < deadline do
		task.wait(0.1)
	end

	local after = #workspace:GetDescendants()
	return {
		started = true,
		alreadyRunning = false,
		settleSeconds = settle,
		context = Runtime.context(),
		isRunning = RunService:IsRunning(),
		workspaceDescendants = after,
		baselineDescendants = baseline,
		generatedDescendants = after - baseline,
		-- A non-empty baseline means an earlier run already built a world here.
		baselineDirty = baseline > 2,
	}
end

--- run.stop: end the simulation and return Studio to edit mode.
---
--- Stops a `RunService:Run()` bare simulation cleanly. It is not the way to
--- finish a StudioTestService Play/Run/multiplayer job; those sessions are
--- identity-bound and must end through `test.finish` /
--- `rqe.hub.lifecycle.stop_play_solo`.
function SessionCommands.stop(_params: { [string]: any }): any
	if not RunService:IsRunning() then
		return { stopped = false, alreadyStopped = true, context = Runtime.context() }
	end
	local ok, err = pcall(function()
		RunService:Stop()
	end)
	if not ok then
		Errors.raise(Errors.EXEC, "RunService:Stop() was refused: " .. tostring(err))
	end
	task.wait(0.2)
	return {
		stopped = true,
		context = Runtime.context(),
		isRunning = RunService:IsRunning(),
		note = "run.stop is only for RunService bare simulations; "
			.. "use test.finish/stop_play_solo for StudioTestService sessions",
	}
end

local CLIENT_SCRIPT_NAME = "RQEClientBridge"

local function starterPlayerScripts(): Instance
	local starterPlayer = game:GetService("StarterPlayer")
	local scripts = starterPlayer:FindFirstChild("StarterPlayerScripts")
	if scripts == nil then
		Errors.raise(Errors.NOT_FOUND, "StarterPlayer.StarterPlayerScripts is missing")
	end
	return scripts :: Instance
end

--- bridge.install_client: put the client half of the bridge into the place.
---
--- Needed because a plugin only exists in the edit and server DataModels, while
--- ProximityPrompt activation and GUI input only work on the client. Installing
--- this LocalScript is what makes the client half of a game addressable.
local function installClientImpl(params: { [string]: any }): any
	local ClientSource = require(script.Parent.Parent.ClientSource)
	local parent = starterPlayerScripts()

	local existing = parent:FindFirstChild(CLIENT_SCRIPT_NAME)
	local replaced = existing ~= nil
	if existing then
		existing:Destroy()
	end

	local localScript = Instance.new("LocalScript")
	localScript.Name = CLIENT_SCRIPT_NAME
	localScript.Parent = parent
	local sourceOk, sourceError = pcall(function()
		ScriptEditorService:UpdateSourceAsync(localScript, function(_old)
			return ClientSource
		end)
	end)
	if not sourceOk then
		localScript:Destroy()
		Errors.raise(
			Errors.EXEC,
			"ScriptEditorService:UpdateSourceAsync failed while installing client bridge: "
				.. tostring(sourceError)
		)
	end

	-- Create the meeting point at edit time so it is saved with the place and
	-- replicates before the client script's WaitForChild runs. Creating it
	-- lazily on the first command would race the client's startup.
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local channelName = "RQEClientChannel"
	local channel = ReplicatedStorage:FindFirstChild(channelName)
	if channel and not channel:IsA("RemoteFunction") then
		channel:Destroy()
		channel = nil
	end
	if channel == nil then
		channel = Instance.new("RemoteFunction")
		channel.Name = channelName
		channel.Parent = ReplicatedStorage
	end

	return {
		installed = true,
		replaced = replaced,
		path = localScript:GetFullName(),
		channel = channel:GetFullName(),
		sourceBytes = #ClientSource,
		note = "the client bridge answers once a play session starts; it does nothing in edit mode",
	}
end

--- bridge.remove_client: take the instrumentation back out of the place.
local function removeClientImpl(_params: { [string]: any }): any
	local parent = starterPlayerScripts()
	local existing = parent:FindFirstChild(CLIENT_SCRIPT_NAME)
	local channel = game:GetService("ReplicatedStorage"):FindFirstChild("RQEClientChannel")
	if existing == nil and channel == nil then
		return { removed = false, reason = "not_installed" }
	end
	if existing then
		existing:Destroy()
	end
	if channel then
		channel:Destroy()
	end
	return { removed = true, script = existing ~= nil, channel = channel ~= nil }
end

SessionCommands.installClient = function(params: { [string]: any }): any
	return History.record("RQE bridge.install_client", function()
		return installClientImpl(params)
	end)
end

SessionCommands.removeClient = function(params: { [string]: any }): any
	return History.record("RQE bridge.remove_client", function()
		return removeClientImpl(params)
	end)
end

--- bridge.exec: run Luau supplied by the hub.
---
--- This is an arbitrary-code channel and is treated as one. It exists because a
--- capability the typed API does not cover yet would otherwise cost a Studio
--- restart to add. The trust boundary is the loopback socket: run the hub with
--- --token if anything untrusted can reach this machine's ports.
function SessionCommands.exec(params: { [string]: any }): any
	local source = Errors.expect(params, "source", "string")

	if type(loadstring) ~= "function" then
		Errors.raise(Errors.UNSUPPORTED_CONTEXT, "loadstring is unavailable in this plugin context")
	end

	local chunk, compileError = loadstring(source, params.chunkName or "rqe.exec")
	if chunk == nil then
		Errors.raise(Errors.BAD_PARAMS, "could not compile source: " .. tostring(compileError), { source = source })
	end

	local started = os.clock()
	local ok, result = pcall(chunk :: any)
	local elapsedMs = (os.clock() - started) * 1000

	if not ok then
		Errors.raise(Errors.EXEC, "source raised: " .. tostring(result), { elapsedMs = elapsedMs })
	end

	local Serialize = require(script.Parent.Parent.Serialize)
	return {
		returned = Serialize.value(result),
		elapsedMs = elapsedMs,
		context = Runtime.context(),
	}
end

return SessionCommands
