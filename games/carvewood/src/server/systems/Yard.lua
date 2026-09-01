--!strict
--[[
	Yard — one player's wood yard: the state, the rules, and nothing else.

	No Instances here. This module decides what a swing, a roll, a carve and a
	sale *mean*, and it does that against plain tables, so it can be reasoned
	about, saved, and played through without a world existing.

	Why growth is wall-clock
	------------------------

	A tree stores the moment it was planted, and readiness is arithmetic
	against `Yard.clock()`. Nothing ticks. That is what makes the yard grow
	while the player is away without a single line of offline-catch-up code:
	the answer to "is this tree ready" is the same question whether they were
	here for the wait or not.

	It also means the server cannot be tricked by a client that lies about
	elapsed time, because no client is ever asked.

	Why every action re-reads its own price
	---------------------------------------

	`plant` takes a species id, not a cost. `hire` takes nothing at all. The
	client says which thing; the server says what it costs and whether it is
	affordable. A payload carrying a price is a payload somebody will edit.

	What changed when the game grew up
	----------------------------------

	Four things that used to be one call each are now processes, and the state
	grew to match:

	  * **Felling is hits.** A plot carries `hp`, and `strike` takes it down.
	  * **Seeds are rolled, not bought.** `state.level` is gone; `state.seeds`
	    is a stock, and `plant` spends one.
	  * **Carvings have quality.** `state.carved` was a count per species;
	    `state.carvings` is a list, because two Oak pieces are no longer the
	    same object.
	  * **Selling is a shop.** Pieces go on stands at a price the player sets,
	    and customers decide. The counter survives as a 60% quick sale so that
	    nobody is ever stranded holding stock.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Trees = require(ReplicatedStorage.Shared.Trees)

local CrateRoll = Forge.Progression.CrateRoll
local UpgradeTree = Forge.Progression.UpgradeTree

local Yard = {}

--[[
	The clock, as a field rather than a call.

	Every readiness question here is arithmetic against wall-clock time, and a
	module that reaches for `os.time()` directly is a module whose rules cannot
	be exercised without waiting for them. Forty minutes of Starheart is not a
	test.

	Swapping this is how a whole session runs in a second. It is not a
	test-only hook bolted on afterwards: reading the clock through one named
	place is also the only way the yard can ever be replayed, audited, or run
	against a server clock that is not this machine's.
]]
Yard.clock = os.time

Yard.START_SLOTS = 3
Yard.MAX_SLOTS = 12
Yard.MAX_AXE = 8
Yard.MAX_CREW = 6

--: Logs the crew will not touch, so a player always has something to carve by
--: hand. See `crewTick` -- without this, hiring cancels the bench.
Yard.CREW_RESERVE = 6

-- ================================= quality ==================================
--[[
	What a carving is worth, relative to a Fine one.

	Rough is what the crew produces and nothing else does. Everything above it
	comes from a player's hands at the bench, which is the entire reason the
	minigame is worth playing and the entire reason hiring is still worth
	doing. See `systems/Carving`.
]]
Yard.QUALITY = {
	rough = { name = "Rough", multiplier = 0.7 },
	fine = { name = "Fine", multiplier = 1.0 },
	master = { name = "Masterwork", multiplier = 1.8 },
	flawless = { name = "Flawless", multiplier = 3.0 },
}
Yard.QUALITY_ORDER = { "rough", "fine", "master", "flawless" }

function Yard.multiplier(quality: string): number
	local entry = Yard.QUALITY[quality]
	return if entry then entry.multiplier else 1.0
end

--: What one piece is honestly worth. The player may ask any price; this is
--: what a customer measures that price against.
function Yard.fairPrice(speciesId: string, quality: string): number
	local species = Trees.get(speciesId)
	if not species then
		return 0
	end
	return math.floor(species.value * Yard.multiplier(quality))
end

-- ================================== prices ==================================
--[[
	Prices, as curves.

	Each is `base * growth^owned`, which is the shape every tycoon uses because
	it works: the first upgrade is impulsive, the fifth is a decision, and the
	tenth is a goal.
]]
function Yard.plotCost(owned: number): number
	return math.floor(60 * (2.35 ^ (owned - Yard.START_SLOTS)))
end

function Yard.axeCost(level: number): number
	return math.floor(90 * (2.1 ^ (level - 1)))
end

function Yard.crewCost(hired: number): number
	return math.floor(500 * (2.8 ^ hired))
end

--: A pack of seeds. Flat, and cheap enough that a player who has just sold
--: their first carving can afford one -- rolling is the loop, not the reward.
Yard.PACK_COST = 40

--[[
	How hard the axe bites.

	This used to multiply the *yield* of a chop, back when a chop was one call.
	Now that felling is a count of swings, the axe shortens that count instead,
	which is the number the player is actually watching go down.
]]
function Yard.axePower(level: number): number
	return 1 + (level - 1) * 0.6
end

function Yard.hitsToFell(speciesId: string, axe: number): number
	local species = Trees.get(speciesId)
	if not species then
		return 1
	end
	return math.max(1, math.ceil(species.toughness / Yard.axePower(axe)))
end

-- ================================ the shop ==================================
--[[
	The shop is an upgrade tree, and the tree's shape is the design.

	`counter` widens a floor and `floors` stacks another one on top, and
	`floors` roots on `counter` so the first thing a player does is fill the
	shelf they already have. Starting with two stands and one piece on display
	is the point: a customer walking in to buy your single Pine carving is the
	moment the shop becomes real, and it has to happen early.

	`Progression/UpgradeTree` owns the levels, the costs and the visibility;
	this only says what the nodes mean.
]]
Yard.SHOP_BASE_STANDS = 2
Yard.MAX_FLOORS = 5

Yard.shopTree = UpgradeTree.new({
	nodes = {
		counter = {
			maxLevel = 4,
			cost = function(level: number)
				return math.floor(150 * (2.6 ^ (level - 1)))
			end,
		},
		floors = {
			maxLevel = Yard.MAX_FLOORS - 1,
			roots = { "counter" },
			cost = function(level: number)
				return math.floor(900 * (3.4 ^ (level - 1)))
			end,
		},
		--: Footfall. Nothing else in the game raises how many customers arrive,
		--: so this is the node that turns a good shop into a busy one.
		signage = {
			maxLevel = 5,
			cost = function(level: number)
				return math.floor(220 * (2.4 ^ (level - 1)))
			end,
		},
		--: How much a customer is willing to pay over the odds. Cosmetic in
		--: name and the opposite in effect.
		decor = {
			maxLevel = 5,
			roots = { "signage" },
			cost = function(level: number)
				return math.floor(400 * (2.7 ^ (level - 1)))
			end,
		},
	},
})

export type Stand = { species: string, quality: string, price: number }

export type Shop = {
	upgrades: { [string]: number },
	stands: { [number]: Stand },
	takings: number,
}

function Yard.floors(shop: Shop): number
	return 1 + (shop.upgrades.floors or 0)
end

function Yard.standsPerFloor(shop: Shop): number
	return Yard.SHOP_BASE_STANDS + (shop.upgrades.counter or 0)
end

function Yard.standCount(shop: Shop): number
	return Yard.floors(shop) * Yard.standsPerFloor(shop)
end

--: Footfall multiplier and price tolerance, read by `Customers`.
function Yard.footfall(shop: Shop): number
	return 1 + (shop.upgrades.signage or 0) * 0.55
end

function Yard.appealBonus(shop: Shop): number
	return 1 + (shop.upgrades.decor or 0) * 0.09
end

-- ================================== state ===================================
export type Plot = { species: string?, plantedAt: number?, hp: number? }

export type Carving = { species: string, quality: string }

export type State = {
	cash: number,
	seeds: { [string]: number },
	essence: number,
	pity: number,
	slots: number,
	axe: number,
	crew: number,
	plots: { Plot },
	logs: { [string]: number },
	carvings: { Carving },
	shop: Shop,
	chopped: number,
	sold: number,
	rolled: number,
	lastSeen: number,
}

function Yard.blank(): State
	local plots = {}
	for index = 1, Yard.START_SLOTS do
		plots[index] = {}
	end
	return {
		--: Enough for a pack and a mistake. A tycoon that opens with an empty
		--: wallet opens with a wait, and the first thirty seconds are the only
		--: ones every player sees.
		cash = 60,
		--: Two Pines to start, so the first action is planting rather than
		--: rolling. A player whose first act is a gacha pull has not yet been
		--: shown what the seeds are for.
		seeds = { pine = 2 },
		essence = 0,
		pity = 0,
		slots = Yard.START_SLOTS,
		axe = 1,
		crew = 0,
		plots = plots,
		logs = {},
		carvings = {},
		shop = { upgrades = {}, stands = {}, takings = 0 },
		chopped = 0,
		sold = 0,
		rolled = 0,
		lastSeen = Yard.clock(),
	}
end

--[[
	Fill in whatever a saved table is missing, and carry old profiles forward.

	Saves outlive schemas. A profile written before `crew` existed must not
	crash the yard that reads it, and the failure mode without this is not a
	crash anyway -- it is `nil + 1`, three systems later, on a player who did
	nothing wrong.

	Two migrations matter here, because both replaced a field rather than adding
	one. A profile from before seeds were rolled has a `level`; it becomes the
	seeds that level implied, so the player keeps what they unlocked. A profile
	from before carvings had quality has `carved` as a count per species; each
	becomes that many Fine pieces, which is the grade the old flat value was.
]]
function Yard.reconcile(state: any): State
	local blank = Yard.blank()
	if type(state) ~= "table" then
		return blank
	end
	for key, value in blank do
		if state[key] == nil then
			state[key] = value
		end
	end
	if type(state.plots) ~= "table" then
		state.plots = blank.plots
	end
	for index = 1, state.slots do
		if type(state.plots[index]) ~= "table" then
			state.plots[index] = {}
		end
	end
	for index = state.slots + 1, #state.plots do
		state.plots[index] = nil
	end
	if type(state.logs) ~= "table" then state.logs = {} end

	--: `level` -> `seeds`. Everything the old ladder had unlocked becomes
	--: stock, so nobody loses a Legendary they paid for.
	if type(state.seeds) ~= "table" then state.seeds = {} end
	if type(state.level) == "number" then
		for index = 1, math.min(state.level, #Trees.species) do
			local species = Trees.species[index]
			state.seeds[species.id] = (state.seeds[species.id] or 0) + 2
		end
		state.level = nil
	end

	--: `carved` counts -> `carvings` list, at Fine, which is what the flat old
	--: value actually was.
	if type(state.carvings) ~= "table" then state.carvings = {} end
	if type(state.carved) == "table" then
		for id, count in state.carved do
			if Trees.get(id) then
				for _ = 1, math.min(tonumber(count) or 0, 200) do
					table.insert(state.carvings, { species = id, quality = "fine" })
				end
			end
		end
		state.carved = nil
	end

	if type(state.shop) ~= "table" then
		state.shop = { upgrades = {}, stands = {}, takings = 0 }
	end
	if type(state.shop.upgrades) ~= "table" then state.shop.upgrades = {} end
	if type(state.shop.stands) ~= "table" then state.shop.stands = {} end
	if type(state.shop.takings) ~= "number" then state.shop.takings = 0 end
	--: A shop that shrank because an upgrade was refunded must not keep
	--: displaying on stands that no longer exist.
	local count = Yard.standCount(state.shop)
	for index in state.shop.stands do
		if index > count then
			state.shop.stands[index] = nil
		end
	end
	return state
end

-- ================================== growth ==================================
function Yard.ready(plot: Plot, now: number?): boolean
	if not plot.species or not plot.plantedAt then
		return false
	end
	local species = Trees.get(plot.species)
	if not species then
		return false
	end
	return (now or Yard.clock()) - plot.plantedAt >= species.seconds
end

function Yard.remaining(plot: Plot, now: number?): number
	if not plot.species or not plot.plantedAt then
		return 0
	end
	local species = Trees.get(plot.species)
	if not species then
		return 0
	end
	return math.max(0, species.seconds - ((now or Yard.clock()) - plot.plantedAt))
end

-- ================================== seeds ===================================
--[[
	One pack, one seed.

	`CrateRoll` carries the pity counter on the roller, and a roller built fresh
	per call would start every player at zero pity forever -- an unlucky streak
	that never ends because nothing remembers it. So the counter lives in the
	profile and is loaded into the roller and read back out around the roll.
]]
local roller = CrateRoll.new({
	drops = Trees.drops(),
	--: Twelve packs without a Rare guarantees one. Steep weights need a short
	--: leash or the tail is where players quit.
	pityThreshold = 12,
	minRarityForPity = 3,
})

function Yard.rollSeed(state: State, rng: () -> number): (boolean, any)
	if state.cash < Yard.PACK_COST then
		return false, string.format("a pack of seeds costs %d", Yard.PACK_COST)
	end
	state.cash -= Yard.PACK_COST
	state.rolled += 1

	roller.pityCounter = state.pity
	local drop = roller:roll(rng)
	state.pity = roller.pityCounter

	local species = Trees.get(drop.id)
	if not species then
		return false, "the pack was empty"
	end
	state.seeds[drop.id] = (state.seeds[drop.id] or 0) + 1
	--: Every pack also pays essence, so a run of Commons is progress toward
	--: choosing a species outright rather than a run of nothing.
	state.essence += species.essence
	return true, {
		species = species.id, name = species.name, rarity = species.rarity,
		tier = species.tier, essence = species.essence,
	}
end

--: Essence buys a named seed. This is the floor under the gacha: a player who
--: rolls badly for an hour still arrives at the thing they wanted.
function Yard.convert(state: State, speciesId: string): (boolean, any)
	local species = Trees.get(speciesId)
	if not species then
		return false, "no such tree"
	end
	local cost = species.essence * 12
	if state.essence < cost then
		return false, string.format("%s costs %d essence", species.name, cost)
	end
	state.essence -= cost
	state.seeds[speciesId] = (state.seeds[speciesId] or 0) + 1
	return true, { species = speciesId, spent = cost }
end

function Yard.convertCost(speciesId: string): number
	local species = Trees.get(speciesId)
	return if species then species.essence * 12 else math.huge
end

-- ================================= planting =================================
function Yard.plant(state: State, index: number, speciesId: string): (boolean, any)
	local plot = state.plots[index]
	if not plot then
		return false, "that plot is not yours yet"
	end
	if plot.species then
		return false, "something is already growing there"
	end
	local species = Trees.get(speciesId)
	if not species then
		return false, "no such tree"
	end
	--: Seeds, not cash. The only gate on planting a Celestial is having rolled
	--: one, which is what makes the roll matter.
	local have = state.seeds[speciesId] or 0
	if have <= 0 then
		return false, "you have no " .. species.name .. " seeds"
	end
	state.seeds[speciesId] = have - 1
	if state.seeds[speciesId] <= 0 then
		state.seeds[speciesId] = nil
	end
	plot.species = speciesId
	plot.plantedAt = Yard.clock()
	plot.hp = nil
	return true, { species = speciesId, seconds = species.seconds }
end

-- ================================= chopping =================================
--[[
	One swing.

	The client says "I swung at plot 3" and nothing else. Reach, cooldown and
	power are read here from state the server owns, because a payload carrying
	damage is a payload somebody will edit.
]]
function Yard.strike(state: State, index: number, now: number?): (boolean, any)
	local plot = state.plots[index]
	if not plot or not plot.species then
		return false, "nothing to chop"
	end
	if not Yard.ready(plot, now) then
		return false, string.format("still growing -- %ds left",
			math.ceil(Yard.remaining(plot, now)))
	end
	local species = Trees.get(plot.species)
	if not species then
		plot.species, plot.plantedAt, plot.hp = nil, nil, nil
		return false, "that tree is gone"
	end

	--: Health is created on the first swing rather than at planting, so a tree
	--: that was planted before the axe existed still fells correctly.
	plot.hp = (plot.hp or species.toughness) - Yard.axePower(state.axe)
	if plot.hp > 0 then
		return true, {
			species = species.id, felled = false,
			hp = plot.hp, max = species.toughness,
		}
	end

	local yield = species.logs
	state.logs[species.id] = (state.logs[species.id] or 0) + yield
	state.chopped += yield
	plot.species, plot.plantedAt, plot.hp = nil, nil, nil
	return true, {
		species = species.id, felled = true, logs = yield, hp = 0,
		max = species.toughness,
	}
end

--: The whole tree at once, for the crew and for the simulation. The same rule
--: as `strike`, without the swings -- so a test can fell a Starheart without
--: pretending to press a button twenty-eight times.
function Yard.chop(state: State, index: number): (boolean, any)
	local plot = state.plots[index]
	if not plot or not plot.species then
		return false, "nothing to chop"
	end
	if not Yard.ready(plot) then
		return false, "still growing"
	end
	local species = Trees.get(plot.species)
	if not species then
		plot.species, plot.plantedAt, plot.hp = nil, nil, nil
		return false, "that tree is gone"
	end
	state.logs[species.id] = (state.logs[species.id] or 0) + species.logs
	state.chopped += species.logs
	plot.species, plot.plantedAt, plot.hp = nil, nil, nil
	return true, { species = species.id, logs = species.logs }
end

-- ================================== carving =================================
--: Which log a bench would reach for when nothing is chosen: the most valuable
--: on the pile, because that is what a player would have picked and nobody
--: enjoys sorting.
function Yard.bestLog(state: State): string?
	local best, bestValue = nil, -1
	for candidate, count in state.logs do
		local species = Trees.get(candidate)
		if species and count > 0 and species.value > bestValue then
			best, bestValue = candidate, species.value
		end
	end
	return best
end

function Yard.takeLog(state: State, speciesId: string): boolean
	local have = state.logs[speciesId] or 0
	if have <= 0 then
		return false
	end
	state.logs[speciesId] = have - 1
	if state.logs[speciesId] <= 0 then
		state.logs[speciesId] = nil
	end
	return true
end

--[[
	A log becomes a piece, at a grade.

	The grade is the *only* thing the bench minigame decides, and it is decided
	server-side from the timing of the strokes -- see `systems/Carving`. Passing
	it in here keeps this module ignorant of how it was earned, which is what
	lets the crew hand in Rough through the same door.
]]
function Yard.carveInto(state: State, speciesId: string?, quality: string): (boolean, any)
	local id = speciesId or Yard.bestLog(state)
	if not id then
		return false, "no logs to carve"
	end
	if not Yard.QUALITY[quality] then
		quality = "rough"
	end
	if not Yard.takeLog(state, id) then
		return false, "no logs of that kind"
	end
	table.insert(state.carvings, { species = id, quality = quality })
	return true, { species = id, quality = quality,
		value = Yard.fairPrice(id, quality) }
end

--: The old one-call carve, kept for the crew and the simulation. Rough, always
--: -- which is the decision that keeps both the minigame and hiring worth it.
function Yard.carve(state: State, speciesId: string?): (boolean, any)
	return Yard.carveInto(state, speciesId, "rough")
end

-- ================================== selling =================================
--[[
	The counter, at a discount.

	Selling everything at once is what the game used to be, and it has to keep
	working: a player with no shop, or with full stands, must never be stuck
	holding stock they cannot turn into money. But it pays 60%, so the shop is
	always the better answer and the counter is the impatient one.
]]
Yard.QUICK_SALE = 0.6

function Yard.sell(state: State): (boolean, any)
	if #state.carvings <= 0 then
		return false, "nothing carved to sell"
	end
	local earned, pieces = 0, 0
	for _, carving in state.carvings do
		earned += Yard.fairPrice(carving.species, carving.quality)
		pieces += 1
	end
	earned = math.floor(earned * Yard.QUICK_SALE)
	table.clear(state.carvings)
	state.cash += earned
	state.sold += pieces
	return true, { earned = earned, pieces = pieces, quick = true }
end

-- ============================== the shop floor ==============================
function Yard.stock(state: State, standIndex: number, carvingIndex: number,
                    price: number): (boolean, any)
	local shop = state.shop
	if standIndex < 1 or standIndex > Yard.standCount(shop) then
		return false, "that display does not exist yet"
	end
	if shop.stands[standIndex] then
		return false, "that display is already full"
	end
	local carving = state.carvings[carvingIndex]
	if not carving then
		return false, "no such carving"
	end
	local fair = Yard.fairPrice(carving.species, carving.quality)
	--: A price is clamped rather than refused. Somebody will type 1 and
	--: somebody will type a billion, and both should land on a number the
	--: customer rules can actually reason about.
	local asked = math.clamp(math.floor(tonumber(price) or fair),
		math.max(1, math.floor(fair * 0.25)), math.floor(fair * 4))
	table.remove(state.carvings, carvingIndex)
	shop.stands[standIndex] = {
		species = carving.species, quality = carving.quality, price = asked,
	}
	return true, { stand = standIndex, price = asked, fair = fair }
end

function Yard.unstock(state: State, standIndex: number): (boolean, any)
	local stand = state.shop.stands[standIndex]
	if not stand then
		return false, "nothing on that display"
	end
	state.shop.stands[standIndex] = nil
	table.insert(state.carvings,
		{ species = stand.species, quality = stand.quality })
	return true, { stand = standIndex }
end

function Yard.setPrice(state: State, standIndex: number, price: number): (boolean, any)
	local stand = state.shop.stands[standIndex]
	if not stand then
		return false, "nothing on that display"
	end
	local fair = Yard.fairPrice(stand.species, stand.quality)
	stand.price = math.clamp(math.floor(tonumber(price) or fair),
		math.max(1, math.floor(fair * 0.25)), math.floor(fair * 4))
	return true, { stand = standIndex, price = stand.price }
end

--: A customer bought it. Not a player action, so it takes no reason string --
--: it is called by `Customers` once the valuation has already said yes.
function Yard.completeSale(state: State, standIndex: number, paid: number): (boolean, any)
	local stand = state.shop.stands[standIndex]
	if not stand then
		return false, "nothing on that display"
	end
	state.shop.stands[standIndex] = nil
	state.cash += paid
	state.shop.takings += paid
	state.sold += 1
	return true, { stand = standIndex, paid = paid, species = stand.species,
		quality = stand.quality }
end

function Yard.buyUpgrade(state: State, nodeId: string): (boolean, any)
	if not Yard.shopTree.nodes[nodeId] then
		return false, "no such upgrade"
	end
	local ok, why = Yard.shopTree:canBuy(state.shop.upgrades, nodeId, state.cash)
	if not ok then
		if why == "cost" then
			return false, string.format("that costs %d",
				Yard.shopTree:cost(state.shop.upgrades, nodeId))
		elseif why == "maxed" then
			return false, "that is already at its limit"
		end
		return false, "build the counter out first"
	end
	local cost = Yard.shopTree:cost(state.shop.upgrades, nodeId)
	--[[
		`buy` is pure. It answers with a delta and changes nothing.

		Calling it and discarding the answer -- which is what this did --
		charged the player and left the level where it was. They paid 150 for a
		shelf that never appeared, and the panel showed the cash leaving, so
		the only visible symptom was a number going down. A live scenario found
		it in a millisecond; eight rounds of screenshots had not.
	]]
	local delta = Yard.shopTree:buy(state.shop.upgrades, nodeId)
	if not delta then
		return false, "that upgrade is not available"
	end
	state.shop.upgrades[delta.id] = delta.level
	state.cash -= cost
	return true, { node = nodeId, level = state.shop.upgrades[nodeId],
		spent = cost }
end

-- ================================ customers =================================
--[[
	What one customer thinks a piece is worth.

	Pure, and deliberately so: willingness is the number the whole shop economy
	turns on, and it has to be answerable in a simulation without an NPC, a
	navigator or a frame -- the same way the rest of this module was played
	through before a Part existed.

	`taste` is the rarity tier this customer came looking for. Distance from it
	costs, but never to zero: somebody who wanted a Legendary will still buy a
	good Pine, just not for Legendary money.
]]
export type Customer = {
	budget: number,
	taste: number,
	generosity: number,
	patience: number,
}

function Yard.valuation(customer: Customer, stand: Stand, shop: Shop?): number
	local species = Trees.get(stand.species)
	if not species then
		return 0
	end
	local fair = Yard.fairPrice(stand.species, stand.quality)
	--[[
		Wanting something rarer disappoints; finding something rarer does not.

		A symmetric penalty made a customer who came in for a Legendary refuse a
		fairly-priced Oak outright -- which meant a new player, whose shop holds
		nothing but Commons, watched most of their footfall walk out. Missing
		*up* still costs, because they wanted better; missing *down* barely
		does, because nobody is annoyed to be offered something nicer.
	]]
	local gap = species.tier - customer.taste
	local distance = if gap < 0 then -gap * 0.15 else gap * 0.05
	local taste = 1 / (1 + distance)
	local decor = if shop then Yard.appealBonus(shop) else 1
	return fair * taste * customer.generosity * decor
end

Yard.BUY_AT = 0.80
Yard.HAGGLE_AT = 1.25
Yard.HAGGLE_OFFER = 0.85

--[[
	Buy, haggle, or walk.

	Walking away is information -- a shop that sells nothing is telling the
	player their price is wrong -- so "no" is a real outcome here rather than a
	retry.
]]
function Yard.decide(customer: Customer, stand: Stand, shop: Shop?): (string, number)
	local willing = Yard.valuation(customer, stand, shop)
	if stand.price > customer.budget then
		return "afford", 0
	end
	if stand.price <= willing * Yard.BUY_AT then
		return "buy", stand.price
	end
	if stand.price <= willing * Yard.HAGGLE_AT then
		return "haggle", math.max(1, math.floor(willing * Yard.HAGGLE_OFFER))
	end
	return "leave", 0
end

-- ================================== upkeep ==================================
function Yard.buyPlot(state: State): (boolean, any)
	if state.slots >= Yard.MAX_SLOTS then
		return false, "the yard is full"
	end
	local cost = Yard.plotCost(state.slots)
	if state.cash < cost then
		return false, string.format("a new plot costs %d", cost)
	end
	state.cash -= cost
	state.slots += 1
	state.plots[state.slots] = {}
	return true, { slots = state.slots, spent = cost }
end

function Yard.buyAxe(state: State): (boolean, any)
	if state.axe >= Yard.MAX_AXE then
		return false, "your axe is as sharp as it gets"
	end
	local cost = Yard.axeCost(state.axe)
	if state.cash < cost then
		return false, string.format("the next axe costs %d", cost)
	end
	state.cash -= cost
	state.axe += 1
	return true, { axe = state.axe, spent = cost }
end

function Yard.hire(state: State): (boolean, any)
	if state.crew >= Yard.MAX_CREW then
		return false, "the crew is full"
	end
	local cost = Yard.crewCost(state.crew)
	if state.cash < cost then
		return false, string.format("hiring costs %d", cost)
	end
	state.cash -= cost
	state.crew += 1
	return true, { crew = state.crew, spent = cost }
end

-- =================================== crew ===================================
--[[
	What the crew did while a second passed.

	They fell ready trees slowly and they carve, and everything they carve is
	Rough. Both halves are deliberate.

	Felling used to be one call, so a crew that did not chop cost the player
	nothing. Now that a Starheart is twenty-eight swings, a crew that does not
	chop means an idle yard fills with grown trees and stops earning -- which
	would undo the offline-growth promise the whole game is built on. So they
	chop, at a fraction of the rate a player with an axe manages.

	And they only ever produce Rough. A crew that made Masterworks would make
	the bench pointless; a crew that made nothing would make hiring pointless.
	Rough keeps both worth doing.
]]
function Yard.crewTick(state: State, seconds: number): (number, number)
	if state.crew <= 0 then
		return 0, 0
	end
	local carved, felled = 0, 0

	--: One tree every twenty seconds per employee, regardless of species. Slow
	--: enough that swinging the axe yourself is always faster.
	local fellBudget = state.crew * seconds * 0.05
	while fellBudget >= 1 do
		local target = nil
		for index = 1, state.slots do
			local plot = state.plots[index]
			if plot and plot.species and Yard.ready(plot) then
				target = index
				break
			end
		end
		if not target then
			break
		end
		local ok = Yard.chop(state, target)
		if not ok then
			break
		end
		fellBudget -= 1
		felled += 1
	end

	--[[
		The crew leaves a reserve, and that is not a nicety.

		Simulated at forty minutes, two employees and a sharp axe earned 23%
		more than a bare yard -- for an investment of thousands. The reason was
		here: the crew carves once a second each and had eaten the whole log
		pile as Rough before the player's hands reached it. Every Masterwork
		the bench could have produced was pre-empted by an employee making the
		worst grade in the game.

		So they only ever work the overflow. Below the reserve the pile is the
		player's, which is what makes hiring relief rather than replacement.
	]]
	local logs = Yard.counts(state)
	local carveBudget = math.min(state.crew * seconds * 0.5,
		math.max(0, logs - Yard.CREW_RESERVE))
	while carveBudget >= 1 do
		local ok = Yard.carve(state)
		if not ok then
			break
		end
		carveBudget -= 1
		carved += 1
	end
	return carved, felled
end

-- ================================ reporting =================================
function Yard.counts(state: State): (number, number)
	local logs = 0
	for _, count in state.logs do
		logs += count
	end
	return logs, #state.carvings
end

function Yard.seedCount(state: State): number
	local total = 0
	for _, count in state.seeds do
		total += count
	end
	return total
end

--: The whole yard, shaped for drawing. One call rather than an attribute per
--: plot: the shape changes only when a player acts, and the hot numbers travel
--: as attributes instead.
function Yard.snapshot(state: State): { [string]: any }
	local now = Yard.clock()
	local plots = {}
	for index = 1, state.slots do
		local plot = state.plots[index] or {}
		local species = plot.species and Trees.get(plot.species) or nil
		plots[index] = {
			species = plot.species,
			name = species and species.name or nil,
			ready = Yard.ready(plot, now),
			remaining = Yard.remaining(plot, now),
			total = species and species.seconds or 0,
			hp = plot.hp,
			hits = if species
				then Yard.hitsToFell(species.id, state.axe) else nil,
		}
	end

	local carvings = {}
	for index, carving in state.carvings do
		local species = Trees.get(carving.species)
		carvings[index] = {
			species = carving.species,
			name = species and species.name or carving.species,
			quality = carving.quality,
			qualityName = Yard.QUALITY[carving.quality].name,
			value = Yard.fairPrice(carving.species, carving.quality),
		}
	end

	local stands = {}
	for index = 1, Yard.standCount(state.shop) do
		local stand = state.shop.stands[index]
		if stand then
			local species = Trees.get(stand.species)
			stands[index] = {
				species = stand.species,
				name = species and species.name or stand.species,
				quality = stand.quality,
				qualityName = Yard.QUALITY[stand.quality].name,
				price = stand.price,
				fair = Yard.fairPrice(stand.species, stand.quality),
			}
		else
			stands[index] = false
		end
	end

	local upgrades = {}
	for id in Yard.shopTree.nodes do
		local level = Yard.shopTree:levelOf(state.shop.upgrades, id)
		local ok = Yard.shopTree:canBuy(state.shop.upgrades, id, state.cash)
		upgrades[id] = {
			level = level,
			max = Yard.shopTree.nodes[id].maxLevel,
			cost = Yard.shopTree:cost(state.shop.upgrades, id),
			visible = Yard.shopTree:visible(state.shop.upgrades, id),
			affordable = ok,
		}
	end

	local seeds = {}
	for _, species in Trees.species do
		local held = state.seeds[species.id] or 0
		seeds[species.id] = {
			held = held,
			name = species.name,
			rarity = species.rarity,
			tier = species.tier,
			seconds = species.seconds,
			value = species.value,
			hits = Yard.hitsToFell(species.id, state.axe),
			essence = Yard.convertCost(species.id),
		}
	end

	local logCount, carvedCount = Yard.counts(state)
	return {
		cash = state.cash, essence = state.essence, slots = state.slots,
		axe = state.axe, crew = state.crew, pity = state.pity,
		plots = plots, logs = state.logs, carvings = carvings,
		seeds = seeds, seedCount = Yard.seedCount(state),
		stands = stands, standCount = Yard.standCount(state.shop),
		floors = Yard.floors(state.shop),
		standsPerFloor = Yard.standsPerFloor(state.shop),
		upgrades = upgrades, takings = state.shop.takings,
		logCount = logCount, carvedCount = carvedCount,
		chopped = state.chopped, sold = state.sold, rolled = state.rolled,
		packCost = Yard.PACK_COST,
		plotCost = if state.slots < Yard.MAX_SLOTS
			then Yard.plotCost(state.slots) else nil,
		axeCost = if state.axe < Yard.MAX_AXE
			then Yard.axeCost(state.axe) else nil,
		crewCost = if state.crew < Yard.MAX_CREW
			then Yard.crewCost(state.crew) else nil,
	}
end

return Yard
