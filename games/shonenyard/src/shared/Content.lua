--!strict
--[[
	Content — every fighter, scroll, station and number in shonenyard.

	One module, because the house rule is that a balance number never lives in
	two places. A system that wants a price asks here; nothing else hardcodes.

	Where the numbers came from
	---------------------------

	**The ladder was solved, not chosen.** `rqe.economy.designer` takes what a
	session should feel like and returns the curve that produces it:

	    Targets(tiers=10, first_tier_seconds=35, total_minutes=75,
	            income_multiplier=1.28)

	    Targets(..., base_income_per_second=0.4)

	    tier 1 costs     14 ki   reached at   35s
	    tier 5 costs    403 ki   reached at  ~11m
	    tier 10 costs 11,887 ki  reached at  ~75m

	Thirty-five seconds for the first rung is not a preference either. The only
	real retention record in this repository -- a published game, fifty new
	players -- says 28% left before a first payout that landed at 22 seconds,
	and 74% never reached a second rung at all. A first rung outside the first
	session is a game with one rung.

	**The rarity weights are the shipped ones.** Taken from `forge/kits/halo`,
	which is a pet game that ran with real players, rather than from a feeling
	about what feels rare.

	Why the names are original
	--------------------------

	Every fighter here is written in the genre's idiom and belongs to nobody:
	this is an anime *tycoon*, which is a shape of game, not a licence to ship
	somebody else's characters.
]]

local Content = {}

-- =============================================================== currencies

--[[
	Two, and only two.

	`ki` is earned by the loop and spent by the loop. `shards` come only from
	rare summons and buy the things that would otherwise be a grind wall --
	which keeps the second currency from becoming a second economy nobody
	balanced.
]]
Content.currencies = {
	ki = { display = "Ki", start = 0, precision = 0 },
	shards = { display = "Spirit Shards", start = 0, precision = 0 },
}

-- ================================================================== fighters

--[[
	Rarity is a number because everything downstream does arithmetic on it.

	1 common · 2 uncommon · 3 rare · 4 epic · 5 mythic

	`power` is what the fighter contributes per second when training. It rises
	steeply with rarity on purpose: a mythic that produced 10% more than a
	common would make the whole summon loop pointless, and that is the most
	common way this genre is got wrong.
]]
export type Fighter = {
	id: string,
	name: string,
	rarity: number,
	power: number,
	weight: number,
	blurb: string,
}

local fighters: { Fighter } = {
	-- rarity 1 -- the ones you see in the first minute
	{ id = "broom", name = "Broom Cadet", rarity = 1, power = 1, weight = 400,
	  blurb = "Sweeps the dojo. Has never lost a fight he was allowed to start." },
	{ id = "bento", name = "Bento Runner", rarity = 1, power = 1, weight = 400,
	  blurb = "Fastest hands in the yard, entirely for lunch-related reasons." },
	{ id = "kohai", name = "Eager Kohai", rarity = 1, power = 2, weight = 170,
	  blurb = "Copies every stance he sees. Badly, then suddenly well." },

	-- rarity 2 -- the first upgrade that feels like one
	{ id = "ironfist", name = "Iron Fist Trainee", rarity = 2, power = 5, weight = 90,
	  blurb = "Broke the post. Bought a new post. Broke that one too." },
	{ id = "kite", name = "Kite Duelist", rarity = 2, power = 6, weight = 70,
	  blurb = "Fights at range because getting close is somebody else's problem." },

	-- rarity 3 -- the draw worth telling somebody about
	{ id = "blade", name = "Blade Dancer", rarity = 3, power = 18, weight = 22,
	  blurb = "Three cuts. You will only ever see the third." },
	{ id = "storm", name = "Storm Caller", rarity = 3, power = 20, weight = 18,
	  blurb = "Trains outdoors regardless of forecast. Forecast adjusts." },

	-- rarity 4 -- the one that changes the plot
	{ id = "oni", name = "Oni of the Ninth Gate", rarity = 4, power = 70, weight = 6,
	  blurb = "Was sealed. Is no longer sealed. Is quite polite about it." },
	{ id = "sage", name = "Mountain Sage", rarity = 4, power = 80, weight = 4,
	  blurb = "Meditated for a hundred years. Came down for the tournament." },

	-- rarity 5 -- the reason the collection screen exists
	{ id = "sovereign", name = "Sovereign of the Final Form", rarity = 5, power = 320,
	  weight = 1,
	  blurb = "The yard goes quiet. Even the Broom Cadet stops sweeping." },
}
Content.fighters = fighters

