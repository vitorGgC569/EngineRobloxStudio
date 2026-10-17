--!strict
--[[
	aurarift — server bootstrap.

	Order matters here and each position is a decision:

	  containers -> world -> persistence -> systems -> telemetry -> ready

	The world is built before persistence starts, because a player who lands
	in the window before the floor exists falls through it. `Hello` exists
	because a client that boots after its join broadcast would otherwise sit
	on an empty interface. `Debug.ready` is the last line and stays last.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

-- The engine contract this project was scaffolded against. Keep it: an engine
-- that moves under a game fails far from the line that caused it.
Forge.require("0.2.0")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Content = require(Shared:WaitForChild("Content"))

-- Wire defines every channel in THIS VM. Required eagerly: a server without
-- the channel contract is a server whose Net.on binds nothing, silently.
require(Shared:WaitForChild("Wire"))

local Rng = Forge.Core.Rng
local Net = Forge.Net
local Save = Forge.Save
local Debug = Forge.Debug
local Telemetry = Forge.Telemetry

local PlayerStore = require(script:WaitForChild("systems"):WaitForChild("PlayerStore"))
local Shrine = require(script:WaitForChild("Structures"):WaitForChild("Shrine"))

local startedAt = os.clock()

-- Determinism where it belongs: one seed, named streams downstream.
Rng.seed(Config.seed)

-- Runtime containers. Anything the game creates lives in one of these, so a
-- validator can count them and a cleanup can find them.
for _, name in Config.containers do
	if not Workspace:FindFirstChild(name) then
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = Workspace
	end
end

-- The shrine is standing before the first player can land.
Shrine.build(Workspace:FindFirstChild("World"))

-- Persistence. The template is the shape of a new player's save; it is the
-- PlayerStore's template, so a new field cannot exist in one and not the other.
Save.configure({
	store = Config.saveStore,
	version = 1,
	template = PlayerStore.template(),
})

-- observe connects AND replays for already-loaded players: a plain
-- onLoaded:Connect here silently misses the Studio local player.
PlayerStore.install()
Save.start()

-- A client whose loop came up after its join broadcast asks for the world.
Net.on("Hello", function(player)
	PlayerStore.push(player)
end)

-- Your systems. Each one is a module with a `start()`.
local systems = script:FindFirstChild("systems")
if systems then
	for _, module in systems:GetChildren() do
		if module:IsA("ModuleScript") then
			local ok, system = pcall(require, module)
			if not ok then
				Debug.error(string.format("system '%s' failed to load: %s", module.Name, tostring(system)))
				continue
			end
			if type(system) == "table" and type(system.start) == "function" then
				local started, err = pcall(system.start)
				if not started then
					Debug.error(string.format("system '%s' failed to start: %s", module.Name, tostring(err)))
				end
			end
		end
	end
end

-- Telemetry: started WITH a sink. A started telemetry without a sink is a
-- buffer that grows and tells nobody anything.
Telemetry.start()
if RunService:IsStudio() then
	Telemetry.printSink()
else
	Telemetry.dataStoreSink()
end

--[[
	The live suite.

	Runs after every system is up, because a suite that starts first tests a
	game that does not exist yet. Studio only: the scenarios build and
	destroy real instances.
]]
if Config.selfTest then
	task.defer(function()
		local report = Forge.Testing.runAndPublish(script:FindFirstChild("tests"))
		Debug.info(string.format(
			"self test: %d passed, %d failed, %d hung",
			report.passed or 0, report.failed or 0, report.timedOut or 0))
	end)
end

-- The seam. This is what lets the Quality Engine measure meaning and not
-- just geometry.
Debug.expose()

Debug.probe("session", function()
	return {
		uptime = os.clock() - startedAt,
		players = #Players:GetPlayers(),
		seed = Rng.masterSeed(),
		title = Content.title,
	}
end)

Debug.probe("economy", function()
	local snapshot = {}
	PlayerStore.forEach(function(state)
		table.insert(snapshot, {
			userId = state.player.UserId,
			rift = PlayerStore.riftNumber(state),
			perSecond = state.perSecond,
			power = state.power,
			floor = state.bestFloor,
			unique = PlayerStore.uniqueCount(state.collection),
			rolls = state.rolls,
			life = state.life,
		})
	end)
	return snapshot
end)

Debug.info(string.format("%s up in %.2fs", Config.name, os.clock() - startedAt))
print(string.format("[%s] server ready in %.2fs (seed %d)", Config.name, os.clock() - startedAt, Config.seed))

--[[
	The last line, and it must stay last.

	Everything that photographs, measures or tests this game has to know when
	it is up. Without this line each of them watches the screen stop changing,
	and a HUD settles while the game is still starting.
]]
Debug.ready(Config.name)
