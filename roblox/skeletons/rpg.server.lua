--!strict
--- OPEN-WORLD RPG — a valley, people who want things, and things that want you.
---
--- Everything a small RPG needs, using the library rather than replacing it:
---
---   * sculpted terrain with a river, a road and three settlements
---   * NPCs with conversations that remember you, and quests that track
---   * enemies that see you, close the distance, swing, and drop loot
---   * a weapon, a swing, damage numbers, knockback and backstabs
---   * levels from experience, on a curve you can read before shipping it
---   * animated bodies -- nothing in this world stands perfectly still
---
--- Read it, change it, delete what you do not want. This is a starting point.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Core = require(ReplicatedStorage.Core)
local Behaviours = require(ReplicatedStorage.Behaviours)
local WorldKit = require(ReplicatedStorage.WorldKit)
local GameKit = require(ReplicatedStorage.GameKit)

local Actions, Events, Timer, Curve = Core.Actions, Core.Events, Core.Timer, Core.Curve
local Spatial, Signal = Core.Spatial, Core.Signal
local Story, Combat, Life = Behaviours.Story, Behaviours.Combat, Behaviours.Life
local World, Play = Behaviours.World, Behaviours.Play

-- ================================================================= the design

--- **The three numbers that are the game.** Enemy health against weapon damage
--- sets how long a fight lasts; experience against the level curve sets how
--- often something changes.
local SWORD = {
	name = "Iron Sword", damage = 22, reach = 9, width = 7,
	cooldown = 0.6, knockback = 18, backstab = 1.8,
}
local ENEMY_HEALTH = 70
local ENEMY_XP = 35

local VALLEY = 420          -- studs across
local SETTLEMENTS = 3

-- ================================================================= the world

local WORLD = workspace:FindFirstChild("Valley")
if WORLD then WORLD:Destroy() end
WORLD = Instance.new("Folder")
WORLD.Name = "Valley"
WORLD.Parent = workspace

local tokens = WorldKit.Tokens.define(require(ReplicatedStorage.Shared.TokenData))

--- Terrain first, and flattened where anything is built. A settlement on a
--- hillside is a settlement half underground.
local PLOTS = {}
for index = 1, SETTLEMENTS do
	local angle = (index / SETTLEMENTS) * math.pi * 2
	table.insert(PLOTS, {
		centre = Vector3.new(math.cos(angle) * 130, 0, math.sin(angle) * 130),
		size = Vector2.new(90, 90),
	})
end

local relief = WorldKit.Land.heightfield({
	centre = Vector3.new(0, 0, 0),
	size = Vector2.new(VALLEY, VALLEY),
	baseHeight = 0,
	amplitude = 46,
	wavelength = 120,
	octaves = 4,
	seed = 2029,
	material = Enum.Material.Grass,
	waterLevel = -14,
	flatten = PLOTS,
})

-- **The rock band comes from the measured relief, not from a guess.** Picking a
-- height by eye put it above the highest ground once and across the whole
-- surface once: the first attempt painted everything brown, the second painted
-- nothing at all.
local low = relief.detail and relief.detail.lowest or -20
local high = relief.detail and relief.detail.highest or 20
local ridge = low + (high - low) * 0.62
WorldKit.Land.paint({
	centre = Vector3.new(0, ridge + (high - ridge) * 0.5, 0),
	size = Vector3.new(VALLEY, math.max((high - ridge) * 2, 8), VALLEY),
}, Enum.Material.Grass, Enum.Material.Rock)

WorldKit.Land.tint(Enum.Material.Grass, Color3.fromRGB(96, 118, 78))

--- The look. Post-processing is most of what "finished" means, and none of it
--- needs an upload.
local Lighting = game:GetService("Lighting")
Lighting.ClockTime = 16.5
-- Mood names come from the token set, not from taste: this one declares
-- `vigil-*` and asking for anything else takes the whole script down.
WorldKit.Mood.apply(tokens, "vigil-golden")

-- ================================================================= settlements