--: Rarity, as the player sees it. The colour is a token name, not a hex --
--: `UI` owns what the colour actually is.
Content.rarities = {
	[1] = { name = "Common", colour = "neutralMid", weightShare = "97%" },
	[2] = { name = "Uncommon", colour = "accentSuccess", weightShare = "13.4%" },
	[3] = { name = "Rare", colour = "accentInfo", weightShare = "3.4%" },
	[4] = { name = "Epic", colour = "accentWarning", weightShare = "0.9%" },
	[5] = { name = "Mythic", colour = "accentDanger", weightShare = "0.09%" },
}

--: The draw table `Loop.Hatch` takes, derived from the fighters above so a
--: fighter can never exist without a weight or drift from one.
function Content.drops(): { { id: string, weight: number, rarity: number } }
	local drops = {}
	for _, fighter in Content.fighters do
		table.insert(drops, {
			id = fighter.id, weight = fighter.weight, rarity = fighter.rarity,
		})
	end
	return drops
end

function Content.fighter(id: string): Fighter?
	for _, fighter in Content.fighters do
		if fighter.id == id then
			return fighter
		end
	end
	return nil
end

-- =================================================================== scrolls

--[[
	Three scrolls, and the first one is free.

	Not a promotion: 28% of new players in the only real retention record left
	before a first payout. A scroll behind a price is a payout behind a price,
	and that is where they go.
]]
Content.scrolls = {
	{ id = "novice", name = "Novice Scroll", cost = 0, currency = "ki",
	  minRarity = 1, blurb = "Everyone's first. Costs nothing, on purpose." },
	{ id = "veteran", name = "Veteran Scroll", cost = 120, currency = "ki",
	  minRarity = 1, rarityBias = 1,
	  blurb = "Weighted away from the sweeping staff." },
	{ id = "ascendant", name = "Ascendant Scroll", cost = 8, currency = "shards",
	  minRarity = 3, blurb = "Rare or better. That is the whole promise." },
}

function Content.scroll(id: string): any
	for _, scroll in Content.scrolls do
		if scroll.id == id then
			return scroll
		end
	end
	return nil
end

-- ================================================================== stations

--[[
	Training stations: the tycoon half.

	A station holds fighters and multiplies what they produce. Slots rather
	than raw multipliers because the interesting decision in a tycoon is
	*which* fighter goes where, and a flat multiplier removes it.
]]
Content.stations = {
	{ id = "post", name = "Punching Post", cost = 0, slots = 2, multiplier = 1.0,
	  tier = 1, blurb = "It came with the yard." },
	--: 70 ki at rank 2, not 240 at rank 2.
	--:
	--: A player who opened this said it had "one plot". They were right, and
	--: not only because the button was broken: at 240 ki and roughly 2.4/s the
	--: second station was a hundred seconds of standing still, which is past
	--: the ninety-second dead-time line `Loop.Hatch` refuses. The second plot
	--: is what turns a button into a tycoon; it has to arrive while the first
	--: one is still interesting.
	{ id = "weights", name = "Weight Rack", cost = 70, slots = 3, multiplier = 1.4,
	  tier = 2, blurb = "Heavier than it looks. It looks heavy." },
	{ id = "mat", name = "Meditation Mat", cost = 320, slots = 3, multiplier = 1.9,
	  tier = 3, blurb = "Ki flows better when nobody is shouting." },
	{ id = "gravity", name = "Gravity Chamber", cost = 1500, slots = 4, multiplier = 3.2,
	  tier = 5, blurb = "Ten times normal. The Broom Cadet declined." },
	{ id = "forge", name = "Spirit Forge", cost = 6000, slots = 5, multiplier = 6.0,
	  tier = 7, blurb = "Where a fighter stops training and starts becoming." },
}

