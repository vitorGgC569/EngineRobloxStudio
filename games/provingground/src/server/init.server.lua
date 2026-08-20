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
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Content = require(Shared:WaitForChild("Content"))

local Rng = Forge.Core.Rng
local Net = Forge.Net
local Save = Forge.Save
local Rig = Forge.Rig
local Debug = Forge.Debug

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
})

Content.load()

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

Arena.start()
Fight.start()
-- After Arena: the targets need ground to stand on.
Range.start()

-- ============================== the player ==================================
local function onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.MaxHealth = 220
	humanoid.Health = 220
	humanoid.BreakJointsOnDeath = false
	character:SetAttribute("Armor", 30)

	-- Roblox's own Animate script writes the same joints Forge does.
	Rig.stripDefaultAnimate(character)

	character:PivotTo(CFrame.new(Arena.spawnPoint + Vector3.new(math.random(-6, 6), 0, math.random(-6, 6))))

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
			Net.fire(player, "Notify", { text = "You fell. Score reset." })
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
	Net.fire(player, "Notify", { text = "Proving Ground. LMB strikes, Q dodges, RMB blocks, F shoots." })
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
