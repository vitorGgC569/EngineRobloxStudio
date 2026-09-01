--!strict
--[[
	Trees — what you plant, how long it takes, and what it is worth.

	The whole game is this table. Everything else is the machinery that lets a
	player interact with it, so the numbers here are the design and the rest is
	plumbing.

	How the curve is shaped
	-----------------------

	Each tier roughly triples in value and roughly doubles in growth time. That
	gap is deliberate and it is the engine of the loop: a rarer tree is always
	worth the wait *per slot*, so the interesting decision is never "which tree
	is best" -- it is "how many slots do I have, and can I afford to tie one up
	for eleven minutes".

	`seed` is what a plot costs to plant; `logs` is what chopping yields;
	`value` is what one carved piece sells for. A tree therefore returns
	`logs * value` against `seed`, and the ratio widens with tier so that
	progress feels like acceleration rather than a longer grind.

	Growth is wall-clock and it continues while the player is away. That is the
	promise the original makes on its store page -- "your wood yard grows trees
	offline" -- and it is the reason a session can be five minutes long and
	still feel worth opening.
]]

local Trees = {}

export type Species = {
	id: string,
	name: string,
	rarity: string,    -- the tier's name, for display
	tier: number,      -- 1 Common .. 7 Celestial; what a roll compares against
	weight: number,    -- roll weight; falls off hard with tier
	essence: number,   -- what a duplicate is worth, and what buying one costs
	seconds: number,   -- wall-clock growth
	toughness: number, -- axe hits to fell at power 1
	logs: number,      -- logs yielded when felled
	value: number,     -- cash for one Fine carving
	colour: Color3,    -- canopy, for the grown tree
	trunk: Color3,
	topic: string,     -- what to fetch from the model catalogue
}

--[[
	Seven rarities, and the ladder is the whole progression now.

	Species used to be unlocked in a line by spending cash, and `tier` was just
	its index. Seeds are rolled now, so `tier` is a rarity a roll can be
	compared against and `weight` is how often it comes up. `CrateRoll` reads
	both directly.

	The weights fall off by roughly 3x a tier. That is steep enough that a
	Celestial is a story and shallow enough that pity -- one high roll every
	twelve packs -- actually reaches it.
]]
Trees.RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary",
	"Mythic", "Celestial" }

--: Ordered by tier. Index is the tier, and several systems rely on that --
--: unlock levels, the shop's ordering, the rarity of a random drop.
Trees.species = ({
	{
		id = "pine", name = "Pine", rarity = "Common", tier = 1,
		weight = 1000, essence = 2,
		seconds = 20, toughness = 3, logs = 2, value = 8,
		colour = Color3.fromRGB(86, 132, 74), trunk = Color3.fromRGB(104, 78, 52),
		topic = "tree",
	},
	{
		id = "birch", name = "Birch", rarity = "Common", tier = 1,
		weight = 720, essence = 3,
		seconds = 45, toughness = 4, logs = 3, value = 18,
		colour = Color3.fromRGB(126, 168, 92), trunk = Color3.fromRGB(214, 208, 190),
		topic = "tree",
	},
	{
		id = "oak", name = "Oak", rarity = "Uncommon", tier = 2,
		weight = 340, essence = 8,
		seconds = 90, toughness = 6, logs = 4, value = 46,
		colour = Color3.fromRGB(72, 116, 60), trunk = Color3.fromRGB(92, 66, 44),
		topic = "tree",
	},
	{
		id = "maple", name = "Maple", rarity = "Rare", tier = 3,
		weight = 118, essence = 22,
		seconds = 180, toughness = 8, logs = 5, value = 128,
		colour = Color3.fromRGB(198, 96, 58), trunk = Color3.fromRGB(96, 64, 46),
		topic = "tree",
	},
	{
		id = "ebony", name = "Ebony", rarity = "Epic", tier = 4,
		weight = 40, essence = 60,
		seconds = 360, toughness = 11, logs = 6, value = 380,
		colour = Color3.fromRGB(58, 52, 66), trunk = Color3.fromRGB(38, 34, 40),
		topic = "tree",
	},
	{
		id = "amberheart", name = "Amberheart", rarity = "Legendary", tier = 5,
		weight = 13, essence = 170,
		seconds = 660, toughness = 15, logs = 8, value = 1150,
		colour = Color3.fromRGB(226, 168, 72), trunk = Color3.fromRGB(122, 82, 40),
		topic = "tree",
	},
	{
		id = "duskthorn", name = "Duskthorn", rarity = "Mythic", tier = 6,
		weight = 4, essence = 460,
		seconds = 1200, toughness = 20, logs = 10, value = 3400,
		colour = Color3.fromRGB(138, 74, 158), trunk = Color3.fromRGB(52, 38, 60),
		topic = "tree",
	},
	{
		--: The top of the ladder, and deliberately absurd. A player who rolls
		--: one should be able to tell from across the map -- which is what the
		--: glow in `Timber` is for.
		id = "starheart", name = "Starheart", rarity = "Celestial", tier = 7,
		weight = 1, essence = 1300,
		seconds = 2400, toughness = 28, logs = 14, value = 11000,
		colour = Color3.fromRGB(140, 214, 236), trunk = Color3.fromRGB(196, 206, 226),
		topic = "tree",
	},
} :: any) :: { Species }

local byId: { [string]: Species } = {}
local order: { [string]: number } = {}
for index, species in Trees.species do
	byId[species.id] = species
	order[species.id] = index
end

function Trees.get(id: string): Species?
	return byId[id]
end

--: The rarity tier, which is a property of the species and no longer its
--: position in the list. Two Commons share tier 1; the list order is only how
--: they are displayed.
function Trees.tier(id: string): number
	local species = byId[id]
	return if species then species.tier else 1
end

function Trees.order(id: string): number
	return order[id] or 1
end

--[[
	The roll table, straight out of the species list.

	`Trees.unlocked(level)` used to live here and gated planting on a cash-bought
	level. Nothing gates planting now except owning a seed, so the list a player
	can plant from is their own stock and this is what fills it.

	`CrateRoll.Drop` is `{ id, weight, rarity }` exactly, so this needs no
	adapting on the way in.
]]
function Trees.drops(): { { id: string, weight: number, rarity: number } }
	local out = {}
	for _, species in Trees.species do
		table.insert(out, { id = species.id, weight = species.weight,
			rarity = species.tier })
	end
	return out
end

--: What one full cycle of this species pays, ignoring time. The shop shows it
--: because "seed 1500, value 380" is two numbers a player has to multiply, and
--: a shop that makes you do arithmetic is a shop that gets skipped.
function Trees.yield(species: Species): number
	return species.logs * species.value
end

--: Cash per second if the slot were worked perfectly. This is the number that
--: actually orders the species, and it is not the same order as `value`.
function Trees.rate(species: Species): number
	return Trees.yield(species) / species.seconds
end

function Trees.describe(): { [string]: any }
	local rows = {}
	for tier, species in Trees.species do
		rows[species.id] = {
			tier = species.tier, order = tier, yield = Trees.yield(species),
			perSecond = math.round(Trees.rate(species) * 100) / 100,
		}
	end
	return rows
end

return Trees
