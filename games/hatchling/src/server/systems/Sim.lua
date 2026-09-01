--!strict
--[[
	Sim — the machine. One player's save, and every rule that acts on it.

	No Instances, no names, no art. This module decides what breaking a crate,
	hatching an egg, equipping a pet and rebirthing *mean*, against plain
	tables, so the whole economy can be played through in a second before a
	single Part exists.

	It also contains no string a player will ever read. Everything nameable
	lives in `Theme`, and the join is the rarity tier: this says "tier 5 pets
	have power 40 and drop at weight 8"; the theme says tier 5 is called a
	Starmane. That is what makes the second theme a list of names rather than a
	rebalance.

	The loop
	--------

	  break a crate  ->  coins, scaled by the pets you have equipped
	  spend coins    ->  an egg
	  hatch the egg  ->  a pet, weighted by that egg's tier
	  equip better   ->  crates pay more
	  pay the toll   ->  a zone whose crates pay more again
	  rebirth        ->  give it all back for a permanent multiplier

	Every one of those is a rule here and a picture somewhere else.
]]

local Sim = {}

--: The clock, as a field. Nothing here waits, but offline earnings and the
--: daily do arithmetic against wall time, and a module that reaches for
--: `os.time()` directly cannot be exercised without waiting for it.
Sim.clock = os.time

-- =============================== the ladder =================================
--[[
	Seven tiers, and everything else in the game is a function of them.

	`power` is the multiplier a pet of that tier contributes. It climbs by
	roughly 3x a tier, which is steep enough that a Legendary is a visible event
	and shallow enough that a bag of Commons is not worthless.

	`weight` is the base drop rate before an egg leans on it. The two curves
	pull against each other on purpose: the thing that is 400x stronger is
	roughly 6,600x rarer, so the ladder is worth climbing for a long time.
]]
Sim.RARITIES = {
	{ id = "common", name = "Common", power = 1, weight = 1000 },
	{ id = "uncommon", name = "Uncommon", power = 2, weight = 420 },
	{ id = "rare", name = "Rare", power = 5, weight = 130 },
	{ id = "epic", name = "Epic", power = 14, weight = 34 },
	{ id = "legendary", name = "Legendary", power = 40, weight = 8 },
	{ id = "mythic", name = "Mythic", power = 120, weight = 1.6 },
	{ id = "secret", name = "Secret", power = 400, weight = 0.15 },
}

Sim.TIERS = #Sim.RARITIES

function Sim.rarity(tier: number): any
	return Sim.RARITIES[math.clamp(tier, 1, Sim.TIERS)]
end

-- ================================== eggs ====================================
Sim.EGG_TIERS = 6

--: What an egg costs. Steep, because the egg you can just afford should always
--: be the one you want and never the one you have outgrown.
function Sim.eggCost(tier: number): number
	return math.floor(120 * (9.5 ^ (tier - 1)))
end

--[[
	How an egg leans its drop table.

	Every egg can drop every rarity -- a table that hard-excludes the top is a
	table where the best egg is the only egg worth opening, and the early game
	loses its lottery. Instead each egg shifts the whole curve: `lean` is how
	many tiers up the weight distribution slides.

	The consequence worth knowing: a tier-1 egg can produce a Secret. It happens
	about once in seventy thousand, and the one player it happens to tells
	everybody.
]]
function Sim.eggWeights(tier: number): { number }
	--[[
		The curve is *moved*, not attenuated.

		First attempt scaled each rarity's own base weight by its distance from
		the egg's centre, plus a small floor of that same base weight. Common's
		base is 1000 and Secret's is 0.15, so the floor alone put 50% Common in
		the best egg in the game -- a worse table than the third-cheapest. The
		base weights are too skewed to be attenuated; the shape has to slide
		along the ladder instead, and stop referring to the base at all.

		Two-sided on purpose, and asymmetric. Going *up* from an egg's sweet
		spot falls off hard, so the top of the ladder stays rare everywhere.
		Going *down* falls off gently, so an expensive egg still pays out
		something rather than nothing when it misses.
	]]
	local lean = (tier - 1) * 1.15
	local out = {}
	for index in Sim.RARITIES do
		local x = (index - 1) - lean
		out[index] = if x >= 0 then 4.5 ^ -x else 1.75 ^ x
	end
	return out
end

