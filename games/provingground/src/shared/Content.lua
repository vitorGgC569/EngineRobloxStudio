--!strict
--[[
	Content — every number this game balances on.

	Schemas first, so a typo is an error at load instead of a nil three systems
	later. Then the tables. No system below `src/server/systems/` contains a
	balance number; they all read from here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Data = Forge.Data
local Weapon = Forge.Weapon

local Content = {}

--[[
	Ranged weapons go straight into the engine's registry.

	`Weapon.define` already validates and defaults every field a ranged weapon
	has, so wrapping it in a second `Data.define` schema would mean two places
	to change one number and one of them would eventually be wrong.

	Two weapons, deliberately opposite, because a weapon is only interesting
	next to a different one:

	  longbow      slow, charged, arcs, hurts. Rewards holding the draw and
	               leading the target. One arrow at a time.
	  handcannon   instant, six shots, spread that opens the faster you fire.
	               Rewards standing still and short bursts.
]]
Content.ranged = { "longbow", "handcannon" }

local function loadRanged()
	Weapon.define("longbow", {
		label = "Longbow",
		mode = "projectile",
		damage = 44, rpm = 70, range = 700,
		magazine = 1, reserve = math.huge, reloadTime = 0.5,
		-- Charged weapons draw their tension from the wait, so the cone stays
		-- tight: a bow that also sprays would just be unfair.
		spread = { min = 0.15, max = 1.2, perShot = 0.5, recover = 6 },
		recoil = { pitch = 0.9, yaw = 0.2, recover = 7 },
		falloff = { start = 200, stop = 620, floor = 0.6 },
		charge = { time = 0.85, minRatio = 0.3 },
		projectile = {
			speed = 210, gravity = 46, life = 5,
			visual = { color = Color3.fromRGB(255, 226, 168), size = Vector3.new(0.16, 0.16, 3.2), trail = true },
		},
		clip = "bow_loose",
		aimClip = "bow_draw",
		reloadClip = "interact",
		-- Left hand: the right one draws the string, which is what the
		-- bow_draw clip animates.
		hand = "left",
		model = "longbow",
		--[[
			How the bow sits in the hand.

			Welded with no rotation, a weapon inherits the arm's axis and swings
			around with the shoulder: upright while the arm hangs, flat on its
			side the moment the arm comes up. A bow has to stay vertical in the
			pose that matters.

			A quarter turn about the hand's X puts the limbs along the hand's Z,
			which reads as vertical once the arm is extended. Negative rather
			than positive so the string ends up on the archer's side instead of
			the target's.
		]]
		gripOffset = CFrame.new(0, -0.1, -0.15) * CFrame.Angles(math.rad(-90), 0, 0),
	})

	Weapon.define("handcannon", {
		label = "Hand Cannon",
		mode = "hitscan",
		damage = 17, rpm = 260, range = 520,
		magazine = 6, reserve = math.huge, reloadTime = 1.5,
		spread = { min = 0.5, max = 7, perShot = 1.4, recover = 4.5 },
		recoil = { pitch = 2.2, yaw = 0.7, recover = 8 },
		falloff = { start = 90, stop = 380, floor = 0.35 },
		clip = "shoot",
		aimClip = "aim",
		reloadClip = "reload",
		color = Color3.fromRGB(255, 214, 150),
		hand = "right",
		model = "handcannon",
		-- Same reasoning: the barrel runs down the hand's -Y, which points
		-- where the character is facing once the arm comes up to aim.
		gripOffset = CFrame.new(0, -0.1, -0.1) * CFrame.Angles(math.rad(-90), 0, 0),
	})
end

function Content.load()
	Data.define("weapon", {
		name = { type = "string" },
		damage = { type = "number", min = 1 },
		range = { type = "number", default = 9 },
		arc = { type = "number", default = 110 },
		cooldown = { type = "number", default = 0.55 },
		knockback = { type = "number", default = 26 },
		crit = { type = "number", default = 0.08, min = 0, max = 1 },
		color = { type = "Color3" },
		kind = { type = "string", oneOf = { "sword", "axe", "greatsword", "staff", "dagger" } },
	})

	Data.define("enemy", {
		name = { type = "string" },
		health = { type = "number", min = 1 },
		damage = { type = "number", min = 0 },
		armor = { type = "number", default = 0 },
		speed = { type = "number", default = 14 },
		reach = { type = "number", default = 7 },
		aggro = { type = "number", default = 42 },
		attackEvery = { type = "number", default = 1.6 },
		score = { type = "number", default = 10 },
		rig = { type = "table" },
		profile = { type = "string", default = "grounded", oneOf = { "grounded", "heavy", "skittering" } },
	})

	Data.load("weapon", {
		training_blade = {
			name = "Training Blade",
			damage = 18, range = 9.5, arc = 110, cooldown = 0.52,
			knockback = 26, crit = 0.08, kind = "sword",
			color = Color3.fromRGB(196, 202, 214),
		},
	})

	Data.load("enemy", {
		-- `extends` keeps a family of variants from becoming copy-paste
		husk = {
			name = "Husk",
			health = 90, damage = 9, armor = 2, speed = 13,
			reach = 7, aggro = 44, attackEvery = 1.7, score = 10,
			profile = "grounded",
			rig = {
				scale = 0.95, shape = "biped",
				body = Color3.fromRGB(96, 88, 82),
				accent = Color3.fromRGB(64, 58, 54),
				eyes = Color3.fromRGB(220, 80, 60),
				-- Armed, and visibly so. An enemy whose reach is 7 studs but
				-- whose hands are empty reads as a bug the first time it hits
				-- you from a distance.
				weapon = "dagger",
			},
		},
		husk_brute = {
			extends = "husk",
			name = "Brute Husk",
			health = 260, damage = 22, armor = 12, speed = 10,
			reach = 10, attackEvery = 2.4, score = 35,
			profile = "heavy",
			rig = {
				-- The brute gets the fifteen-joint skeleton.
				--
				-- Elbows and knees only exist on R15, and a boss is where they
				-- pay: a two-handed overhead needs an elbow to fold, and a
				-- shoulder alone can only point the arm at the ground. The
				-- smaller enemies stay R6 on purpose — nine joints each,
				-- fourteen of them on screen at once, for motion nobody reads
				-- at that distance.
				rigType = "R15",
				scale = 1.5, shape = "hulk", bulky = true,
				body = Color3.fromRGB(112, 100, 92),
				accent = Color3.fromRGB(198, 120, 60),
				eyes = Color3.fromRGB(255, 140, 60),
				glow = true,
				spikes = true,
				weapon = "greatsword",
			},
		},
		stalker = {
			extends = "husk",
			name = "Stalker",
			health = 70, damage = 13, armor = 0, speed = 20,
			reach = 6.5, aggro = 56, attackEvery = 1.1, score = 20,
			profile = "skittering",
			rig = {
				scale = 0.8, shape = "quadruped",
				body = Color3.fromRGB(70, 84, 74),
				accent = Color3.fromRGB(150, 220, 130),
				eyes = Color3.fromRGB(160, 255, 120),
			},
		},
	})

	loadRanged()
end

return Content