local function settlement(name: string, at: Vector3, index: number)
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = WORLD

	-- A plaza, so the ground under the buildings is built rather than terrain.
	local plaza = Instance.new("Part")
	plaza.Name = "Plaza"
	plaza.Size = Vector3.new(70, 2, 70)
	plaza.Position = at + Vector3.new(0, 1, 0)
	plaza.Anchored = true
	plaza.Material = Enum.Material.Cobblestone
	plaza.Color = Color3.fromRGB(128, 124, 116)
	plaza.Parent = folder

	-- Walls with real openings, cut rather than painted. A doorway drawn as a
	-- dark rectangle is the clearest tell that a place is a greybox.
	for wall = 1, 4 do
		local angle = (wall / 4) * math.pi * 2
		local offset = Vector3.new(math.cos(angle) * 30, 8, math.sin(angle) * 30)
		local panel = Instance.new("Part")
		panel.Name = ("Wall%d"):format(wall)
		panel.Size = Vector3.new(28, 14, 2)
		panel.CFrame = CFrame.lookAt(at + offset, at + Vector3.new(0, 8, 0))
		panel.Anchored = true
		panel.Material = Enum.Material.Slate
		panel.Color = Color3.fromRGB(150, 142, 128)
		panel.Parent = folder

		if wall == 1 then
			local cut, _ = WorldKit.Fab.aperture(panel, {
				{ offset = Vector2.new(0, -3), size = Vector2.new(7, 9) },
			}, {})
			if cut ~= nil then
				cut.Name = "Gatehouse"
			end
		end
	end

	-- A landmark, so the settlement is visible from across the valley.
	local tower = Instance.new("Part")
	tower.Name = "Tower"
	tower.Size = Vector3.new(10, 34, 10)
	tower.Position = at + Vector3.new(0, 19, 0)
	tower.Anchored = true
	tower.Material = Enum.Material.Slate
	tower.Color = Color3.fromRGB(120, 116, 108)
	tower.Parent = folder

	local beacon = Instance.new("PointLight")
	beacon.Range = 60
	beacon.Brightness = 2
	beacon.Color = Color3.fromRGB(255, 200, 140)
	beacon.Parent = tower

	WorldKit.Interact.sign(tower, {
		text = name, size = 2.2, face = Enum.NormalId.Front,
		background = Color3.fromRGB(38, 34, 30),
	})

	-- A door that opens, because a settlement you cannot enter is a backdrop.
	local leaf = Instance.new("Part")
	leaf.Name = "Door"
	leaf.Size = Vector3.new(6, 10, 1)
	leaf.Position = at + Vector3.new(0, 6, -30)
	leaf.Anchored = true
	leaf.Material = Enum.Material.Wood
	leaf.Color = Color3.fromRGB(96, 72, 48)
	leaf.Parent = folder
	World.door(leaf, { by = "prompt", style = "swing", autoClose = 6, label = name })

	-- Planted around, kept off the plaza.
	pcall(function()
		WorldKit.Nature.scatter(folder, WorldKit.Palette.BrickFarm, {
			centre = at, size = Vector2.new(150, 150), count = 26, seed = 11 * index,
			minSpacing = 14,
			exclusions = { { centre = at, size = Vector2.new(80, 80) } },
		}, 0.75)
	end)

	return folder
end

local TOWNS = {
	settlement("Ashford", PLOTS[1].centre, 1),
	settlement("Millbrook", PLOTS[2].centre, 2),
	settlement("Thornrest", PLOTS[3].centre, 3),
}

-- ================================================================= the story

local bounty = Story.quest("bounty", {
	{ id = "slain", text = "Drive back the wolves", count = 5 },
}, {
	title = "The Wolves of Ashford",
	startMessage = "Elder Maren asks you to thin the wolves.",
	doneMessage = "The wolves are thinned. Maren will want to hear.",
	reward = function(player)
		Actions.add(player, "Gold", 250)
		Actions.add(player, "Experience", 120)
	end,
})

local errand = Story.quest("errand", {
	{ id = "visited", text = "Reach Thornrest", count = 1 },
}, {
	title = "Word to Thornrest",
	reward = function(player)
		Actions.add(player, "Gold", 90)
		Actions.add(player, "Experience", 60)
	end,
})