function Content.station(id: string): any
	for _, station in Content.stations do
		if station.id == id then
			return station
		end
	end
	return nil
end

-- ==================================================================== ladder

--[[
	Dojo ranks: the cost ladder, solved rather than chosen.

	These are **cumulative thresholds**, which is what `Progression` means by a
	tier cost -- what a player pays for rank `i` is the difference from rank
	`i-1`. Getting that backwards produces a ladder that looks gentle and is
	brutal, and it is the mistake `rqe/economy/designer.py` was written after.
]]
Content.ranks = {
	{ rank = 1, name = "Open Yard", cost = 14 },
	{ rank = 2, name = "Swept Floor", cost = 41 },
	{ rank = 3, name = "First Banner", cost = 95 },
	{ rank = 4, name = "Named Dojo", cost = 199 },
	{ rank = 5, name = "Regional Entry", cost = 403 },
	{ rank = 6, name = "Ranked Hall", cost = 802 },
	{ rank = 7, name = "Provincial Seat", cost = 1581 },
	{ rank = 8, name = "Grand Hall", cost = 3103 },
	{ rank = 9, name = "Sanctioned Ground", cost = 6077 },
	{ rank = 10, name = "Sovereign Dojo", cost = 11887 },
}

--: The income multiplier the ladder was solved against. Written here so the
--: game cannot run at a pace the pacing report never saw.
Content.incomeMultiplierPerRank = 1.28

--[[
	The empty yard's trickle, and why it is small.

	This was 1.0, which made the first fighter a **100% raise** -- and a raise
	that size on a number that was already moving is one a player does not
	notice. At 0.4 the same fighter is a 250% raise, and the difference between
	those two is whether the summon loop reads as the point of the game or as a
	decoration on top of a number that goes up anyway.

	The ladder above was re-solved against it rather than left alone:
	`rqe.economy.designer` returns the same 35-second first rung and the same
	75-minute run, at costs scaled to the new floor. Changing an income and
	keeping a curve solved for a different one is how a game becomes twice as
	long as its own design document says.
]]
Content.baseIncomePerSecond = 0.4

--: When the second rung becomes reachable, in seconds. Required by
--: `Loop.Hatch` because 74% of new players never reached one.
Content.tierTwoSeconds = 90

-- =================================================================== ascend

--[[
	Ascension: the rebirth loop.

	Priced off the top of the ladder, so ascending is a decision a player makes
	*after* finishing rather than a button they stare at from rank two.
]]
Content.ascend = {
	basePrice = 30000,
	priceGrowth = 2.4,
	--: What each ascension is worth, permanently. Below about 1.5 nobody
	--: ascends twice; above about 3 the second run is over before it starts.
	powerMultiplierPerLife = 1.85,
	shardsPerLife = 25,
}

function Content.ascendPrice(life: number): number
	return math.floor(Content.ascend.basePrice
		* Content.ascend.priceGrowth ^ math.max(0, life - 1))
end

-- ================================================================ collection

--[[
	The collection, which is the reason to come back.

	Every game of this shape lives or dies on it: a player who never opens the
	collection has not been given a reason to return, which is why
	`Loop.Hatch` has a funnel step for looking at it.
]]
Content.milestones = {
	{ id = "first_five", need = 5, reward = { shards = 3 },
	  name = "Five in the Yard" },
	{ id = "all_common", need = 3, rarity = 1, reward = { ki = 250 },
	  name = "Every Beginner" },
	{ id = "first_rare", need = 1, rarity = 3, reward = { shards = 5 },
	  name = "Someone Worth Watching" },
	{ id = "first_epic", need = 1, rarity = 4, reward = { shards = 15 },
	  name = "The Yard Has A Name" },
	{ id = "complete", need = #Content.fighters, reward = { shards = 100 },
	  name = "The Whole Roster" },
}

return Content
