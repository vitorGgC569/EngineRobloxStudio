--!strict
--[[
	Config — every tunable number for overflow in one place.

	The game: a sorting line that speeds up until you drown in it. Crates ride
	a trunk belt past four chutes. Each chute has a gate. Open the right gate as
	the right crate passes and it drops in; open the wrong one, or none, and you
	take a strike. Three strikes ends the shift.

	The verb is **anticipate and route**, not fetch and carry. You never pick
	anything up — you are a switch operator, and the whole skill is reading what
	is coming and being at the right lever when it arrives.
]]

local RunService = game:GetService("RunService")

return {
	selfTest = RunService:IsStudio(),

	name = "overflow",
	seed = 20260828,
	saveStore = "overflow_Profiles_v1",
	containers = { "Mill", "Line", "Chutes", "Props", "Effects" },

	--[[
		The trunk belt.

		Crates enter at `headX` and are lost at `tailX`. Everything else is
		measured against those two numbers: the chutes sit between them, the
		player's run is along them, and the difficulty is how long a crate takes
		to cross them.
	]]
	belt = {
		headX = -78,
		tailX = 78,
		z = 0,
		y = 4.2,
		width = 9,
	},

	--[[
		Four chutes, evenly spaced, each taking one kind.

		Four and not six: the run between the outermost pair is what sets the
		skill ceiling, and six chutes over the same belt makes the middle two
		free while the ends become impossible.

		`span` is how much of the belt a chute can pull from. A crate is taken
		when it is inside the span *and* the gate is open, so a wider span is a
		more forgiving window and the reason `reach` is an upgrade.
	]]
	chutes = {
		span = 11,
		--: Colour is the whole language of this game. Four hues that stay
		--: distinct for the most common colour blindness: blue/amber is safe,
		--: and green/red is not, so the fourth is violet rather than red.
		{ id = "ore",    label = "ORE",    x = -54, color = { 108, 176, 246 } },
		{ id = "grain",  label = "GRAIN",  x = -18, color = { 236, 186, 82 } },
		{ id = "scrap",  label = "SCRAP",  x = 18,  color = { 126, 206, 138 } },
		{ id = "flux",   label = "FLUX",   x = 54,  color = { 196, 132, 236 } },
	},

	gate = {
		--: How long a gate stays open after it is pulled. Long enough that a
		--: pull made in anticipation still catches the crate; short enough that
		--: opening everything and walking away is not a strategy.
		openSeconds = 1.7,
		--: A gate that just shut cannot be pulled again immediately. Without
		--: this, holding the key at one chute sorts the whole line.
		cooldownSeconds = 0.45,
		--: How close the player must be to pull it.
		range = 13,
	},

	line = {
		--: Studs per second at the start of a shift, and where it ends up. The
		--: crate's whole journey is 156 studs, so a shift starts at thirteen
		--: seconds of thinking time per crate and ends at four and a half.
		startSpeed = 11,
		maxSpeed = 34,
		--[[
			Seconds between crates, start and floor.

			2.6 was the first number and it was measured wrong. A crate crosses
			the belt in fourteen seconds, so at 2.6 the second and third arrive
			2.6 and 5.2 seconds after the first — which means a player who
			misses one has five seconds to fix everything before the shift is
			over. That is not difficulty, it is a shift that ends before it has
			explained itself.
		]]
		startInterval = 3.4,
		minInterval = 0.85,
		--: How many correct sorts it takes to go from start to max. The whole
		--: difficulty curve is this one number.
		rampSorts = 45,
		--: How many crates ahead the player can see on the HUD. This is the
		--: game's central fairness: routing is only a skill if you can plan.
		previewCount = 4,
	},

	shift = {
		--: Four, not three. See the note on `startInterval`: the strikes arrive
		--: within seconds of each other, so the count is the only slack a new
		--: player gets.
		strikes = 4,
		--: Consecutive correct sorts multiply the score. Breaking the streak
		--: on a mistake is most of what makes a mistake hurt.
		streakStep = 4,
		maxMultiplier = 5,
		scorePerSort = 10,
		--: Coins are the persistent currency, and deliberately much smaller
		--: than score: score is the round, coins are the account.
		coinsPerSort = 1,
	},

	walk = {
		--: No sprint key. The belt is the clock; a second control competing
		--: with the gates would only ever be held down.
		speed = 26,
	},

	upgrades = {
		{ id = "reach",  label = "Wider Chutes", detail = "+1.2 studs of catch window", base = 30, growth = 1.7, max = 5 },
		{ id = "hold",   label = "Slow Levers",  detail = "Gates stay open +0.2s",      base = 40, growth = 1.8, max = 5 },
		{ id = "brake",  label = "Line Brake",   detail = "The whole line runs slower",        base = 55, growth = 1.9, max = 4 },
		{ id = "buffer", label = "Spare Bin",    detail = "+1 strike before the horn",  base = 90, growth = 2.4, max = 3 },
	},
}
