--!strict
-- Runtime telemetry and log access.
--
-- Every value here is measured when the command runs. Where a metric is not
-- available in the current context the field is null and `unavailable` names it,
-- because a fabricated 60 FPS is worse than an honest "not measured".

local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local Config = require(script.Parent.Parent.Config)
local Serialize = require(script.Parent.Parent.Serialize)

local RuntimeCommands = {}

local SEVERITY_BY_MESSAGE_TYPE = {
	[Enum.MessageType.MessageOutput] = "info",
	[Enum.MessageType.MessageInfo] = "info",
	[Enum.MessageType.MessageWarning] = "warning",
	[Enum.MessageType.MessageError] = "error",
}

function RuntimeCommands.context(): string
	if RunService:IsRunning() then
		if RunService:IsServer() and RunService:IsClient() then
			return "run"
		elseif RunService:IsServer() then
			return "server"
		elseif RunService:IsClient() then
			return "client"
		end
		return "run"
	end
	return "edit"
end

--- Sample real frame times over a short window instead of trusting a counter.
local function sampleFrameRate(seconds: number): (number?, number?)
	if seconds <= 0 then
		return nil, nil
	end
	local frames = 0
	local worstDelta = 0
	local elapsed = 0
	local connection
	connection = RunService.Heartbeat:Connect(function(delta: number)
		frames += 1
		elapsed += delta
		if delta > worstDelta then
			worstDelta = delta
		end
	end)
	task.wait(seconds)
	connection:Disconnect()
	if frames == 0 or elapsed <= 0 then
		return nil, nil
	end
	return frames / elapsed, worstDelta * 1000
end

--- run.state: the structured answer to "what is the game doing right now?"
function RuntimeCommands.state(params: { [string]: any }): any
	local sampleSeconds = math.clamp(tonumber(params.sampleSeconds) or 0.5, 0, 5)
	local unavailable: { string } = {}

	local fps, worstFrameMs = sampleFrameRate(sampleSeconds)
	if fps == nil then
		table.insert(unavailable, "fps")
	end

	local memoryMb: number? = nil
	local ok, value = pcall(function()
		return Stats:GetTotalMemoryUsageMb()
	end)
	if ok then
		memoryMb = Serialize.round(value, 1)
	else
		table.insert(unavailable, "memoryMb")
	end

	local instanceCount = #game:GetDescendants()
	local workspaceCount = #workspace:GetDescendants()

	local playerStates = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		table.insert(playerStates, {
			userId = player.UserId,
			name = player.Name,
			displayName = player.DisplayName,
			hasCharacter = character ~= nil,
			position = if root and root:IsA("BasePart") then Serialize.roundVector(root.Position, 2) else nil,
			health = if humanoid then Serialize.round(humanoid.Health, 1) else nil,
			maxHealth = if humanoid then humanoid.MaxHealth else nil,
			walkSpeed = if humanoid then humanoid.WalkSpeed else nil,
			grounded = if humanoid then humanoid.FloorMaterial ~= Enum.Material.Air else nil,
			floorMaterial = if humanoid then tostring(humanoid.FloorMaterial) else nil,
		})
	end

	local errorCount = 0
	local warningCount = 0
	local logOk, history = pcall(function()
		return LogService:GetLogHistory()
	end)
	if logOk then
		for _, entry in ipairs(history) do
			if entry.messageType == Enum.MessageType.MessageError then
				errorCount += 1
			elseif entry.messageType == Enum.MessageType.MessageWarning then
				warningCount += 1
			end
		end
	else
		table.insert(unavailable, "logCounts")
	end

	return {
		context = RuntimeCommands.context(),
		isRunning = RunService:IsRunning(),
		isEdit = RunService:IsEdit(),
		placeName = if game.Name ~= "" then game.Name else "Unsaved",
		placeId = game.PlaceId,
		runtime = {
			fps = if fps then Serialize.round(fps, 2) else nil,
			worstFrameMs = if worstFrameMs then Serialize.round(worstFrameMs, 2) else nil,
			sampleSeconds = sampleSeconds,
			memoryMb = memoryMb,
			instances = instanceCount,
			workspaceInstances = workspaceCount,
		},
		players = playerStates,
		playerCount = #playerStates,
		logs = { errors = errorCount, warnings = warningCount },
		unavailable = unavailable,
	}
end

--- log.tail: the Output window, structured and filterable.
function RuntimeCommands.logTail(params: { [string]: any }): any
	local limit = math.clamp(tonumber(params.limit) or 100, 1, Config.MAX_LOG_LINES)
	local severityFilter = params.severity
	local pattern = params.pattern

	local ok, history = pcall(function()
		return LogService:GetLogHistory()
	end)
	if not ok then
		return { available = false, reason = tostring(history), entries = {} }
	end

	local entries = {}
	-- Walk backwards: the tail is what matters and the history can be long.
	for index = #history, 1, -1 do
		local entry = history[index]
		local severity = SEVERITY_BY_MESSAGE_TYPE[entry.messageType] or "info"
		local include = severityFilter == nil or severity == severityFilter
		if include and pattern ~= nil then
			include = string.find(entry.message, pattern) ~= nil
		end
		if include then
			table.insert(entries, 1, {
				severity = severity,
				message = entry.message,
				timestamp = entry.timestamp,
			})
			if #entries >= limit then
				break
			end
		end
	end

	local counts = { info = 0, warning = 0, error = 0 }
	for _, entry in ipairs(history) do
		local severity = SEVERITY_BY_MESSAGE_TYPE[entry.messageType] or "info"
		counts[severity] = (counts[severity] or 0) + 1
	end

	return {
		available = true,
		totalEntries = #history,
		counts = counts,
		returned = #entries,
		entries = entries,
	}
end

--- run.players: player and character state, on its own for cheap polling.
function RuntimeCommands.players(_params: { [string]: any }): any
	local result = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local leaderstats = player:FindFirstChild("leaderstats")
		local stats = {}
		if leaderstats then
			for _, stat in ipairs(leaderstats:GetChildren()) do
				local valueOk, statValue = pcall(function()
					return (stat :: any).Value
				end)
				if valueOk then
					stats[stat.Name] = Serialize.value(statValue)
				end
			end
		end
		table.insert(result, {
			userId = player.UserId,
			name = player.Name,
			position = if root and root:IsA("BasePart") then Serialize.roundVector(root.Position, 2) else nil,
			health = if humanoid then humanoid.Health else nil,
			state = if humanoid then tostring(humanoid:GetState()) else nil,
			leaderstats = stats,
			attributes = player:GetAttributes(),
		})
	end
	return { players = result, count = #result, context = RuntimeCommands.context() }
end

return RuntimeCommands
