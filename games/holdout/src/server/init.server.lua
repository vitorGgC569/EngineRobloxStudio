--!strict
--[[
	holdout — server bootstrap.

	This file wires the engine and nothing else. Every line below is
	infrastructure; none of it decides what your game is.

	Add gameplay in `src/server/systems/`. The rule that keeps this project
	from turning into the thing Forge exists to replace: no system in here may
	be a template of a genre. Write the game you mean.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

-- The engine contract this project was scaffolded against. Keep it: an engine
-- that moves under a game fails far from the line that caused it.
Forge.require("0.2.0")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Rng = Forge.Core.Rng
local Net = Forge.Net
local Save = Forge.Save
local Debug = Forge.Debug

local startedAt = os.clock()

-- 1. Determinism where it belongs: one seed, named streams downstream.
Rng.seed(Config.seed)

-- 2. Runtime containers. Anything the game creates lives in one of these, so a
--    validator can count them and a cleanup can find them.
for _, name in Config.containers do
	if not Workspace:FindFirstChild(name) then
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = Workspace
	end
end

-- 3. The world, before anybody can stand in it.
--
--    Built here rather than lazily on join, because a player arrives faster
--    than a world builds and the failure mode is a character in freefall
--    against an empty sky. That has happened twice in this repository already.
local World = require(script.systems.World)
local built = World.build()
Debug.info(string.format("world: %d trees, %d rocks, %d ruins",
	built.trees or 0, built.rocks or 0, built.ruins or 0))

-- 4. Persistence. The template is the shape of a new player's save.
Save.configure({
	store = Config.saveStore,
	version = 1,
	template = {
		-- add your fields here; anything you add later is backfilled
		-- automatically for existing players
	},
})
Save.start()

-- `observe` connects AND replays for players whose profile already loaded.
-- A plain `onLoaded:Connect` here silently misses the Studio local player,
-- because they join before the bootstrap finishes.
--: The scaffold fired a `StateSync` remote here that this game's own network
--: contract does not declare, so the first profile load threw. Left alone
--: until there is a save shape worth sending; a remote defined for the sake
--: of the line that uses it is how a contract stops meaning anything.
Save.observe(function(player, profile)
	Debug.count("profiles.loaded")
end)

-- 5. Your systems. Each one is a module with a `start()`.
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

--[[
	6. The live suite.

	Runs after every system is up, because a suite that starts first tests a
	game that does not exist yet. Studio only: the scenarios build and destroy
	real instances, which does not belong in a session somebody is playing.

	`forge gametest` reads the report this publishes. That command is the only
	thing in this project that can answer "does the game still work" without a
	person watching a screen, and it needs this line to have anything to read.
]]
if Config.selfTest then
	task.defer(function()
		local report = Forge.Testing.runAndPublish(script:FindFirstChild("tests"))
		Debug.info(string.format(
			"self test: %d passed, %d failed, %d hung",
			report.passed or 0, report.failed or 0, report.timedOut or 0))
	end)
end

-- 7. The seam. This is what lets the Quality Engine measure meaning and not
--    just geometry. Removing it does not break the game; it blinds the
--    validator, which is worse.
Debug.expose()

Debug.probe("session", function()
	return {
		uptime = os.clock() - startedAt,
		players = #Players:GetPlayers(),
		seed = Rng.masterSeed(),
	}
end)

Debug.info(string.format("%s up in %.2fs", Config.name, os.clock() - startedAt))
print(string.format("[%s] server ready in %.2fs (seed %d)", Config.name, os.clock() - startedAt, Config.seed))
