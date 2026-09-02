--!strict
--[[
	Debug — how a running game explains itself.

	This is the seam between the two halves.

	The Quality Engine's bridge can already measure geometry: raycasts, bounds,
	overlaps, part counts. What it cannot see is *meaning* — whether the economy
	is solvent, whether forty actors are stuck in one state, whether anyone has
	taken damage in the last minute. Those are facts only the game knows.

	Debug makes the game say them out loud, in JSON, through a replicated
	StringValue the plugin can read while the place is running. No loadstring,
	which does not exist in a play session anyway.

		Debug.expose()                       -- once, on the server
		Debug.probe("economy", function()
			return { gold = totalGold(), shops = #shops }
		end)

	Then from the validator, with a command that already exists:

		dm.properties { path = "ReplicatedStorage.ForgeDebug.Snapshot",
		                properties = { "Value" } }

	It also carries live tunables, so a number can be changed in a running
	session and the effect observed without a rebuild — the shortest iteration
	loop the platform allows.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local Players = game:GetService("Players")

local Debug = {}

local probes: { [string]: () -> any } = {}
local tunables: { [string]: any } = {}
local logBuffer: { any } = {}
local assertions: { any } = {}
local counters: { [string]: number } = {}
local startedAt = os.clock()

Debug.config = {
	logCapacity = 300,
	assertionCapacity = 100,
}

-- ================================= probes ===================================
-- Register anything the game knows that a validator could not infer.
function Debug.probe(name: string, fn: () -> any)
	probes[name] = fn
end

function Debug.removeProbe(name: string)
	probes[name] = nil
end

-- =============================== counters ===================================
-- Cheap event tallies: "damage dealt", "items dropped", "quests completed".
-- A counter that stays at zero through a whole playtest is a system that never
-- ran, which is the most common silent failure in a generated game.
function Debug.count(name: string, amount: number?)
	counters[name] = (counters[name] or 0) + (amount or 1)
end

function Debug.counter(name: string): number
	return counters[name] or 0
end

function Debug.resetCounters()
	table.clear(counters)
end

-- ================================= log ======================================
function Debug.log(level: string, message: string, detail: any?)
	local entry = {
		t = os.clock() - startedAt,
		level = level,
		message = message,
		detail = detail,
	}
	table.insert(logBuffer, entry)
	if #logBuffer > Debug.config.logCapacity then
		table.remove(logBuffer, 1)
	end
	if level == "error" then
		warn("[Forge] " .. message)
	end
	return entry
end

function Debug.info(message: string, detail: any?)
	return Debug.log("info", message, detail)
end

function Debug.warn(message: string, detail: any?)
	return Debug.log("warn", message, detail)
end

function Debug.error(message: string, detail: any?)
	return Debug.log("error", message, detail)
end

--[[
	A soft assertion. It does not stop the game; it records a violated
	expectation so a playtest can end with a list of things that were not true.

	This is deliberately not `assert`. In a live session a hard error hides
	every problem after the first one.
]]
function Debug.check(condition: boolean, description: string, detail: any?): boolean
	if condition then
		return true
	end
	local entry = { description = description, detail = detail, t = os.clock() - startedAt }
	table.insert(assertions, entry)
	if #assertions > Debug.config.assertionCapacity then
		table.remove(assertions, 1)
	end
	warn("[Forge] expectation failed: " .. description)
	return false
end

function Debug.violations(): { any }
	return table.clone(assertions)
end

-- =============================== tunables ===================================
--[[
	A number that can be changed while the game runs.

		local cooldown = Debug.tunable("combat.attackCooldown", 0.55)
		if now - last < cooldown() then return end

	The getter is a function so the value is read fresh every time. Capture it
	into a local once and you have silently opted out of tuning.
]]
function Debug.tunable(path: string, default: any): () -> any
	if tunables[path] == nil then
		tunables[path] = default
	end
	return function()
		return tunables[path]
	end
end

function Debug.setTunable(path: string, value: any): boolean
	if tunables[path] == nil then
		Debug.warn(string.format("tunable '%s' does not exist", path))
		return false
	end
	local previous = tunables[path]
	if typeof(previous) ~= typeof(value) then
		Debug.warn(string.format("tunable '%s' is a %s, refusing a %s", path, typeof(previous), typeof(value)))
		return false
	end
	tunables[path] = value
	Debug.info(string.format("tunable '%s' = %s", path, tostring(value)))
	return true
end

function Debug.tunables(): { [string]: any }
	return table.clone(tunables)
end

-- ================================ snapshot ==================================
local function moduleDescriptions(): { [string]: any }
	local out: { [string]: any } = {}
	local forge = script.Parent
	for _, child in forge:GetChildren() do
		if child == script or not child:IsA("ModuleScript") then
			continue
		end
		local ok, module = pcall(require, child)
		if ok and type(module) == "table" and type(module.describe) == "function" then
			local success, description = pcall(module.describe)
			out[child.Name] = success and description or { error = tostring(description) }
		end
	end
	return out
end

--[[
	Everything the game can say about itself right now.

	Shape is stable on purpose: a validator diffs snapshots across builds, and a
	field that moves is a field that breaks the comparison.
]]
function Debug.snapshot(): { [string]: any }
	local players = {}
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		table.insert(players, {
			name = plr.Name,
			userId = plr.UserId,
			hasCharacter = char ~= nil,
			health = humanoid and humanoid.Health or nil,
			maxHealth = humanoid and humanoid.MaxHealth or nil,
			position = char and char:GetPivot().Position or nil,
		})
	end

	local custom: { [string]: any } = {}
	for name, fn in probes do
		local ok, value = pcall(fn)
		custom[name] = ok and value or { error = tostring(value) }
	end

	return {
		forge = require(script.Parent).VERSION,
		context = RunService:IsServer() and "server" or "client",
		uptime = os.clock() - startedAt,
		modules = moduleDescriptions(),
		probes = custom,
		counters = table.clone(counters),
		tunables = table.clone(tunables),
		violations = assertions,
		players = players,
		performance = {
			heartbeatMs = Stats.HeartbeatTimeMs,
			physicsMs = Stats:FindFirstChild("PhysicsStepTimeMs") and Stats.PhysicsStepTimeMs or nil,
			instanceCount = Stats.InstanceCount,
			memoryMb = Stats:GetTotalMemoryUsageMb(),
		},
	}
end

function Debug.snapshotJson(): string
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, Debug.snapshot())
	if ok then
		return encoded
	end
	return HttpService:JSONEncode({ error = "snapshot could not be encoded: " .. tostring(encoded) })
end

function Debug.logs(count: number?): { any }
	local n = count or #logBuffer
	local out = {}
	for i = math.max(1, #logBuffer - n + 1), #logBuffer do
		table.insert(out, logBuffer[i])
	end
	return out
end

-- ============================== the seam ====================================
--[[
	Say the game has finished starting.

	Every automated look at a running game -- screenshots, interface
	measurement, the quality gate -- has to answer "is it up yet", and until
	now each of them guessed. The guesses were all versions of watching the
	HUD stop changing, and they were all wrong in the same way: a heads-up
	display builds its labels in the first frame and fills them as answers
	arrive, so anything watching it settles while the readout still says
	"Locating" and the player is still unarmed.

	A game whose server spends twelve seconds carving terrain was therefore
	photographed at second two, every time, and every absence in that
	photograph was read as a bug. Several were investigated. None existed.

	One line at the end of a bootstrap ends that whole category. What cannot be
	inferred from outside is trivially known from inside.
]]
function Debug.ready(label: string?)
	local holder = ReplicatedStorage:FindFirstChild("ForgeReady")
	if not holder then
		holder = Instance.new("StringValue")
		holder.Name = "ForgeReady"
		holder.Parent = ReplicatedStorage
	end
	;(holder :: StringValue).Value = label or "ready"
end

--[[
	Publishes the game's self-description where a validator can read it.

	This is a StringValue, not a BindableFunction, and the reason matters:
	**a BindableFunction does not cross the client/server boundary.** Its
	OnInvoke is bound in whichever Lua VM created it, so a server-side handler
	is simply absent from the client's VM and every invocation returns nil. The
	Studio plugin's `client.invoke_bindable` runs client-side, which made the
	first version of this seam look wired and return null forever.

	A replicated StringValue has no such problem. `dm.properties` reads it in
	*any* context -- edit, run, server or client -- using a command that already
	exists, with no new plugin surface:

		dm.properties { path = "ReplicatedStorage.ForgeDebug.Snapshot",
		                properties = { "Value" } }

	`Command` is the write side. Set it with `instance.update` (run context) to
	a JSON object and the answer appears in `Result`:

		{"cmd":"probe","name":"fight"}
		{"cmd":"set","path":"fight.comboWindow","value":1.4}
		{"cmd":"logs","count":40}
		{"cmd":"reset"}

	The BindableFunction is still created for callers inside the same VM, where
	it is the more direct route.
]]
function Debug.expose(parent: Instance?, options: any?): Folder
	local host = parent or ReplicatedStorage
	local opts = options or {}

	local existing = host:FindFirstChild("ForgeDebug")
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "ForgeDebug"

	local snapshot = Instance.new("StringValue")
	snapshot.Name = "Snapshot"
	snapshot.Parent = folder

	local command = Instance.new("StringValue")
	command.Name = "Command"
	command.Parent = folder

	local result = Instance.new("StringValue")
	result.Name = "Result"
	result.Parent = folder

	local function run(request: any): any
		local cmd = type(request) == "table" and request.cmd or request
		if cmd == "snapshot" then
			return Debug.snapshot()
		elseif cmd == "logs" then
			return Debug.logs(tonumber(request.count) or 50)
		elseif cmd == "tunables" then
			return Debug.tunables()
		elseif cmd == "counters" then
			return counters
		elseif cmd == "violations" then
			return Debug.violations()
		elseif cmd == "set" then
			return { ok = Debug.setTunable(request.path, request.value) }
		elseif cmd == "probe" then
			local fn = probes[request.name]
			if not fn then
				return { error = "no probe named " .. tostring(request.name) }
			end
			local ok, value = pcall(fn)
			return ok and value or { error = tostring(value) }
		elseif cmd == "netsim" then
			local Netcode = require(script.Parent.Netcode)
			Netcode.broadcastSimulation(tonumber(request.latencyMs) or 0, tonumber(request.loss) or 0, true)
			return { latencyMs = tonumber(request.latencyMs) or 0, loss = tonumber(request.loss) or 0 }
		elseif cmd == "bench" then
			-- Runs the standard load suite and returns real numbers. Deliberately
			-- driven from outside: a benchmark that runs on every boot is a
			-- benchmark that gets disabled.
			local Bench = require(script.Parent.Bench)
			return Bench.suite({
				entities = tonumber(request.entities) or 2000,
				anchors = tonumber(request.anchors) or 30,
			})
		elseif cmd == "reset" then
			Debug.resetCounters()
			table.clear(assertions)
			return { ok = true }
		end
		return { error = "unknown command: " .. tostring(cmd) }
	end

	command.Changed:Connect(function(text)
		if text == "" then
			return
		end
		local ok, request = pcall(HttpService.JSONDecode, HttpService, text)
		if not ok then
			request = text -- allow a bare command name
		end
		local answered, payload = pcall(run, request)
		result.Value = HttpService:JSONEncode(answered and payload or { error = tostring(payload) })
	end)

	-- Same-VM callers get the direct route.
	local bindable = Instance.new("BindableFunction")
	bindable.Name = "Invoke"
	bindable.OnInvoke = function(request: any): string
		local ok, payload = pcall(run, request)
		return HttpService:JSONEncode(ok and payload or { error = tostring(payload) })
	end
	bindable.Parent = folder

	folder.Parent = host

	-- Keep Snapshot fresh so a reader never has to ask first. Cheap: one
	-- encode every couple of seconds, and only while someone might be looking.
	local interval = opts.interval or 2
	task.spawn(function()
		while folder.Parent do
			local ok, encoded = pcall(Debug.snapshotJson)
			snapshot.Value = ok and encoded or HttpService:JSONEncode({ error = tostring(encoded) })
			task.wait(interval)
		end
	end)

	Debug.info("ForgeDebug exposed at " .. folder:GetFullName())
	return folder
end

function Debug.describe(): { [string]: any }
	local probeNames = {}
	for name in probes do
		table.insert(probeNames, name)
	end
	table.sort(probeNames)
	return {
		probes = probeNames,
		counters = table.clone(counters),
		violations = #assertions,
		logEntries = #logBuffer,
		uptime = os.clock() - startedAt,
	}
end

return Debug
