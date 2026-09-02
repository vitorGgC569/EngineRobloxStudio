--!strict
--[[
	brownout — server bootstrap.

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

-- 3. The network contract, declared from the module both VMs require.
--    `Net.define` is per-VM: a channel the server declares does not exist on
--    the client until the client declares it too. One list, required twice.
require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Channels")).define()

-- 3b. The sound bank, registered before any system can ask to play one.
--     Both VMs register it; `Audio.define` is per-VM the same way `Net` is.
require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sound")).register(Forge.Audio)

-- 4. Persistence. The template is the shape of a new player's save.
Save.configure({
	store = Config.saveStore,
	version = 1,
	template = {
		--: The currency. Everything else here is a statistic; this is the only
		--: field a player would be upset to lose.
		watts = 0,
		--: Never spent, so a long-running account has something to show for
		--: itself that buying an upgrade does not take away.
		lifetime = 0,
		nights = 0,
		delivered = 0,
		upgrades = {},
		--: Which onboarding lines this account has already been shown. In the
		--: profile rather than in memory, so a returning player is never taught
		--: their own game a second time.
		taught = {},
	},
})
Save.start()

-- `observe` connects AND replays for players whose profile already loaded.
-- A plain `onLoaded:Connect` here silently misses the Studio local player,
-- because they join before the bootstrap finishes.
--: The per-player push lives in `Store`, which is the system that knows what a
--: crew snapshot contains. This one only counts.
Save.observe(function()
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
		--[[
			Wait for the world before testing it.

			`task.defer` fires as soon as the system loop has called every
			`start()`, and every system in this project returns from `start()`
			immediately and does its real work in a spawned task — which is the
			correct shape, because a system that blocks the loop deadlocks the
			systems waiting on it.

			The consequence is that the suite otherwise races the world build and
			reports a game with no terrain, no lamps and no fuel. That is not a
			flaky test, it is a test asking its question too early, and the
			failure mode is worse than noise: a scenario that loops over an empty
			list passes, so "every lamp lit correctly" goes green against zero
			lamps.
		]]
		--: Every signal, not the last one written. `Outpost` and `Cells` both
		--: wait on `ground_ready` and then race each other, so awaiting only
		--: `cells_ready` caught the faster of the two and still tested a world
		--: with no lamps in it.
		if not Forge.Core.Boot.awaitAll({ "ground_ready", "outpost_ready", "cells_ready" }, 180) then
			Debug.error("self test skipped: the world never finished building")
			return
		end

		local report = Forge.Testing.runAndPublish(script:FindFirstChild("tests"), nil, "brownout")
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
