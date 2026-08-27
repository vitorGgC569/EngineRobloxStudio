--!strict
-- Config — every tunable number for quarryline in one place.
-- If a system contains a magic number, it belongs here instead.

return {
	name = "quarryline",
	seed = 20260821,
	saveStore = "quarryline_Profiles_v2",
	containers = { "Plots", "Lines", "Nodes", "Effects", "Drops" },

	--[[
		The plot grid.

		Six plots laid in a row with a gap wide enough that two neighbours
		cannot see each other's conveyors as one line. A tycoon whose plots read
		as a single factory is a tycoon where nobody knows what they own.

		**On the size.** This was forty studs, and forty studs is eight
		characters across -- a patio, not a factory floor. A player standing on
		it could see the whole thing without turning, which leaves a tycoon with
		nothing to grow into and makes every machine on it read as a toy.

		112 is twenty characters across. It is deliberately more room than the
		starting machines need: an empty corner is the thing a tycoon is *for*,
		and a plot that looks full at the start has nowhere to go.
	]]
	plots = { count = 6, size = 112, spacing = 150, origin = Vector3.new(0, 12, 0) },

	--[[
		The tick the whole economy runs on.

		Two seconds, not a frame. Everything here is production over time and
		nothing about it is per-frame: a conveyor that moves on Heartbeat costs
		sixty times more to be exactly as slow. The number is here rather than
		in the loop because it is the single biggest lever on this game's cost.
	]]
	tickSeconds = 2,

	--: How long an absent player keeps earning, in hours. Beyond this the
	--: offline payout stops growing — a week away must not buy the endgame.
	offlineCapHours = 8,

	-- Run the live suite during bootstrap and publish the report. On in
	-- Studio, off in a published place: these scenarios write to a DataStore
	-- and place geometry, neither of which belongs in somebody's session.
	selfTest = game:GetService("RunService"):IsStudio(),
}
