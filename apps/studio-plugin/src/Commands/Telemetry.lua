--!strict
-- Runtime telemetry: the measurements a performance budget needs to be real.
--
-- Frame rate was reachable only through `bridge.exec` before this, and memory,
-- physics step cost and network traffic were not observed at all. A budget
-- nobody measures is a comment, so this family exists to turn every number in a
-- contract's performance section into something with a producer.
--
-- Two habits, both learned here:
--
-- **Sample, do not read a counter.** `Stats` exposes instantaneous values that
-- swing wildly frame to frame. A single read reports whatever happened during
-- one frame, which is why a place can measure 12 FPS and 60 FPS one second
-- apart. Everything timing-related here samples a window and reports the
-- distribution.
--
-- **A missing metric is null and named.** Some values do not exist in edit
-- mode, some only exist on a server, and some depend on a Stats item that a
-- given Studio build does not expose. A fabricated number is far worse than an
-- honest gap, so every absence lands in `unavailable`.

local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local Workspace = game:GetService("Workspace")

local Errors = require(script.Parent.Parent.Errors)
local Serialize = require(script.Parent.Parent.Serialize)

local Telemetry = {}

--- Longest window a caller may ask for. The bridge holds a command thread open
--- while it samples, and a request for a minute would look like a hung plugin.
local MAX_SAMPLE_SECONDS = 10

local function round(value: number?, places: number?): number?
	if value == nil then
		return nil
	end
	return Serialize.round(value, places or 3)
end

local function sampleSeconds(params: { [string]: any }): number
	local seconds = tonumber(params.seconds) or 1.0
	if seconds <= 0 or seconds > MAX_SAMPLE_SECONDS then
		Errors.raise("E_BAD_PARAMS", string.format(
			"seconds must be between 0 and %d", MAX_SAMPLE_SECONDS
		))
	end
	return seconds
end

--- Read a Stats item by path, tolerating builds that do not have it.
local function statValue(path: { string }): number?
	local node: any = Stats
	for _, segment in ipairs(path) do
		local ok, child = pcall(function()
			return node:FindFirstChild(segment)
		end)
		if not ok or child == nil then
			return nil
		end
		node = child
	end
	local ok, value = pcall(function()
		return node:GetValue()
	end)
	if ok and type(value) == "number" then
		return value
	end
	return nil
end