--: Rolls without pity, so the same seed always gives the same egg. Pity is
--: applied by `hatch`, which owns the counter.
function Sim.rollTier(tier: number, roll: number): number
	local weights = Sim.eggWeights(tier)
	local total = 0
	for _, w in weights do
		total += w
	end
	local target = math.clamp(roll, 0, 0.999999) * total
	local acc = 0
	for index, w in weights do
		acc += w
		if target < acc then
			return index
		end
	end
	return 1
end

--[[
	Pity: a guaranteed step up the ladder after a dry run.

	Counted per egg tier rather than globally, because a player grinding a
	tier-1 egg and a player grinding a tier-6 egg are having different
	experiences and should not share a counter.
]]
Sim.PITY_AT = 40
Sim.PITY_FLOOR = 4

-- ================================== pets ====================================
export type Pet = { id: string, tier: number, shiny: boolean? }

--: A shiny is the same creature, ten times the power, about one in a hundred.
--: It exists so that a duplicate can still be the best thing that happened
--: today, which is the whole answer to a collection game's late grind.
Sim.SHINY_CHANCE = 0.01
Sim.SHINY_POWER = 10

function Sim.power(pet: Pet): number
	local base = Sim.rarity(pet.tier).power
	return if pet.shiny then base * Sim.SHINY_POWER else base
end

Sim.START_SLOTS = 3
Sim.MAX_SLOTS = 8

function Sim.slotCost(owned: number): number
	return math.floor(2500 * (9 ^ (owned - Sim.START_SLOTS)))
end

--[[
	What the equipped pets multiply crates by.

	A sum rather than a product, and the first pet is worth as much as the
	fourth. Multiplying would make the fourth slot worth more than every earlier
	upgrade combined, and the whole mid-game would be one purchase.
]]
function Sim.multiplier(state: State): number
	local total = 0
	for _, uid in state.equipped do
		local pet = state.pets[uid]
		if pet then
			total += Sim.power(pet)
		end
	end
	return 1 + total
end

-- ================================== zones ===================================
Sim.ZONES = 6

--: What a zone's crates are worth, and what it costs to be let in. The toll is
--: about eight crates' worth of the *previous* zone, so arriving somewhere new
--: is a short goal rather than a wall.
function Sim.crateValue(zone: number): number
	return math.floor(10 * (5.2 ^ (zone - 1)))
end

--[[
	How long a zone should take, in minutes of ordinary play.

	This is the tuning surface, and it is deliberately the *only* one: a
	designer holds "zone 4 should take about an hour" in their head, and cannot
	hold "the toll constant is 900". Every toll below is derived from these
	numbers and the income model, so changing the pacing is changing this table
	and nothing else.

	Priced by hand the first time, and the measurement was damning: the toll
	cost 5.6 minutes at zone 2 and 0.8 at zone 6. The game got *faster* as it
	went, because income compounds at about 15x a zone -- crate value times a
	better ladder of pets -- and a hand-written toll curve grew at 9.5x. A
	progression that accelerates has no late game; it has an ending nobody
	reached on purpose.
]]
Sim.MINUTES_PER_ZONE = { 0, 5, 13, 28, 55, 100 }

--: 30 crates a minute is what an ordinary player manages: walk, break, walk.
--: It is the constant every pacing number here is quoted in.
Sim.CRATES_PER_MINUTE = 30

--[[
	The multiplier a player will plausibly have when they arrive at a zone.

	Not their best case -- the ladder they can *sustain*: a full bench of the
	tier the egg they can afford there mostly drops. Pricing against the best
	case makes every toll a wall; pricing against the worst makes them all
	free.
]]
function Sim.expectedMultiplier(zone: number): number
	local tier = math.clamp(zone + 1, 1, Sim.TIERS)
	return 1 + Sim.MAX_SLOTS * Sim.RARITIES[tier].power
end

function Sim.incomePerMinute(zone: number): number
	return Sim.crateValue(zone) * Sim.expectedMultiplier(zone)
		* Sim.CRATES_PER_MINUTE
end

