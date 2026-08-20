--!strict
--[[
	Anim.Presets — a starter set of clips.

	Read this carefully, because it is the one file in Forge that comes closest
	to breaking the rule: these are EXAMPLES, not the engine. They exist so a
	new project has something moving in the first minute, and so there is a
	worked reference for how tracks and markers fit together.

	Copy them into your game and edit them. Do not build a game on top of the
	defaults and then wonder why it feels like every other game built on the
	defaults — that is exactly the failure mode Forge exists to avoid.

		local Anim = Forge.Anim
		Anim.registerAll(require(Anim.Presets))   -- then override what you want

	Marker vocabulary used here (yours can differ, but be consistent):
	  hit          the frame damage should be dealt
	  trail_on/off weapon trail window
	  telegraph    the moment the player must be able to read the attack
	  iframes_on/off invulnerability window
	  release      a projectile or effect leaves the caster
	  fall         the body should go ragdoll / settle
	  draw_full    a charged weapon has reached full power
	  mag_out/in   the reload's two halves
	  eject        a casing leaves the weapon
	  grab         the object should change hands
	  lifted       it is clear of the ground
]]

local Anim = require(script.Parent)
local k = Anim.k
local UPPER, ALL = Anim.UPPER, Anim.JOINTS

return {
	-- three-hit melee chain: overhead, return cut, spinning thrust
	attack_1 = {
		duration = 0.52, mask = UPPER, priority = 2,
		tracks = {
			rightArm = { k(0, -20, 10), k(0.18, -150, 24), k(0.30, 62, -6), k(0.52, -10, 4) },
			leftArm = { k(0, -8, -14), k(0.18, -34, -30), k(0.30, 20, -10), k(0.52, -6, -8) },
			torso = { k(0, 0, 0, 0), k(0.18, -6, 0, -22), k(0.30, 9, 0, 26), k(0.52, 0, 0, 0) },
			head = { k(0, 0, 0, 0), k(0.30, 6, 0, 12), k(0.52, 0, 0, 0) },
		},
		markers = { { t = 0.16, name = "trail_on" }, { t = 0.26, name = "hit" }, { t = 0.40, name = "trail_off" } },
	},
	attack_2 = {
		duration = 0.50, mask = UPPER, priority = 2,
		tracks = {
			rightArm = { k(0, 40, -20), k(0.16, 96, -64), k(0.30, -46, 30), k(0.50, -10, 4) },
			leftArm = { k(0, 10, -8), k(0.16, 40, -20), k(0.30, -20, -14), k(0.50, -6, -8) },
			torso = { k(0, 0, 0, 10), k(0.16, 4, 0, 30), k(0.30, -4, 0, -24), k(0.50, 0, 0, 0) },
			head = { k(0, 0, 0, 8), k(0.30, 0, 0, -12), k(0.50, 0, 0, 0) },
		},
		markers = { { t = 0.14, name = "trail_on" }, { t = 0.24, name = "hit" }, { t = 0.38, name = "trail_off" } },
	},
	attack_3 = {
		duration = 0.74, mask = ALL, priority = 3,
		tracks = {
			rightArm = { k(0, -30, 30), k(0.22, -110, 70), k(0.44, 80, -20), k(0.74, -10, 4) },
			leftArm = { k(0, -30, -30), k(0.22, -80, -60), k(0.44, 40, 10), k(0.74, -6, -8) },
			rightLeg = { k(0, 0), k(0.22, -18), k(0.44, 22), k(0.74, 0) },
			leftLeg = { k(0, 0), k(0.22, 16), k(0.44, -20), k(0.74, 0) },
			torso = { k(0, 0, 0, -20), k(0.22, -10, 0, -70), k(0.44, 12, 0, 80), k(0.74, 0, 0, 0) },
			head = { k(0, 0, 0, -10), k(0.44, 4, 0, 30), k(0.74, 0, 0, 0) },
		},
		markers = { { t = 0.18, name = "trail_on" }, { t = 0.34, name = "hit" }, { t = 0.56, name = "trail_off" } },
	},

	cast = {
		duration = 0.62, mask = UPPER, priority = 2,
		tracks = {
			rightArm = { k(0, -10, 6), k(0.22, -168, 20), k(0.36, -120, 6), k(0.62, -10, 4) },
			leftArm = { k(0, -8, -8), k(0.22, -40, -26), k(0.62, -6, -8) },
			torso = { k(0, 0), k(0.22, -8), k(0.36, 6), k(0.62, 0) },
		},
		markers = { { t = 0.24, name = "telegraph" }, { t = 0.34, name = "release" } },
	},

	hurt = {
		duration = 0.34, mask = ALL, priority = 4,
		tracks = {
			rightArm = { k(0, 0, 0), k(0.10, -34, 40), k(0.34, -6, 8) },
			leftArm = { k(0, 0, 0), k(0.10, -34, -40), k(0.34, -6, -8) },
			torso = { k(0, 0), k(0.10, -22), k(0.34, 0) },
			head = { k(0, 0), k(0.10, -26), k(0.34, 0) },
		},
	},

	block = {
		duration = 0.2, loop = true, hold = true, mask = UPPER, priority = 2,
		tracks = {
			rightArm = { k(0, -78, 34, 20), k(0.2, -74, 32, 20) },
			leftArm = { k(0, -84, -20, -10), k(0.2, -80, -22, -10) },
			torso = { k(0, 6, 0, -8), k(0.2, 5, 0, -8) },
		},
	},

	dodge = {
		duration = 0.45, mask = ALL, priority = 5,
		tracks = {
			rightArm = { k(0, -20, 20), k(0.16, -130, 60), k(0.45, -8, 6) },
			leftArm = { k(0, -20, -20), k(0.16, -130, -60), k(0.45, -8, -6) },
			rightLeg = { k(0, 0), k(0.16, -70), k(0.30, 40), k(0.45, 0) },
			leftLeg = { k(0, 0), k(0.16, -60), k(0.30, 34), k(0.45, 0) },
			torso = { k(0, 0), k(0.16, -46), k(0.30, 14), k(0.45, 0) },
			head = { k(0, 0), k(0.16, -20), k(0.45, 0) },
		},
		markers = { { t = 0.02, name = "iframes_on" }, { t = 0.30, name = "iframes_off" } },
	},

	die = {
		duration = 1.0, mask = ALL, priority = 9, hold = true,
		tracks = {
			rightArm = { k(0, 0, 0), k(0.35, -50, 55), k(1.0, -18, 70) },
			leftArm = { k(0, 0, 0), k(0.35, -50, -55), k(1.0, -18, -70) },
			rightLeg = { k(0, 0), k(1.0, 26) },
			leftLeg = { k(0, 0), k(1.0, -20) },
			torso = { k(0, 0), k(0.4, -30), k(1.0, -78) },
			head = { k(0, 0), k(1.0, 34) },
		},
		markers = { { t = 0.35, name = "fall" } },
	},

	-- heavy attack with a readable wind-up: the telegraph marker is the whole
	-- point, because a boss slam the player cannot read is not difficulty
	slam = {
		duration = 1.15, mask = ALL, priority = 3,
		tracks = {
			rightArm = { k(0, -20, 10), k(0.55, -172, 28), k(0.74, 46, 4), k(1.15, -10, 6) },
			leftArm = { k(0, -20, -10), k(0.55, -172, -28), k(0.74, 46, -4), k(1.15, -10, -6) },
			rightLeg = { k(0, 0), k(0.55, -14), k(0.74, 10), k(1.15, 0) },
			leftLeg = { k(0, 0), k(0.55, 12), k(0.74, -8), k(1.15, 0) },
			torso = { k(0, 0), k(0.55, -26), k(0.74, 24), k(1.15, 0) },
			head = { k(0, 0), k(0.55, -20), k(0.78, 16), k(1.15, 0) },
		},
		markers = { { t = 0.50, name = "telegraph" }, { t = 0.72, name = "hit" } },
	},

	lunge = {
		duration = 0.8, mask = ALL, priority = 3,
		tracks = {
			rightArm = { k(0, -30, 20), k(0.30, -140, 44), k(0.46, 70, -10), k(0.8, -10, 6) },
			leftArm = { k(0, -30, -20), k(0.30, -140, -44), k(0.46, 70, 10), k(0.8, -10, -6) },
			rightLeg = { k(0, 0), k(0.30, -46), k(0.46, 30), k(0.8, 0) },
			leftLeg = { k(0, 0), k(0.30, -30), k(0.46, 24), k(0.8, 0) },
			torso = { k(0, 0), k(0.30, -34), k(0.46, 18), k(0.8, 0) },
		},
		markers = { { t = 0.26, name = "telegraph" }, { t = 0.40, name = "leap" }, { t = 0.52, name = "hit" } },
	},

	--- ranged ------------------------------------------------------------------
	--
	-- A shooting animation is mostly a *pose* plus a very short disturbance of
	-- it. The aim pose is what the player looks at for minutes at a time, so it
	-- carries the weapon's character; the shot itself lasts a fifth of a second
	-- and only has to break the pose convincingly before snapping back.

	-- Held while aiming. Left arm supports, right hand at the cheek, torso
	-- turned into the shot so the shoulders are not square to the target.
	aim = {
		duration = 0.24, loop = true, hold = true, mask = UPPER, priority = 2,
		tracks = {
			leftArm = { k(0, -88, -12, 0), k(0.24, -86, -12, 0) },
			rightArm = { k(0, -72, 30, -14), k(0.24, -70, 32, -14) },
			torso = { k(0, 0, 0, -16), k(0.24, 0, 0, -16) },
			head = { k(0, -4, 0, -8), k(0.24, -4, 0, -8) },
		},
	},

	-- One shot. `release` sits at 0.03 because a trigger is instant: putting it
	-- any later means the bullet leaves after the muzzle has already kicked,
	-- which reads as lag even when the netcode is perfect.
	shoot = {
		duration = 0.26, mask = UPPER, priority = 3,
		tracks = {
			rightArm = { k(0, -72, 30, -14), k(0.05, -84, 34, -20), k(0.26, -72, 30, -14) },
			leftArm = { k(0, -88, -12, 0), k(0.05, -96, -16, 0), k(0.26, -88, -12, 0) },
			torso = { k(0, 0, 0, -16), k(0.05, -5, 0, -18), k(0.26, 0, 0, -16) },
			head = { k(0, -4, 0, -8), k(0.05, -10, 0, -8), k(0.26, -4, 0, -8) },
		},
		markers = { { t = 0.03, name = "release" }, { t = 0.06, name = "eject" } },
	},

	-- Drawing a bow. Held at full draw, so the game decides when it ends; the
	-- `draw_full` marker is where a charge meter should top out.
	bow_draw = {
		duration = 0.8, hold = true, mask = UPPER, priority = 3,
		tracks = {
			leftArm = { k(0, -40, -14, 0), k(0.30, -90, -10, 0), k(0.8, -92, -8, 0) },
			--[[
				The draw arm has to end up *near the other one*.

				Only the shoulder is animated on this rig — there is no elbow to
				bend — so a large spread angle swings the whole arm wide and the
				archer visibly stops touching the bow with it. Keeping the swing
				high and the spread modest reads as two hands on one weapon,
				which is the only thing this pose has to say.
			]]
			rightArm = { k(0, -40, 14, 0), k(0.30, -72, 20, -10), k(0.8, -80, 28, -16) },
			torso = { k(0, 0, 0, 0), k(0.30, 0, 0, -12), k(0.8, -3, 0, -22) },
			head = { k(0, 0, 0, 0), k(0.8, -3, 0, -14) },
		},
		markers = { { t = 0.30, name = "telegraph" }, { t = 0.78, name = "draw_full" } },
	},

	-- Loosing it. The right hand does not travel forward — it opens and the
	-- string throws it back, which is the detail that separates an archer from
	-- someone miming one.
	bow_loose = {
		duration = 0.44, mask = UPPER, priority = 3,
		tracks = {
			-- Follows through from where bow_draw now leaves the arm, not from
			-- the wide pose it used to end in.
			rightArm = { k(0, -80, 28, -16), k(0.06, -74, 46, -20), k(0.44, -34, 14, -6) },
			leftArm = { k(0, -92, -8, 0), k(0.06, -96, -12, 0), k(0.44, -38, -12, 0) },
			torso = { k(0, -3, 0, -22), k(0.08, -1, 0, -12), k(0.44, 0, 0, 0) },
			head = { k(0, -3, 0, -14), k(0.44, 0, 0, 0) },
		},
		markers = { { t = 0.04, name = "release" } },
	},

	-- Reloading. Authored at 1.6s and played at whatever speed the weapon's
	-- reloadTime asks for, so the hands always finish exactly when the magazine
	-- does instead of standing still for the last half second.
	reload = {
		duration = 1.6, mask = UPPER, priority = 2,
		tracks = {
			rightArm = { k(0, -72, 30, -14), k(0.25, -50, 22, -6), k(1.15, -56, 26, -10), k(1.6, -72, 30, -14) },
			leftArm = { k(0, -88, -12, 0), k(0.35, -18, -30, 20), k(0.75, -22, -26, 14), k(1.2, -80, -14, 2), k(1.6, -88, -12, 0) },
			torso = { k(0, 0, 0, -16), k(0.35, 8, 0, -10), k(1.2, 2, 0, -14), k(1.6, 0, 0, -16) },
			head = { k(0, -4, 0, -8), k(0.4, 10, 0, -4), k(1.6, -4, 0, -8) },
		},
		markers = { { t = 0.34, name = "mag_out" }, { t = 0.96, name = "mag_in" }, { t = 1.42, name = "ready" } },
	},

	-- Throwing something. Whole body, because a throw that only moves the arm
	-- has no weight behind it.
	throw = {
		duration = 0.62, mask = ALL, priority = 3,
		tracks = {
			rightArm = { k(0, -20, 12, 0), k(0.24, -166, 26, -20), k(0.36, 30, 10, 10), k(0.62, -12, 6, 0) },
			leftArm = { k(0, -20, -12, 0), k(0.24, -70, -30, 0), k(0.36, -20, -18, 0), k(0.62, -10, -8, 0) },
			rightLeg = { k(0, 0), k(0.24, 14), k(0.36, -16), k(0.62, 0) },
			leftLeg = { k(0, 0), k(0.24, -12), k(0.36, 18), k(0.62, 0) },
			torso = { k(0, 0, 0, 18), k(0.24, -14, 0, 34), k(0.36, 12, 0, -20), k(0.62, 0, 0, 0) },
			head = { k(0, 0, 0, 10), k(0.36, 4, 0, -14), k(0.62, 0, 0, 0) },
		},
		markers = { { t = 0.20, name = "telegraph" }, { t = 0.30, name = "release" } },
	},

	--- holding and handling --------------------------------------------------
	--
	-- A character holding something is in that pose for minutes, and every
	-- other clip plays on top of it. So these are low priority and mostly
	-- still: they set where the hands live, and get out of the way.

	-- Weapon at rest. Not aiming, not idle-empty: a weapon carried down and
	-- across the body, which is what someone does with a thing they expect to
	-- use soon.
	hold = {
		duration = 0.3, loop = true, hold = true, mask = UPPER, priority = 1,
		tracks = {
			-- Carried forward and slightly in, not hanging. An arm left at its
			-- side reads as empty-handed no matter what is welded to it, and
			-- whatever it holds points at the floor.
			rightArm = { k(0, -34, 14, -6), k(0.3, -32, 15, -6) },
			leftArm = { k(0, -38, -12, 0), k(0.3, -36, -13, 0) },
			torso = { k(0, 0, 0, -4), k(0.3, 0, 0, -4) },
		},
	},

	-- Both arms out and slightly up, as if under a crate. The forward torso
	-- lean is the part that sells weight: arms alone read as offering, not
	-- carrying.
	carry = {
		duration = 0.36, loop = true, hold = true, mask = UPPER, priority = 2,
		tracks = {
			rightArm = { k(0, -74, 22, 0), k(0.36, -72, 23, 0) },
			leftArm = { k(0, -74, -22, 0), k(0.36, -72, -23, 0) },
			torso = { k(0, -8, 0, 0), k(0.36, -7, 0, 0) },
			head = { k(0, 5, 0, 0), k(0.36, 4, 0, 0) },
		},
	},

	-- Down to take something off the ground. `grab` is the frame the object
	-- should change hands; before it the hand has not arrived.
	pickup = {
		duration = 0.72, mask = ALL, priority = 3,
		tracks = {
			rightArm = { k(0, -10, 8, 0), k(0.30, -64, 14, 0), k(0.44, -58, 12, 0), k(0.72, -26, 16, -8) },
			leftArm = { k(0, -10, -8, 0), k(0.30, -30, -18, 0), k(0.72, -14, -12, 0) },
			rightLeg = { k(0, 0), k(0.30, -34), k(0.48, -30), k(0.72, 0) },
			leftLeg = { k(0, 0), k(0.30, -12), k(0.72, 0) },
			torso = { k(0, 0), k(0.30, -38), k(0.48, -34), k(0.72, 0) },
			head = { k(0, 0), k(0.30, -18), k(0.72, 0) },
		},
		markers = { { t = 0.34, name = "grab" }, { t = 0.62, name = "lifted" } },
	},

	-- And back down. Slower on the way out than the way in, because setting
	-- something down carefully is the whole difference from dropping it.
	putdown = {
		duration = 0.8, mask = ALL, priority = 3,
		tracks = {
			rightArm = { k(0, -26, 16, -8), k(0.34, -62, 14, 0), k(0.52, -60, 13, 0), k(0.8, -10, 8, 0) },
			leftArm = { k(0, -14, -12, 0), k(0.34, -34, -18, 0), k(0.8, -10, -8, 0) },
			rightLeg = { k(0, 0), k(0.34, -32), k(0.56, -28), k(0.8, 0) },
			leftLeg = { k(0, 0), k(0.34, -10), k(0.8, 0) },
			torso = { k(0, 0), k(0.34, -36), k(0.56, -32), k(0.8, 0) },
			head = { k(0, 0), k(0.34, -16), k(0.8, 0) },
		},
		markers = { { t = 0.46, name = "release" } },
	},

	-- Working on something at chest height: a lever, a panel, a lock. Two
	-- hands, because one-handed fiddling reads as pointing.
	handle = {
		duration = 1.1, loop = true, hold = true, mask = UPPER, priority = 2,
		tracks = {
			rightArm = { k(0, -62, 18, 0), k(0.36, -70, 24, -6), k(0.72, -58, 14, 4), k(1.1, -62, 18, 0) },
			leftArm = { k(0, -60, -16, 0), k(0.36, -54, -12, 4), k(0.72, -66, -20, -4), k(1.1, -60, -16, 0) },
			torso = { k(0, -4, 0, 4), k(0.55, -5, 0, -4), k(1.1, -4, 0, 4) },
			head = { k(0, 8, 0, 0), k(1.1, 8, 0, 0) },
		},
	},

	-- non-combat: needed far more often than people expect
	interact = {
		duration = 0.5, mask = UPPER, priority = 2,
		tracks = {
			rightArm = { k(0, -6, 6), k(0.2, -84, 16), k(0.34, -76, 12), k(0.5, -6, 6) },
			torso = { k(0, 0), k(0.2, 8), k(0.5, 0) },
		},
		markers = { { t = 0.24, name = "touch" } },
	},
	cheer = {
		duration = 0.9, mask = UPPER, priority = 2,
		tracks = {
			rightArm = { k(0, -10, 6), k(0.2, -168, 30), k(0.45, -150, 46), k(0.7, -168, 30), k(0.9, -10, 6) },
			leftArm = { k(0, -10, -6), k(0.2, -168, -30), k(0.45, -150, -46), k(0.7, -168, -30), k(0.9, -10, -6) },
			torso = { k(0, 0), k(0.45, -8), k(0.9, 0) },
		},
	},
}