local function distribution(samples: { number }): { [string]: any }
	if #samples == 0 then
		return { count = 0 }
	end
	local sorted = table.clone(samples)
	table.sort(sorted)
	local total = 0
	for _, value in ipairs(sorted) do
		total += value
	end
	local function percentile(fraction: number): number
		local position = math.clamp(math.floor(#sorted * fraction) + 1, 1, #sorted)
		return sorted[position]
	end
	return {
		count = #sorted,
		mean = round(total / #sorted),
		min = round(sorted[1]),
		max = round(sorted[#sorted]),
		p50 = round(percentile(0.5)),
		-- The tail is what a player feels. A mean of 60 with a p99 of 12 is a
		-- game that stutters, and the mean alone hides it completely.
		p95 = round(percentile(0.95)),
		p99 = round(percentile(0.99)),
	}
end

--- runtime.metrics: frame timing, sampled over a real window.
function Telemetry.metrics(params: { [string]: any }): any
	local seconds = sampleSeconds(params)
	local unavailable: { string } = {}

	if not RunService:IsRunning() then
		return {
			conclusive = false,
			running = false,
			reason = "the place is not running; frame timing does not exist in edit mode",
			unavailable = { "frameTimeMs", "fps", "heartbeat" },
		}
	end

	local frameTimes: { number } = {}
	local elapsed = 0
	local connection
	connection = RunService.Heartbeat:Connect(function(delta)
		elapsed += delta
		table.insert(frameTimes, delta * 1000)
	end)
	local deadline = os.clock() + seconds
	while os.clock() < deadline do
		task.wait()
	end
	connection:Disconnect()

	if #frameTimes == 0 then
		return {
			conclusive = false,
			running = true,
			reason = "no Heartbeat fired during the sample window",
			unavailable = { "frameTimeMs", "fps" },
		}
	end

	local frameStats = distribution(frameTimes)
	local fpsSamples: { number } = {}
	for _, milliseconds in ipairs(frameTimes) do
		if milliseconds > 0 then
			table.insert(fpsSamples, 1000 / milliseconds)
		end
	end

	local heartbeat = statValue({ "Heartbeat" })
	if heartbeat == nil then
		table.insert(unavailable, "Stats.Heartbeat")
	end

	return {
		conclusive = true,
		running = true,
		sampleSeconds = round(elapsed),
		frameTimeMs = frameStats,
		fps = distribution(fpsSamples),
		heartbeatMs = round(heartbeat),
		unavailable = unavailable,
	}
end

--- runtime.memory: where the megabytes are, by category.
function Telemetry.memory(_params: { [string]: any }): any
	local unavailable: { string } = {}

	local total = nil
	local ok, value = pcall(function()
		return Stats:GetTotalMemoryUsageMb()
	end)
	if ok and type(value) == "number" then
		total = value
	else
		table.insert(unavailable, "totalMb")
	end

	local categories: { [string]: any } = {}
	-- Names Roblox uses for the memory performance items. A build without one
	-- reports null for it rather than omitting the row, so a caller can tell
	-- "zero" from "not measured".
	for _, name in ipairs({
		"Instances", "Signals", "LuaHeap", "Script", "PhysicsCollision",
		"PhysicsParts", "GraphicsTexture", "GraphicsMeshParts", "GraphicsParts",
		"GraphicsSolidModels", "GraphicsSpatialHash", "Sounds", "Animation",
	}) do
		local measured = nil
		local found, memoryValue = pcall(function()
			return Stats:GetMemoryUsageMbForTag((Enum.DeveloperMemoryTag :: any)[name])
		end)
		if found and type(memoryValue) == "number" then
			measured = round(memoryValue, 2)
		else
			table.insert(unavailable, "memory." .. name)
		end
		categories[name] = measured
	end

	return {
		conclusive = total ~= nil,
		totalMb = round(total, 2),
		categories = categories,
		instanceCount = #game:GetDescendants(),
		unavailable = unavailable,
	}
end

--- runtime.physics: simulation cost and what is actually moving.
---
--- Awake part count matters more than any single timing: a place that is slow
--- because 4,000 parts never fall asleep has a different fix from one that is
--- slow because of one expensive constraint.
function Telemetry.physics(params: { [string]: any }): any
	local seconds = sampleSeconds(params)
	if not RunService:IsRunning() then
		return {
			conclusive = false,
			running = false,
			reason = "physics does not step in edit mode",
			unavailable = { "stepTimeMs", "awakeParts" },
		}
	end

	local stepTimes: { number } = {}
	local connection
	connection = RunService.Stepped:Connect(function(_, delta)
		table.insert(stepTimes, delta * 1000)
	end)
	local deadline = os.clock() + seconds
	while os.clock() < deadline do
		task.wait()
	end
	connection:Disconnect()

	local unavailable: { string } = {}
	local physicsStep = statValue({ "PhysicsStepTimeMs" })
	if physicsStep == nil then
		table.insert(unavailable, "Stats.PhysicsStepTimeMs")
	end

	local awake = 0
	local anchored = 0
	local total = 0
	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant:IsA("BasePart") then
			total += 1
			if descendant.Anchored then
				anchored += 1
			else
				local ok, sleeping = pcall(function()
					return descendant:GetNetworkOwner() ~= nil or descendant.AssemblyLinearVelocity.Magnitude > 0.01
				end)
				if ok and sleeping then
					awake += 1
				end
			end
		end
	end

	return {
		conclusive = true,
		running = true,
		sampleSeconds = seconds,
		stepTimeMs = distribution(stepTimes),
		physicsStepMs = round(physicsStep),
		parts = { total = total, anchored = anchored, unanchoredMoving = awake },
		gravity = round(Workspace.Gravity, 2),
		unavailable = unavailable,
	}
end

--- runtime.network: replication traffic, in and out.
function Telemetry.network(_params: { [string]: any }): any
	local unavailable: { string } = {}
	local function stat(path: { string }, label: string): number?
		local value = statValue(path)
		if value == nil then
			table.insert(unavailable, label)
		end
		return round(value, 2)
	end

	local incoming = stat({ "DataReceiveKbps" }, "DataReceiveKbps")
	local outgoing = stat({ "DataSendKbps" }, "DataSendKbps")
	local physicsReceive = stat({ "PhysicsReceiveKbps" }, "PhysicsReceiveKbps")
	local physicsSend = stat({ "PhysicsSendKbps" }, "PhysicsSendKbps")

	local remotes = 0
	local bindables = 0
	for _, descendant in ipairs(game:GetDescendants()) do
		if descendant:IsA("RemoteEvent") or descendant:IsA("RemoteFunction") then
			remotes += 1
		elseif descendant:IsA("BindableEvent") or descendant:IsA("BindableFunction") then
			bindables += 1
		end
	end

	return {
		conclusive = incoming ~= nil or outgoing ~= nil,
		running = RunService:IsRunning(),
		dataReceiveKbps = incoming,
		dataSendKbps = outgoing,
		physicsReceiveKbps = physicsReceive,
		physicsSendKbps = physicsSend,
		remoteObjects = remotes,
		bindableObjects = bindables,
		playerCount = #Players:GetPlayers(),
		unavailable = unavailable,
	}
end

--- runtime.errors and runtime.warnings: the log, split by severity.
---
--- Separate commands rather than a filter argument because a gate asks a
--- different question of each. "Were there any errors" is a release blocker;
--- "were there warnings" is a report.
local function logsOfType(messageType: Enum.MessageType, limit: number): any
	local entries = LogService:GetLogHistory()
	local matched: { any } = {}
	local total = 0
	for index = #entries, 1, -1 do
		local entry = entries[index]
		if entry.messageType == messageType then
			total += 1
			if #matched < limit then
				table.insert(matched, {
					message = entry.message,
					timestamp = entry.timestamp,
				})
			end
		end
	end
	return matched, total
end

function Telemetry.errors(params: { [string]: any }): any
	local limit = math.clamp(tonumber(params.limit) or 100, 1, 500)
	local matched, total = logsOfType(Enum.MessageType.MessageError, limit)
	return {
		conclusive = true,
		severity = "error",
		entries = matched,
		returned = #matched,
		total = total,
		truncated = total > #matched,
	}
end

function Telemetry.warnings(params: { [string]: any }): any
	local limit = math.clamp(tonumber(params.limit) or 100, 1, 500)
	local matched, total = logsOfType(Enum.MessageType.MessageWarning, limit)
	return {
		conclusive = true,
		severity = "warning",
		entries = matched,
		returned = #matched,
		total = total,
		truncated = total > #matched,
	}
end

--- runtime.events: what the game has wired up, and where.
---
--- Not a live event stream -- a plugin cannot subscribe to a game's own signals
--- from outside. This is the connectable surface, which is what a scenario needs
--- in order to know what it can drive.
function Telemetry.events(params: { [string]: any }): any
	local root = if params.path ~= nil
		then require(script.Parent.Parent.Resolve).instance(params.path)
		else game
	local limit = math.clamp(tonumber(params.limit) or 200, 1, 1000)

	local found: { any } = {}
	local counts = { RemoteEvent = 0, RemoteFunction = 0, BindableEvent = 0, BindableFunction = 0 }
	local total = 0

	for _, descendant in ipairs(root:GetDescendants()) do
		local className = descendant.ClassName
		if counts[className] ~= nil then
			counts[className] += 1
			total += 1
			if #found < limit then
				table.insert(found, {
					name = descendant.Name,
					className = className,
					path = descendant:GetFullName(),
				})
			end
		end
	end

	return {
		conclusive = true,
		events = found,
		counts = counts,
		returned = #found,
		total = total,
		truncated = total > #found,
	}
end

return Telemetry