--: The toll is what you earn in the zone you are leaving, times how long the
--: next one is meant to be worth waiting for.
function Sim.zoneToll(zone: number): number
	if zone <= 1 then
		return 0
	end
	local minutes = Sim.MINUTES_PER_ZONE[math.min(zone, #Sim.MINUTES_PER_ZONE)]
	return math.floor(Sim.incomePerMinute(zone - 1) * minutes)
end

-- ================================= rebirth ==================================
--: Give everything back except the collection, for a permanent multiplier.
--: The book is what makes a rebirth survivable: you keep what you have seen.
--: Rebirth is priced off the last zone for the same reason the tolls are: a
--: constant chosen by hand is a constant that stops being true the moment any
--: other number moves. Three hours of the endgame for the first one, and each
--: one after is worth two and a half times the last.
Sim.REBIRTH_MINUTES = 180

function Sim.rebirthCost(count: number): number
	return math.floor(Sim.incomePerMinute(Sim.ZONES) * Sim.REBIRTH_MINUTES
		* (2.5 ^ count))
end

function Sim.rebirthBonus(count: number): number
	return 1 + count * 0.75
end

-- ================================== state ===================================
export type State = {
	coins: number,
	gems: number,
	earned: number,
	pets: { [string]: Pet },
	equipped: { string },
	slots: number,
	zone: number,
	unlocked: number,
	seen: { [string]: boolean },
	shards: number,
	pity: { [number]: number },
	rebirths: number,
	hatched: number,
	broken: number,
	nextUid: number,
	lastSeen: number,
}

function Sim.blank(): State
	return {
		--: Enough for the first egg and nothing else. The first thirty seconds
		--: are the only ones every player sees, and they should contain a hatch.
		coins = 100,
		gems = 0,
		earned = 0,
		pets = {},
		equipped = {},
		slots = Sim.START_SLOTS,
		zone = 1,
		unlocked = 1,
		seen = {},
		shards = 0,
		pity = {},
		rebirths = 0,
		hatched = 0,
		broken = 0,
		nextUid = 1,
		lastSeen = Sim.clock(),
	}
end

function Sim.reconcile(state: any): State
	local blank = Sim.blank()
	if type(state) ~= "table" then
		return blank
	end
	for key, value in blank do
		if state[key] == nil then
			state[key] = value
		end
	end
	for _, key in { "pets", "seen", "pity" } do
		if type(state[key]) ~= "table" then
			state[key] = {}
		end
	end
	if type(state.equipped) ~= "table" then
		state.equipped = {}
	end
	--: Equipped ids that no longer name a pet are dropped rather than left to
	--: return nil from `multiplier` forever.
	local kept = {}
	for _, uid in state.equipped do
		if state.pets[uid] and #kept < state.slots then
			table.insert(kept, uid)
		end
	end
	state.equipped = kept
	return state
end

-- ================================= actions ==================================
--: Every action answers `(ok, detailOrReason)`. A refusal with a reason is the
--: difference between "the button is broken" and "you cannot afford that".

function Sim.breakCrate(state: State): (boolean, any)
	local value = math.floor(Sim.crateValue(state.zone) * Sim.multiplier(state)
		* Sim.rebirthBonus(state.rebirths))
	state.coins += value
	state.earned += value
	state.broken += 1
	return true, { coins = value, multiplier = Sim.multiplier(state) }
end

--[[
	Hatch one egg.

	`roll` and `shinyRoll` are supplied rather than drawn, so a hatch is
	reproducible from a seed and the whole drop distribution can be exercised in
	a test without a random number generator being involved at all.
]]
function Sim.hatch(state: State, eggTier: number, pick: (number) -> string,
                   roll: number, shinyRoll: number): (boolean, any)
	if eggTier < 1 or eggTier > Sim.EGG_TIERS then
		return false, "no such egg"
	end
	local cost = Sim.eggCost(eggTier)
	if state.coins < cost then
		return false, "not enough to hatch that"
	end
	state.coins -= cost

	local tier = Sim.rollTier(eggTier, roll)
	local dry = (state.pity[eggTier] or 0) + 1
	if tier >= Sim.PITY_FLOOR then
		dry = 0
	elseif dry >= Sim.PITY_AT then
		--: The dry run ends. Not at the top -- a guaranteed Secret would make
		--: the counter the only thing anyone plays.
		tier = Sim.PITY_FLOOR
		dry = 0
	end
	state.pity[eggTier] = dry

	local id = pick(tier)
	local uid = "p" .. state.nextUid
	state.nextUid += 1
	local shiny = shinyRoll < Sim.SHINY_CHANCE
	state.pets[uid] = { id = id, tier = tier, shiny = shiny }
	state.hatched += 1

	local isNew = not state.seen[id]
	state.seen[id] = true

	--: Auto-equip while there is room. A first-time player should not have to
	--: find an equip screen to feel their first hatch.
	if #state.equipped < state.slots then
		table.insert(state.equipped, uid)
	end
	return true, { uid = uid, id = id, tier = tier, shiny = shiny,
		isNew = isNew, spent = cost, pity = dry }
end

function Sim.equip(state: State, uid: string): (boolean, any)
	if not state.pets[uid] then
		return false, "no such pet"
	end
	for _, held in state.equipped do
		if held == uid then
			return false, "already out"
		end
	end
	if #state.equipped >= state.slots then
		return false, "no free slot"
	end
	table.insert(state.equipped, uid)
	return true, { uid = uid, multiplier = Sim.multiplier(state) }
end

function Sim.unequip(state: State, uid: string): (boolean, any)
	for index, held in state.equipped do
		if held == uid then
			table.remove(state.equipped, index)
			return true, { uid = uid, multiplier = Sim.multiplier(state) }
		end
	end
	return false, "that one is not out"
end

--[[
	Equip the strongest, which is what every player does by hand every session.

	Offering it as a button is not a convenience, it is a decision about what
	the game is *about*: managing a list is not the fantasy, and a game that
	makes you do it anyway is one people stop opening.
]]
function Sim.equipBest(state: State): (boolean, any)
	local order = {}
	for uid in state.pets do
		table.insert(order, uid)
	end
	table.sort(order, function(a, b)
		local pa, pb = Sim.power(state.pets[a]), Sim.power(state.pets[b])
		if pa ~= pb then
			return pa > pb
		end
		return a < b
	end)
	local equipped = {}
	for index = 1, math.min(state.slots, #order) do
		table.insert(equipped, order[index])
	end
	state.equipped = equipped
	return true, { multiplier = Sim.multiplier(state), count = #equipped }
end

--: Duplicates into shards. A pet you already have is worth its tier's power in
--: shards, so feeding the ladder scales with the ladder.
function Sim.release(state: State, uid: string): (boolean, any)
	local pet = state.pets[uid]
	if not pet then
		return false, "no such pet"
	end
	for _, held in state.equipped do
		if held == uid then
			return false, "that one is out with you"
		end
	end
	local worth = math.max(1, math.floor(Sim.power(pet)))
	state.pets[uid] = nil
	state.shards += worth
	return true, { shards = worth, total = state.shards }
end

function Sim.buySlot(state: State): (boolean, any)
	if state.slots >= Sim.MAX_SLOTS then
		return false, "every slot is open"
	end
	local cost = Sim.slotCost(state.slots)
	if state.coins < cost then
		return false, "not enough for another slot"
	end
	state.coins -= cost
	state.slots += 1
	return true, { slots = state.slots, spent = cost }
end

function Sim.unlockZone(state: State): (boolean, any)
	local next = state.unlocked + 1
	if next > Sim.ZONES then
		return false, "there is nowhere further"
	end
	local toll = Sim.zoneToll(next)
	if state.coins < toll then
		return false, "not enough to get in"
	end
	state.coins -= toll
	state.unlocked = next
	state.zone = next
	return true, { zone = next, spent = toll }
end

function Sim.travel(state: State, zone: number): (boolean, any)
	if zone < 1 or zone > state.unlocked then
		return false, "you have not opened that one"
	end
	state.zone = zone
	return true, { zone = zone }
end

function Sim.rebirth(state: State): (boolean, any)
	local cost = Sim.rebirthCost(state.rebirths)
	if state.earned < cost then
		return false, "not enough earned yet"
	end
	--: The book survives, and so do the shards. Everything else goes back.
	local seen, shards, rebirths = state.seen, state.shards, state.rebirths + 1
	local hatched, broken = state.hatched, state.broken
	local blank = Sim.blank()
	for key, value in blank do
		state[key] = value
	end
	state.seen, state.shards, state.rebirths = seen, shards, rebirths
	state.hatched, state.broken = hatched, broken
	return true, { rebirths = rebirths, bonus = Sim.rebirthBonus(rebirths) }
end

-- ================================ reporting =================================
function Sim.owned(state: State): number
	local n = 0
	for _ in state.pets do
		n += 1
	end
	return n
end

function Sim.collected(state: State): number
	local n = 0
	for _ in state.seen do
		n += 1
	end
	return n
end

--: How long the next thing is away, in crates. The single most useful number
--: in a game like this and the one nobody ever shows: it turns "expensive" into
--: "ninety more".
function Sim.cratesTo(state: State, cost: number): number
	local per = math.max(1, math.floor(Sim.crateValue(state.zone)
		* Sim.multiplier(state) * Sim.rebirthBonus(state.rebirths)))
	return math.max(0, math.ceil((cost - state.coins) / per))
end

return Sim
