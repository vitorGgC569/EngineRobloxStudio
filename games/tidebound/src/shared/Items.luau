--!strict
--[[
	Items — rods, baits and boats.

	Three ladders that multiply rather than stack, which is the balance shape
	this game wants: a good rod with no bait catches less often than a cheap
	rod with the right bait, and only a boat gets you to the water where the
	rod's ceiling matters.

	Every entry's id is a save file value. Renaming one orphans owned items,
	so ids are stable and human-readable on purpose (`carbon`, not `rod_3`).
]]

local Items = {}

-- ================================== rods ====================================
--: power     — the weight in kg at which the reel minigame is hardest. A fish
--:             heavier than this is not refused; it is *hard*, up to a cap.
--: luck      — pulls rare tiers up the draw table.
--: range     — how far the rod can cast, in studs.
--: reel      — multiplier on the minigame's progress rate. A better rod wins
--:             faster, it does not win for you.
Items.rods = {
	{ id = "bamboo", name = "Bamboo Rod", cost = 0, power = 35, luck = 0, range = 42, reel = 1.0,
		blurb = "A stick, a line, and an unreasonable amount of hope." },
	{ id = "fiberglass", name = "Fiberglass Rod", cost = 900, power = 85, luck = 1, range = 50, reel = 1.12,
		blurb = "Forgiving on the cast and honest on the fight." },
	{ id = "carbon", name = "Carbon Rod", cost = 4500, power = 190, luck = 3, range = 58, reel = 1.25,
		blurb = "Light enough to forget, strong enough to regret forgetting." },
	{ id = "titanium", name = "Titanium Rod", cost = 14000, power = 430, luck = 5, range = 66, reel = 1.38,
		blurb = "The shelf standard. Bends where it should and nowhere else." },
	{ id = "abyssal", name = "Abyssal Rod", cost = 38000, power = 950, luck = 8, range = 76, reel = 1.52,
		blurb = "Built from salvage no one will admit to hauling up." },
	{ id = "stormforged", name = "Stormforged Rod", cost = 90000, power = 1900, luck = 11, range = 88, reel = 1.66,
		blurb = "Squall-tempered. The line sings in weather that grounds boats." },
	{ id = "tidecaller", name = "Tidecaller", cost = 260000, power = 4200, luck = 15, range = 100, reel = 1.8,
		blurb = "The water answers it. Everything else is just waiting." },
}

Items.rodById = {}
for _, rod in Items.rods do
	Items.rodById[rod.id] = rod
end

-- ================================== baits ===================================
--: Bites are faster and odds improve; each unit is consumed by the catch that
--: uses it. `bite` multiplies the wait (lower is faster). `zone` biases the
--: draw toward a depth class where the catalogue supports it.
Items.baits = {
	{ id = "worm", name = "Earthworm", cost = 25, stack = 10, bite = 0.85, luck = 0,
		blurb = "Cheap, reliable, and beneath the dignity of exactly nothing." },
	{ id = "shrimp", name = "River Shrimp", cost = 120, stack = 10, bite = 0.7, luck = 1,
		blurb = "What everything in the shallows is already looking for." },
	{ id = "squid", name = "Squid Strip", cost = 520, stack = 10, bite = 0.62, luck = 2,
		blurb = "The reef's currency. Reef habits are expensive." },
	{ id = "glow", name = "Glowfin Chum", cost = 2000, stack = 8, bite = 0.55, luck = 4,
		blurb = "Lights up the dark and everything curious in it. Best at night." },
	{ id = "kraken", name = "Kraken Essence", cost = 9000, stack = 5, bite = 0.5, luck = 7,
		blurb = "Do not ask what it is ground from. The trench does not answer." },
}

Items.baitById = {}
for _, bait in Items.baits do
	Items.baitById[bait.id] = bait
end

-- ================================== boats ===================================
--: speed    — target cruise, studs per second.
--: crate    — added crate capacity while owned.
--: luck     — applies while the player is aboard their own boat.
--: hull     — base hull size, which the builder scales from.
Items.boats = {
	{ id = "rowboat", name = "Rowboat", cost = 0, speed = 26, crate = 0, luck = 0,
		blurb = "Gets you out there, slowly, and gets you back the same way." },
	{ id = "sailboat", name = "Sailboat", cost = 3000, speed = 40, crate = 12, luck = 0,
		blurb = "The wind does most of the work and takes most of the credit." },
	{ id = "trawler", name = "Trawler", cost = 20000, speed = 52, crate = 28, luck = 1,
		blurb = "A working deck. Room for everything you catch and nowhere for excuses." },
	{ id = "cutter", name = "Tide Cutter", cost = 85000, speed = 68, crate = 48, luck = 2,
		blurb = "Built for open shelf crossings and the weather that guards them." },
}

Items.boatById = {}
for _, boat in Items.boats do
	Items.boatById[boat.id] = boat
end

function Items.crateCapacity(boatId: string?): number
	local boat = boatId and Items.boatById[boatId]
	return 24 + (boat and boat.crate or 0)
end

-- ============================== silhouettes ================================
--: The catch card draws a species from a small set of procedural emblems; this
--: maps the catalogue's creature classes onto the ones it can draw.
Items.displayClass = {
	fish = "fish",
	eel = "eel",
	ray = "ray",
	shark = "shark",
	squid = "squid",
	crab = "crab",
	jelly = "jelly",
	angler = "angler",
	legend = "legend",
}

return Items