--- A body for somebody to talk through. `Threat.build` makes a figure, not a
--- marker -- it is what the engine has, and an NPC that is a coloured box is
--- the difference between a world and a diagram.
local function personAt(name: string, at: Vector3, colour: string): Model
	local folk = WORLD:FindFirstChild("Folk") or Instance.new("Folder")
	folk.Name = "Folk"
	folk.Parent = WORLD

	local model = WorldKit.Threat.build(folk, tokens, {
		id = name,
		displayName = name,
		cframe = CFrame.new(Spatial.settle(at, { lift = 4 })),
		maxHealth = 100, health = 100,
		scale = 1.0,
		seed = #name * 17,
		bodyRole = colour,
		mantleRole = "stonePrimary",
		faceRole = "neutralLight",
		accentRole = "accentGold",
		showHealth = false,
	})
	return model
end

local maren = Story.npc(
	personAt("Elder Maren", PLOTS[1].centre + Vector3.new(14, 0, 14), "slate"),
	{
		start = {
			says = "You have the look of someone who can hold a blade. "
				.. "Wolves have come down from the ridge.",
			replies = {
				{ text = "I will deal with them.", goto_ = "given",
				  does = function(player) bounty.give(player) end },
				{ text = "Not today." },
			},
		},
		given = {
			says = "Five should be enough to make the rest think twice. "
				.. "Come back when it is done.",
			replies = {
				{ text = "Understood." },
				{ text = "What is west of here?", goto_ = "west" },
			},
		},
		west = {
			says = "Thornrest. They have not sent word in a fortnight.",
			replies = {
				{ text = "I will go and see.", goto_ = "errand",
				  does = function(player) errand.give(player) end },
				{ text = "Later." },
			},
		},
		errand = { says = "Take the road. The ridge is not safe after dark." },
	},
	{ name = "Elder Maren", action = "Speak" })

local smith = Story.npc(
	personAt("Bran the Smith", PLOTS[2].centre + Vector3.new(-12, 0, 10), "ink"),
	{
		start = {
			says = "Iron is dear this season. But you look like you need it more than I do.",
			replies = {
				{ text = "What have you got?", goto_ = "wares" },
				{ text = "Nothing today." },
			},
		},
		wares = {
			says = "A sword, if you have two hundred gold.",
			replies = {
				{
					text = "I will take it. (200 gold)",
					when = function(player)
						return (Actions.get(player, "Gold", 0) :: number) >= 200
					end,
					does = function(player)
						if Actions.spend(player, "Gold", 200) then
							Actions.set(player, "Weapon", "Iron Sword")
							Actions.notify(player, "You take the iron sword.")
						end
					end,
					goto_ = "sold",
				},
				{ text = "Too rich for me." },
			},
		},
		sold = { says = "Mind the edge. It is sharper than you are." },
	},
	{ name = "Bran the Smith", action = "Trade" })

local warden = Story.npc(
	personAt("Warden Sela", PLOTS[3].centre + Vector3.new(0, 0, -16), "stonePrimary"),
	{
		start = {
			says = "Ashford sent you? Then the road is still open. That is something.",
			onEnter = function(player)
				errand.progress(player, "visited")
			end,
			replies = { { text = "I will tell them." } },
		},
	},
	{ name = "Warden Sela", action = "Speak" })

-- ================================================================= the enemies

local WOLVES = Instance.new("Folder")
WOLVES.Name = "Wolves"
WOLVES.Parent = WORLD

local slain = Signal.new("wolf.slain")

