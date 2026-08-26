--!strict
-- Every tunable number in the game lives here. No other module hardcodes balance values.

export type ZombieClass = {
	name: string,
	hordeThreshold: number, -- fraction of lobby infected before this class unlocks
	maxHealth: number,
	walkSpeedMult: number,
	attacksToKill: number,
	ability: string?, -- "scream" etc.
	abilityCooldown: number?,
}

local GameConfig = {
	Round = {
		MinPlayersToStart = 4,
		FullRewardPlayerCount = 10, -- below this, rewards scale down linearly
		IntermissionSeconds = 25,
		BaseRoundSeconds = 5 * 60,
		SecondsPerConversion = 20,
		MaxRoundSeconds = 8 * 60,
		RevealSeconds = 10,
		ZombieRespawnSeconds = 3,
		SpawnProtectionSeconds = 3,
		LastSurvivorsPingCount = 3, -- last N survivors get pinged
		PingIntervalSeconds = 15,
		PatientZeroRecentRounds = 3, -- rounds a player is deprioritized after being PZ
	},

	-- Round modifiers add replay variety: one is rolled (weighted) at round start and
	-- broadcast for a banner. Effects use clean global levers so no per-entity wiring is
	-- needed — coinMult (reward multiplier), gravity (workspace.Gravity), blackout (client
	-- lighting). "Normal" carries the bulk of the weight so most rounds are vanilla.
	-- Server-driven: add a modifier here and it appears in rotation with no other change.
	DefaultGravity = 196.2,
	RoundModifiers = {
		{ id = "normal", name = "Standard", desc = "A normal outbreak.", weight = 10 },
		{
			id = "double_coins",
			name = "Double Coins",
			desc = "All coin rewards are doubled this round.",
			weight = 3,
			coinMult = 2,
		},
		{
			id = "blackout",
			name = "Blackout",
			desc = "The power is out. Survive in the dark.",
			weight = 3,
			blackout = true,
		},
		{
			id = "low_gravity",
			name = "Low Gravity",
			desc = "Gravity is weak — bunny-hop for your life.",
			weight = 2,
			gravity = 70,
		},
		{
			id = "moon_boots",
			name = "Moon Boots",
			desc = "Everyone jumps sky-high.",
			weight = 2,
			gravity = 110,
			coinMult = 1.5,
		},
	},

	Combat = {
		SurvivorMaxHealth = 100,
		PatientZero = {
			SprintMult = 1.2,
			ThrowKnifeOneHit = true,
			MeleeOneHit = true,
			ThrowCooldown = 2.0,
			MeleeCooldown = 0.8,
			ThrowSpeed = 120, -- studs/s initial projectile velocity
			ThrowGravity = 40, -- studs/s^2 applied to knife arc
			MaxThrowRange = 150,
		},
		Zombie = {
			MeleeDamage = 50, -- 2 hits to convert
			MeleeCooldown = 1.0,
			MeleeRange = 7,
		},
		LastStand = {
			DamageResistMult = 0.5, -- takes 50% damage
			WeaponId = "Minigun",
		},
		Guns = {
			-- id = {damagePerShot, fireRateRps, magSize, reloadSeconds, hitscanRange, pellets?}
			AssaultRifle = { Damage = 34, FireRate = 8, Mag = 30, Reload = 2.2, Range = 300 },
			Shotgun = { Damage = 12, FireRate = 1.4, Mag = 6, Reload = 2.8, Range = 60, Pellets = 8 },
			SMG = { Damage = 22, FireRate = 12, Mag = 35, Reload = 1.9, Range = 180 },
			Pistol = { Damage = 30, FireRate = 5, Mag = 12, Reload = 1.5, Range = 200 },
			Minigun = { Damage = 18, FireRate = 25, Mag = 250, Reload = 5.0, Range = 250 },
		},
		ZombieBaseHealth = 120, -- ~2-4 shots depending on gun
	},

	ZombieClasses = {
		{ name = "Walker", hordeThreshold = 0, maxHealth = 120, walkSpeedMult = 1.0, attacksToKill = 2 },
		{ name = "Runner", hordeThreshold = 0.25, maxHealth = 70, walkSpeedMult = 1.35, attacksToKill = 2 },
		{ name = "Tank", hordeThreshold = 0.5, maxHealth = 300, walkSpeedMult = 0.8, attacksToKill = 2 },
		{
			name = "Screamer",
			hordeThreshold = 0.75,
			maxHealth = 100,
			walkSpeedMult = 1.1,
			attacksToKill = 2,
			ability = "scream", -- pulses survivor positions
			abilityCooldown = 30,
		},
		{
			name = "Pouncer",
			hordeThreshold = 0.4,
			maxHealth = 90,
			walkSpeedMult = 1.15,
			attacksToKill = 2,
			ability = "lunge", -- player-activated speed burst to run down fleeing survivors
			abilityCooldown = 8,
		},
		{
			name = "Stalker",
			hordeThreshold = 0.6,
			maxHealth = 80,
			walkSpeedMult = 1.2,
			attacksToKill = 2,
			ability = "cloak", -- brief semi-invisibility to sneak up on survivors
			abilityCooldown = 12,
		},
	} :: { ZombieClass },

	-- Lunge tunables. LungeSpeed is an ABSOLUTE walkspeed for the burst; kept under
	-- Movement.MaxToleratedSpeed so activating it never trips the anti-cheat.
	Lunge = {
		Speed = 40,
		Duration = 0.6,
	},
	-- Cloak: fade the Stalker (and hide its infection aura) for a short window. Not full
	-- invisibility (survivors can still faintly see them) so it stays fair.
	Cloak = {
		Duration = 3,
		Transparency = 0.75,
	},

	Rewards = {
		-- Coins; XP mirrors coins 1:1
		ZombieKill = 8, -- survivor kills a zombie
		Conversion = 25, -- infected converts a survivor
		FirstBlood = 40,
		SurvivedRound = 75,
		LastSurvivor = 100,
		WinMultiplier = 2,
	},

	-- Bots fill the lobby so a solo (or under-filled) server still plays a full round.
	Bots = {
		Enabled = true,
		TargetPlayers = 8, -- fill humans + bots up to this headcount
		MaxBots = 11, -- never spawn more than this
		ThinkInterval = 0.35, -- AI tick period (seconds)

		-- Navigation (PathfindingService). Paths are recomputed when the target moves
		-- past RepathDistance or on a timer, not every tick — computing a path is costly.
		AgentRadius = 2,
		AgentHeight = 5,
		RepathInterval = 0.8, -- min seconds between path recomputes for a chasing bot
		RepathDistance = 8, -- recompute if the goal moved this many studs
		WaypointReached = 4, -- distance at which a waypoint counts as reached
		StuckSpeed = 2, -- studs/sec below which a bot is "stuck"
		StuckRepathAfter = 1.2, -- seconds stuck before forcing a repath/jump

		-- Survivor behaviour
		FleeRadius = 26, -- start fleeing when a visible infected is this close
		SightRange = 80, -- how far bots can "see" (line-of-sight raycast)
		GroupRadius = 40, -- survivors drift toward other survivors within this range

		-- Survivor bots shooting back at VISIBLE zombies (never the hidden PZ — that would
		-- leak the mind-game). Human-like: only when they have line of sight, with a delay.
		ShootRange = 60,
		ShootInterval = 0.55, -- median seconds between a survivor bot's shots
		ShootIntervalJitter = 0.35, -- +/- randomisation so bots don't fire like a metronome
		ShootReactionMin = 0.25, -- random aim delay before the first shot
		ShootReactionMax = 0.7,
		ShootSpreadDeg = 3.4, -- bots roll a real cone and raycast; misses are visible
		BotWeapon = "AssaultRifle", -- which Ballistics profile a survivor bot fires

		-- Perception. Bots used to see 360 degrees with no memory of a lost target.
		VisionConeDeg = 110,
		PeripheralRange = 10, -- inside this you're noticed regardless of facing
		MemorySeconds = 6, -- how long a lost target stays worth searching for
		-- Infected sense living flesh within this radius even without line of sight. This is
		-- deliberately NOT a wallhack: they get a position to move toward, not a lock, and
		-- it is short enough that you can break away round a corner. Removing the old
		-- unconditional wallhack without adding this made zombies wander at random and
		-- never convert anyone, so rounds never ended.
		InfectedSenseRadius = 80,
		HearingRange = 90, -- gunfire within this radius draws bots to the SOUND (never
		-- to the shooter's identity — that would leak the hidden PZ)
		SearchRadiusBase = 10,
		SearchRadiusGrowth = 4,

		-- Zombie bots telegraph before converting instead of touching you to death. Kept
		-- short: the think interval is 0.35s, so a long wind-up costs several ticks.
		MeleeWindup = 0.3,
		-- Reach at the moment the swing lands. Slightly beyond MeleeRange because the bot is
		-- lunging into it, and because both parties move between the tick that started the
		-- wind-up and the tick that resolves it.
		MeleeLungeReach = 1.6,
		-- Chase speed multiplier while committed to a kill. This has to beat a sprinting
		-- survivor (SprintWalkSpeed) or the horde can never catch anyone and the round never
		-- ends - which is exactly what the combat simulation caught.
		HuntSpeedMult = 1.55,

		-- Idle emotes. Bots that occasionally stop to wave or dance read as people rather
		-- than as pathfinding demos, and it costs nothing — the animations are first-party.
		EmoteChance = 0.05, -- per think tick, while patrolling with nothing to do
		EmoteCooldown = 14, -- seconds between a bot's emotes
		EmoteMaxHold = 2.2, -- max seconds a bot stands still for one; longer is a free kill

		-- Difficulty tiers rolled per-bot at spawn. These now scale aim, rate of fire and
		-- perception too — previously only chase speed and one delay differed, so a Rookie
		-- and a Veteran shot identically.
		Difficulties = {
			{
				name = "Rookie",
				weight = 3,
				speedMult = 0.92,
				reactionMult = 1.5,
				spreadMult = 1.8,
				fireRateMult = 1.45,
				sightMult = 0.8,
			},
			{
				name = "Regular",
				weight = 4,
				speedMult = 1.0,
				reactionMult = 1.0,
				spreadMult = 1.0,
				fireRateMult = 1.0,
				sightMult = 1.0,
			},
			{
				name = "Veteran",
				weight = 2,
				speedMult = 1.06,
				reactionMult = 0.7,
				spreadMult = 0.55,
				fireRateMult = 0.75,
				sightMult = 1.2,
			},
		},
		-- Personalities bias survivor behaviour (roam vs group vs hide).
		Personalities = { "roamer", "grouper", "cautious", "aggressive" },
	},

	Movement = {
		BaseWalkSpeed = 16,
		SprintWalkSpeed = 24,
		-- AntiCheat: max studs/s tolerated before flagging (sprint * PZ mult + slack).
		-- Extra headroom for latency / physics spikes; false kicks were worse than soft cheats.
		MaxToleratedSpeed = 24 * 1.2 * 1.35 + 12, -- fastest legit (Runner sprint) + slack
		TeleportFlagStuds = 100, -- moved more than this in one check window = flag
		CheckIntervalSeconds = 1,
	},

	Economy = {
		CrateCostCoins = 750,
		CrateCostRobuxProductKey = "CrateKey1",
		-- color stored as {r, g, b} 0-255 so this module stays pure (unit-testable outside Roblox)
		Rarities = {
			{ name = "Common", weight = 55, color = { 178, 178, 178 } },
			{ name = "Uncommon", weight = 25, color = { 88, 200, 88 } },
			{ name = "Rare", weight = 12, color = { 70, 130, 240 } },
			{ name = "Epic", weight = 5.5, color = { 170, 80, 230 } },
			{ name = "Legendary", weight = 2, color = { 240, 170, 40 } },
			{ name = "Chroma", weight = 0.5, color = { 255, 90, 160 } },
		},
	},

	-- Roblox audio asset ids; 0 disables a sound. Filled/verified in the Studio pass
	-- (audio must be owned/licensed to play for all users, so IDs are set there).
	-- All Roblox-owned (creator id 1) classic audio — playable in any experience.
	Sounds = {
		GunShot = 12222132, -- "Shoulder fired rocket" (short punchy crack)
		KnifeThrow = 12222200, -- "swoosh"
		Conversion = 9120031442, -- thunder/roar sting
		RoundStart = 12222019, -- "HalloweenLightning"
		SurvivorsWin = 12222253, -- "victory"
		InfectedWin = 12222030, -- "HalloweenThunder"
		Heartbeat = 0, -- no Roblox-owned loop found; disabled until a licensed one is picked
		LobbyMusic = 15675069601, -- "Roblox_UI_Loop_Calm_Music" (95s loop)
		-- In-round music director stems. 0 = disabled (silent) until a licensed loop is
		-- dropped in; the tension system (Sounds.luau) already ramps volume/pitch by the
		-- infected fraction, so adding an id here lights it up with no code change.
		RoundMusic = 0, -- base in-round bed; intensifies as survivors fall
		LastStandMusic = 0, -- swaps in when one survivor remains
	},

	-- Created on Creator Hub 2026-07-17 (universe 10518289514). All start off-sale;
	-- prices go live only after Hari approves them.
	Products = {
		GamePasses = {
			DoubleCoins = 1919414556,
			XPBoost = 1917980542,
			VIP = 1918454539,
			Radio = 1918040566,
		},
		DevProducts = {
			Coins1000 = 3610363831,
			Coins5000 = 3610363881,
			Coins12000 = 3610363919,
			CrateKey1 = 3610364225,
			CrateKey5 = 3610364383,
			PatientZeroToken = 3610364441,
		},
	},
}

return GameConfig
