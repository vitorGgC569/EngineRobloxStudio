--!strict
--[[
	Proving Ground — server bootstrap.

	A vertical slice built on Forge: procedural arena, three enemy types sharing
	one brain, a three-hit melee chain with a dodge and a block, and the whole
	thing legible to the Quality Engine through Debug.expose().

	It exists to prove the primitives compose. It is not a template — copy the
	patterns, not the game.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

-- The engine contract this game was written against. Before 1.0 the minor
-- number carries breaking changes, so a mismatch here is a real one.
Forge.require("0.2.0")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Content = require(Shared:WaitForChild("Content"))

local Rng = Forge.Core.Rng
local Net = Forge.Net
local Save = Forge.Save
local Rig = Forge.Rig
local Debug = Forge.Debug
local Reference = Forge.Reference
local World = Forge.World

local startedAt = os.clock()

Rng.seed(Config.seed)

-- Nobody spawns before there is ground to spawn on.
Players.CharacterAutoLoads = false

for _, name in Config.containers do
	if not Workspace:FindFirstChild(name) then
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = Workspace
	end
end

-- The whole wire contract. Anything not here does not cross.
Net.define({
	StateSync = { dir = "s2c" },
	Notify = { dir = "s2c" },
	Hit = { dir = "s2c" },
	Breath = { dir = "s2c" },
	Stamina = { dir = "s2c" },

	Shot = { dir = "s2c" },
	Impact = { dir = "s2c" },
	Weapon = { dir = "s2c" },

	Dodge = { dir = "c2s", rate = 3, shape = { dir = "Vector3" } },
	SetBlock = { dir = "c2s", rate = 8, shape = { on = "boolean" } },
	SetSprint = { dir = "c2s", rate = 8, shape = { on = "boolean" } },

	-- The trigger is rate-limited twice: here against a flood, and inside
	-- Weapon against the weapon's own cadence. This one only has to stop the
	-- packet, not the shot.
	Shoot = { dir = "c2s", rate = 14, shape = { dir = "Vector3" } },
	DrawStart = { dir = "c2s", rate = 8 },
	DrawCancel = { dir = "c2s", rate = 8 },
	Reload = { dir = "c2s", rate = 4 },
	SwapWeapon = { dir = "c2s", rate = 3 },

	-- The client is the only place that can see a viewport, so the server has
	-- to ask. Rate-limited hard: this is a once-per-session question.
	PlatformCheck = { dir = "s2c" },
	PlatformReport = { dir = "c2s", rate = 1 },
})

Content.load()

--[[
	Read the balance back against the manual, once, at startup.

	`Reference` holds the proportions that hold across every action game ever
	balanced; `Content.review` measures this game's tables against them. It
	warns and never blocks, because a table that disagrees with the manual is
	sometimes the design and sometimes a typo, and only a person can tell the
	two apart. Publishing it on the debug seam is what makes the difference
	something a machine can read.
]]
do
	local notes = Content.review()
	for _, note in notes do
		Debug.warn(string.format("balance: %s %s — %s", note.kind, note.id, note.note))
	end
	Debug.probe("balance", function()
		return { notes = notes, frame = Reference.frame }
	end)
end

Save.configure({
	store = Config.saveStore,
	version = 1,
	template = {
		score = 0,
		kills = 0,
		deaths = 0,
		stamina = 100,
		best = 0,
	},
})
Save.start()

-- Systems, in the order they depend on each other. An explicit list beats
-- iterating a folder the moment one system needs another to have run first.
local Systems = script:WaitForChild("systems")
local Arena = require(Systems.Arena)
local Fight = require(Systems.Fight)
local Range = require(Systems.Range)
local Meta = require(Systems.Meta)
local Beyond = require(Systems.Beyond)

-- Config first: everything below reads values it may have overridden, and a
-- system that starts on a default and gets corrected a second later produces
-- one wave of enemies nobody asked for.
Meta.start()
Arena.start()
Fight.start()
-- After Arena: the targets need ground to stand on.
Range.start()
-- Last of the systems: everything here reaches outside this server, and
-- nothing inside it should wait on a web call.
Beyond.start()

--[[
	Hand-authored scenes, if any were pulled.

	This is the other half of `forge scene pull`. Without it the Editor round
	trip stops at the repository: an edit survives to disk and is never seen
	again, which is exactly the state this engine was in until now.

	Missing is normal and silent — most games have no pulled scenes, and a
	warning on every boot for the ordinary case is a warning people learn to
	skip.
]]
do
	local module = Shared:FindFirstChild("Scenes")
	if module and module:IsA("ModuleScript") then
		local ok, scenes = pcall(require, module)
		if ok and typeof(scenes) == "table" then
			local Scene = Forge.Scene
			local restored = 0
			for name, json in scenes do
				local built, err = pcall(function()
					return Scene.fromJson(json)
				end)
				if built then
					Scene.activate(name, Workspace:FindFirstChild("Props"))
					restored += 1
				else
					Debug.warn(string.format("scene '%s' did not load: %s", name, tostring(err)))
				end
			end
			if restored > 0 then
				Debug.info(string.format("restored %d authored scene(s)", restored))
			end
		end
	end
end

-- ============================== the player ==================================
local function onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.MaxHealth = 220
	humanoid.Health = 220
	humanoid.BreakJointsOnDeath = false
	character:SetAttribute("Armor", 30)

	-- Roblox's own Animate script writes the same joints Forge does.
	Rig.stripDefaultAnimate(character)

	--[[
		Spread the spawn, but measure the ground where they land.

		This scattered players around the centre while keeping the centre's
		height, and the arena is a bowl: every offset lands on ground that is
		higher than the middle, so the character was placed *underneath* it.
		They fell through, hit FallenPartsDestroyHeight, respawned and did it
		again — which is also why anything trying to attach to a player found
		no Character.

		`Arena.spawnPoint` stays as the fallback for the case where nothing is
		under the offset at all; a spawn slightly off is better than a spawn
		nowhere.
	]]
	local offset = Vector3.new(math.random(-6, 6), 0, math.random(-6, 6))
	local wanted = Arena.spawnPoint + offset
	local ground = World.surface(wanted.X, wanted.Z)
	if ground then
		-- Four studs of clearance under the pivot, so the feet start above the
		-- surface and settle onto it rather than starting inside it.
		wanted = ground + Vector3.new(0, 4, 0)
	end
	character:PivotTo(CFrame.new(wanted))

	-- A new body is a new weapon: Weapon keys off the character model, so the
	-- old one's ammo goes with the old one's corpse.
	Range.equip(player, character)

	humanoid.Died:Connect(function()
		local profile = Save.get(player)
		if profile then
			profile.deaths += 1
			profile.best = math.max(profile.best, profile.score)
			profile.score = 0
			Net.fire(player, "StateSync", profile)
			Net.fire(player, "Notify", { text = Forge.LiveOps.textFor(player, "notify.death") })
		end
		Debug.count("player.deaths")
		task.delay(3, function()
			if player.Parent then
				player:LoadCharacter()
			end
		end)
	end)
end

local function attachPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	if player.Character then
		onCharacter(player, player.Character)
	end
end

Players.PlayerAdded:Connect(attachPlayer)
for _, player in Players:GetPlayers() do
	attachPlayer(player)
end

-- `observe`, not `onLoaded:Connect`. In Studio the local player joins at server
-- start, so the profile may already be loaded by the time this line runs --
-- terrain generation above takes seconds. A plain Connect would miss it and no
-- character would ever spawn.
Save.observe(function(player, profile)
	Net.fire(player, "StateSync", profile)
	Net.fire(player, "Notify", { text = Forge.LiveOps.textFor(player, "notify.welcome") })
	if not player.Character then
		player:LoadCharacter()
	end
end)

Players.CharacterAutoLoads = true

-- Belt and braces: anyone still without a body gets one. Cheap, and it turns a
-- silent "nothing happened" into a game that runs.
task.defer(function()
	for _, player in Players:GetPlayers() do
		if not player.Character then
			Debug.warn(string.format("%s had no character after bootstrap; spawning", player.Name))
			player:LoadCharacter()
		end
	end
end)

--[[
	The live suite.

	Last, deliberately: these scenarios assert against systems that must
	already be running, and a suite that starts before the game does tests a
	game that does not exist yet.

	Deferred so bootstrap returns first. The report is published to a
	replicated StringValue that `forge gametest` reads, which is how a machine
	finds out whether combat still works without anybody watching a screen.
]]
if Config.selfTest then
	task.defer(function()
		local Testing = Forge.Testing
		local suite = script:FindFirstChild("tests")
		local report = Testing.runAndPublish(suite, nil, "provingground")
		Debug.info(string.format(
			"self test: %d passed, %d failed, %d hung",
			report.passed or 0, report.failed or 0, report.timedOut or 0))
	end)
end

-- ================================ the seam ==================================
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