local function spawnWolf(wave: number): Instance?
	local angle = math.random() * math.pi * 2
	local radius = 150 + math.random() * 60
	local at = Spatial.settle(
		Vector3.new(math.cos(angle) * radius, 40, math.sin(angle) * radius),
		{ lift = 4 })

	local ok, model = pcall(function()
		return WorldKit.Threat.build(WOLVES, tokens, {
			id = ("Wolf%d"):format(math.random(1, 999999)),
			displayName = "Ridge Wolf",
			cframe = CFrame.new(at),
			maxHealth = ENEMY_HEALTH, health = ENEMY_HEALTH,
			scale = 0.9,
			seed = math.random(1, 9999),
			bodyRole = "ink", mantleRole = "slate",
			faceRole = "accentDanger", accentRole = "accentDanger",
			showHealth = true,
		})
	end)
	if not ok or model == nil then
		return nil
	end

	local enemy = Combat.enemy(model, {
		health = ENEMY_HEALTH,
		sight = 80,
		speed = 13,
		reach = 9,
		gait = "walk",
		experience = ENEMY_XP,
		weapon = { name = "Fangs", damage = 12, reach = 8, cooldown = 1.1, knockback = 14 },
		drops = function(where)
			-- Something to walk to. A kill that leaves nothing behind gives the
			-- player no reason to move.
			local coin = Instance.new("Part")
			coin.Name = "Gold"
			coin.Size = Vector3.new(2, 2, 2)
			coin.Position = where + Vector3.new(0, 3, 0)
			coin.Anchored = true
			coin.CanCollide = false
			coin.Material = Enum.Material.Neon
			coin.Color = Color3.fromRGB(235, 190, 90)
			coin.Parent = WOLVES
			Play.pickup(coin, { currency = "Gold", amount = 40, spin = true })
		end,
	})

	enemy.health.died:connect(function()
		slain:fire()
		for _, player in ipairs(Players:GetPlayers()) do
			bounty.progress(player, "slain")
		end
	end)

	return model
end

local pack = Life.spawner(spawnWolf, {
	first = 3, growth = 1.15, gap = 3.5, between = 25, cap = 12,
})

-- ================================================================= the player

local progression = Combat.progression({ base = 120, ratio = 1.35 })

Events.onPlayer(function(player)
	Actions.set(player, "Gold", 60)
	Actions.set(player, "Level", 1)
	Actions.set(player, "Experience", 0)
	Actions.set(player, "Weapon", "Fists")
end)

--- Every player can swing. The weapon they hold changes what the swing does.
local swings: { [Player]: any } = {}

Events.onCharacter(function(character, player, humanoid)
	humanoid.WalkSpeed = 20
	humanoid.MaxHealth = 150
	humanoid.Health = 150

	local named = Actions.get(player, "Weapon", "Fists")
	local kit = if named == "Iron Sword" then SWORD else nil

	swings[player] = Combat.attacker(character, kit, {
		-- Players hit wolves, never each other and never the townsfolk.
		hostileTo = function(target: Instance): boolean
			return target:IsDescendantOf(WOLVES)
		end,
	})

	task.defer(function()
		Actions.teleport(character, Spatial.settle(
			PLOTS[1].centre + Vector3.new(0, 30, 24), { lift = 4 }))
	end)
end)

Events.onPlayerLeft(function(player)
	local swing = swings[player]
	if swing ~= nil then
		swing.destroy()
		swings[player] = nil
	end
end)

--- Attacking is a server decision driven by a client signal. The remote carries
--- intent, never damage -- a client that reports its own damage is a client
--- that reports whatever it likes.
local strike = ReplicatedStorage:FindFirstChild("Strike") or Instance.new("RemoteEvent")
strike.Name = "Strike"
strike.Parent = ReplicatedStorage

strike.OnServerEvent:Connect(function(player)
	local swing = swings[player]
	if swing ~= nil then
		swing.attack()
	end
end)

-- ================================================================= the loop

pack.waveStarted:connect(function(wave, count)
	for _, player in ipairs(Players:GetPlayers()) do
		Actions.notify(player, ("%d wolves come down from the ridge"):format(count))
	end
end)

bounty.completed:connect(function(player)
	Actions.notify(player, "Return to Elder Maren.")
end)

progression.levelled:connect(function(player, level)
	local character = player.Character
	if character ~= nil then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil then
			humanoid.MaxHealth += 25
			humanoid.Health = humanoid.MaxHealth
		end
	end
end)

Timer.after(4, pack.start)

print(("[rpg] valley of %d studs, %d settlements, %d NPCs, wolves inbound")
	:format(VALLEY, #TOWNS, 3))
