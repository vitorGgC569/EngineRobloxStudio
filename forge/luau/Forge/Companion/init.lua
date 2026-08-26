--!strict
--[[
	Companion — things that follow you, and stay readable while they do.

	Pets, drones, hired workers, a bodyguard, a squad. The genre changes and
	the problems do not: where does each one stand, what does it do while
	nothing is happening, and how does it get there without fighting physics.

		local Companion = Forge.Companion

		local slots = Companion.Formation.resolve(followers, { mode = "risers" })
		local dx, dz = Companion.Meander.step(state, dt, stillFor, busy)

	Generalised from a shipped simulator, which is where the parts that are not
	obvious come from:

	  * followers are sorted **small to front** and spaced by their own
	    footprint, so one large member does not eclipse or shoulder the rest;
	  * the idle wander waits on the **leader's** stillness, not the follower's,
	    and surrenders the instant the leader moves;
	  * crowding is resolved by **pushing targets apart**, never by collision,
	    so the mover keeps sole control of the parts.

	Three things that system knew and this deliberately does not do
	--------------------------------------------------------------

	**No physics.** The version this comes from began as one cloned script per
	follower driving unanchored parts on the server, and its own config carries
	the warning: several active at once "tanks server FPS". Formation maths
	returns offsets; moving something is the caller's, on the client, where a
	cosmetic follower belongs.

	**No teleport watchdog here.** That system needed one -- followers fell off
	the map, and the comment records it as a bug that survived ten months. A
	watchdog belongs to whatever owns the parts, because only that knows what
	"lost" means for its own world.

	**No ownership of what a follower *is*.** Its power, its rarity, its
	inventory slot: that is the game's, and a follow system that also owned
	those would be a pet system rather than a companion one.
]]

local Companion = {}

Companion.Formation = require(script.Formation)
Companion.Meander = require(script.Meander)

--[[
	The tuning a shipped simulator arrived at, as a starting point.

	Offered rather than imposed: every value here was reached by watching real
	players, and every value here is also specific to a game where the
	followers were pets roughly the size of a person. A game whose companions
	are drones or wolves should expect to move them -- but starting from
	numbers somebody tuned beats starting from round ones.
]]
Companion.tuned = {
	formation = {
		mode = "risers",
		followDistance = 6,
		height = 2,
		gap = 1.5,
		defaultFootprint = 4,
		perRow = 3,
		rowGap = 2,
		colSpacing = 3,
		radius = 11,
		arcStepDegrees = 20,
		spreadFactor = 0.15,
		depthFactor = 0.1,
		--: Large followers usually hover, because scaling the model does not
		--: scale the flat formation height. A tall one can sink instead, and
		--: wants a positive value -- hence the per-id table.
		floatOffsets = { normal = 0, large = -1.5, byId = {} },
	},
	bob = { amplitude = 0.5, period = 2 },
	--: Targets closer than this get nudged apart. Zero disables it.
	separation = 3,
	meander = {
		enabled = true,
		leaderStillSeconds = 2,
		radius = 6,
		speed = 4,
		pauseMin = 1.5,
		pauseMax = 4,
	},
}

--[[
	Every slot for a group, with the bob and the crowding already applied.

	The one call a mover needs per frame. Kept here rather than in `Formation`
	because it composes three ideas that are separately useful and separately
	testable.
]]
function Companion.place(followers: { any }, clock: number, config: any?): { any }
	local tuning = config or Companion.tuned
	local formation = tuning.formation or Companion.tuned.formation
	local slots = Companion.Formation.resolve(followers, formation)

	local separation = tuning.separation
	if separation and separation > 0 then
		slots = Companion.Formation.separate(slots, separation)
	end

	local bob = tuning.bob or Companion.tuned.bob
	for index, slot in slots do
		slot.y += Companion.Formation.bob(index, clock, bob.amplitude, bob.period)
	end
	return slots
end

function Companion.describe(): { [string]: any }
	return {
		shapes = { "conga", "risers", "arc" },
		tuned = Companion.tuned,
	}
end

return Companion
