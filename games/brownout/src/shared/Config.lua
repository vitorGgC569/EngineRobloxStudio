--!strict
--[[
	Config — every tunable number for brownout in one place.

	The game: a night shift at an off-grid outpost. The generator is starving,
	and the only fuel left is scattered out past the lamps. Haul it back before
	the lights go out.

	Numbers here are the game's design, not its implementation. A system that
	invents a number is a system nobody can rebalance.
]]

local RunService = game:GetService("RunService")

return {
	selfTest = RunService:IsStudio(),

	name = "brownout",
	seed = 20260826,
	saveStore = "brownout_Profiles_v1",
	containers = { "Outpost", "Lamps", "Cells", "Props", "Effects" },

	--: The outpost sits at the origin. Everything else is measured from it.
	origin = Vector3.new(0, 0, 0),

	generator = {
		--: Charge is a percentage, and the whole game is the fight to keep it
		--: above zero. Starting below half so the first thirty seconds already
		--: have a problem in them.
		--: Raised from 46 after watching a live session: at 46 an idle generator
		--: blacks out in 74 seconds, which is less time than a new player needs
		--: to work out what the game wants from them.
		startCharge = 62,
		maxCharge = 100,

		--: Charge lost per second at the start of a night. This is the single
		--: most important number in the game: too low and there is no pressure,
		--: too high and a solo player cannot cover the round trip.
		--:
		--: Measured against the loop: the nearest cell ring is ~170 studs out,
		--: a carried run is ~14 studs/second, so one trip is roughly 26s. At
		--: 0.62/s that trip costs 16 charge and the smallest cell returns 14 --
		--: a losing trade, on purpose. The player has to go further out.
		baseDrain = 0.62,

		--: Drain climbs across the night, so the last two minutes are the ones
		--: people talk about. Multiplied into baseDrain.
		drainRamp = 0.9,

		--: Each additional player raises the load. A four-player server is not
		--: four times easier than a solo one; it is a bigger machine to feed.
		drainPerExtraPlayer = 0.16,
	},

	night = {
		--: Seconds of night before dawn. Long enough that the ramp is felt,
		--: short enough that a player who dies has not lost their evening.
		duration = 420,
		--: Seconds of dawn: payout, breathing room, no drain.
		dawnDuration = 26,
	},

	--: Charge maps to a lit radius, and the lit radius is the safe zone. This
	--: is the game's central legibility trick: the player never has to read the
	--: gauge, because the world itself is the gauge.
	light = {
		minRadius = 30,
		maxRadius = 172,
		--: Lamp rings, in studs from the outpost. A lamp lights when the safe
		--: radius reaches it, so losing charge visibly switches lamps off from
		--: the outside in.
		rings = { 34, 62, 92, 124, 156 },
		lampsPerRing = { 4, 6, 8, 10, 12 },
	},

	--: Out past the last lamp. Further rings pay more because the trip back is
	--: longer and darker -- that is the entire risk curve of the game.
	cells = {
		rings = {
			--: Ring one was exactly break-even against the drain on a measured
			--: round trip (~20s out and back, ~12 charge lost, 14 returned),
			--: which made it a trap rather than a fallback. Nudged positive.
			{ radius = 210, grade = 1, charge = 19, watts = 11, count = 9, color = { 118, 196, 132 } },
			{ radius = 290, grade = 2, charge = 30, watts = 24, count = 7, color = { 122, 172, 246 } },
			{ radius = 372, grade = 3, charge = 58, watts = 62, count = 5, color = { 232, 132, 224 } },
		},
		--: Seconds before a taken cell reappears somewhere on its ring. Without
		--: a respawn the field empties and the night becomes unwinnable; with a
		--: fast one there is no reason to ever leave the first ring.
		respawnSeconds = 26,
		--: Carrying is a real cost, or there is no decision in picking up a
		--: bigger one.
		carrySlowPerGrade = 0.11,
		pickupRange = 11,
	},

	--: Outside the lit radius the dark does the work of a monster without
	--: needing one. Exposure fills, then bites.
	exposure = {
		--[[
			Points per second gained outside light, lost inside it.

			Tuned against the measured round trips rather than guessed. At 9.5 a
			player filled in 10.5 seconds, and every run past ring one — 28
			seconds outside the light for ring two, 37 for ring three — was
			simply lethal, so the only survivable play was the one ring that did
			not pay. At 4.5 a fresh player lasts 22 seconds out there: ring one
			is free, ring two costs blood, and ring three needs the lantern
			upgrade. That is the progression the shop is for.
		]]
		gainPerSecond = 4.5,
		recoverPerSecond = 26,
		--: Damage per second once exposure is full.
		max = 100,
		damagePerSecond = 13,
		--: The handheld lantern is a personal pocket of safety, and its radius
		--: is the first upgrade anyone buys.
		lanternRadius = 15,
	},

	walk = {
		base = 19,
		--: Sprint is free and always available. A survival game that meters
		--: movement with a stamina bar spends the player's attention on the bar
		--: instead of on the dark.
		sprint = 27,
	},

	upgrades = {
		--: name, label, cost curve, max level. Cost is watts.
		{ id = "lantern", label = "Lantern Range", detail = "+4 studs of personal light", base = 40, growth = 1.75, max = 6 },
		{ id = "hauler",  label = "Hauler Rig",    detail = "Carry slows you less",       base = 55, growth = 1.85, max = 5 },
		{ id = "coupler", label = "Fast Coupler",  detail = "+12% charge per deposit",    base = 90, growth = 2.0,  max = 5 },
		{ id = "boots",   label = "Grip Boots",    detail = "+1.6 sprint speed",          base = 70, growth = 1.9,  max = 5 },
	},

	--: Survive to dawn and the shift pays. Scaled by nights survived so a long
	--: session is worth staying in.
	payout = { base = 55, perNight = 22 },
}
