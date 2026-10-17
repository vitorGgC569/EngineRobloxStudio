--!strict
--[[
	anime-arena — server bootstrap.

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

-- The engine contract this project was scaffolded against.
Forge.require("0.2.0")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Wire = require(Shared:WaitForChild("Wire"))

local Rng = Forge.Core.Rng
local Net = Forge.Net
local Save = Forge.Save
local Debug = Forge.Debug

local startedAt = os.clock()

Rng.seed(Config.seed)

-- Remotes before any handler.
Wire.install()

-- Runtime containers.
for _, name in Config.containers do
	if not Workspace:FindFirstChild(name) then
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = Workspace
	end
end

-- Build world before players spawn.
Players.CharacterAutoLoads = false

local World = require(script.systems.World)
World.build()

Players.CharacterAutoLoads = true
for _, player in Players:GetPlayers() do
	if not player.Character then
		player:LoadCharacter()
	end
end

Save.configure({
	store = Config.saveStore,
	version = 1,
	template = {
		level = 1,
		xp = 0,
		currency = 0,
	},
})
Save.start()

Save.observe(function(player, profile)
	Debug.count("profiles.loaded")
	Net.fire(player, "StateSync", profile)
end)

-- Systems.
local Combat = require(script.systems.Combat)
local Enemies = require(script.systems.Enemies)
local Progression = require(script.systems.Progression)
Combat.start()
Enemies.start()
Progression.start()

-- 5. Your systems. Each one is a module with a `start()`.
-- (loaded explicitly above)

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
		local report = Forge.Testing.runAndPublish(script:FindFirstChild("tests"), nil, "anime-arena")
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

--[[
	8. The last line, and it must stay last.

	Everything that photographs, measures or tests this game has to know when
	it is up, and without this line each of them guesses. The guesses are all
	versions of watching the screen stop changing, and they are all wrong in
	the same way: a HUD builds its labels in the first frame and fills them as
	answers arrive, so a watcher settles while the game is still starting.

	`CLAUDE.md` has asked for this line since it was written, and it was in two
	of thirty-nine games -- because it was a rule in a document rather than a
	line in this file. A convention the scaffold does not produce is a
	convention that does not exist.

	Anything you add below this line runs after the game has announced itself
	as ready, which is exactly the thing this prevents.
]]
Debug.ready(Config.name)
