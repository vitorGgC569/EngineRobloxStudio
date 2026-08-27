--!strict
--[[
	Scale — how big a thing of this kind should be, in studs.

	The problem
	-----------

	Asset packs share no unit. One models a sofa 271 units tall, another a fuel
	tank at 318, a third a whole castle at 4. Nothing about a mesh says what it
	is supposed to measure, and every marketplace normalises nothing, so a world
	assembled from several packs is a world where a chair is taller than a
	church.

	The fix is to declare a target height and scale each model to reach it. The
	question is where that number comes from.

	Why it is not measured
	----------------------

	It cannot be. Authored height is in the pack's own arbitrary unit, so
	measuring 295 models tells you the median tree is 4.2 *somethings*. There is
	no arithmetic from that to "a tree is about 34 studs" -- that is knowledge
	about trees, not about the file.

	Why it is not a table of topics
	-------------------------------

	The first version was: 67 topics, two numbers each, typed by hand. It worked
	and it does not survive twelve thousand models, because every new topic is a
	new row nobody writes and the fallback is one number for everything.

	So the knowledge lives in about a dozen **categories**, and topics are
	classified into them by name. `tree` and `dead oak tree` and `palm tree` are
	all foliage without anyone adding a row; an unrecognised topic lands on a
	neutral prop size rather than on nothing.

	The other half
	--------------

	Height alone is not enough, and the failure is spectacular: a bush modelled
	1 unit tall and 20 wide, scaled until it stands 5 studs, becomes 100 studs
	across. One of those filled a third of a frame and read as a hill.

	So a category also declares how wide a thing of its kind may be, as a
	multiple of its height, and whichever limit binds first wins. A squat model
	then stays squat rather than reaching its target height -- which is correct.
	The target says what a tree should measure, not that every model is
	tree-shaped.

		local Scale = Forge.Catalog.Scale
		local factor = Scale.factor("tree", authoredSize)
]]

local Scale = {}

export type Kind = {
	height: number,   -- studs, top to bottom
	spread: number,   -- how many times its height it may be wide
}

--[[
	The knowledge. Twelve rows, and adding a thirteenth is a real decision.

	Sized against a player who is about 5 studs tall and a world seen from a
	hillside, not against each other on a turntable.
]]
Scale.kinds = ({
	--: Carries the silhouette. At 24 studs a tree read as a shrub from the
	--: road; at 34 it reads as a tree.
	foliage = { height = 34, spread = 1.7 },
	undergrowth = { height = 4, spread = 3.2 },
	--: Rocks and logs. Wide is normal for these, so the clamp is loose.
	terrain = { height = 4.5, spread = 4 },

	--: Read from the far end of the map. The only reason to put one on a hill.
	landmark = { height = 105, spread = 2.4 },
	building = { height = 26, spread = 2.6 },

	--[[
		Built things, split four ways.

		These were one category called `structure` at twelve studs, and it made
		a fence as tall as a curtain wall and a road twelve studs thick. They
		share a material and nothing else: what separates them is what a person
		does with them -- walk along, be stopped by, pass through, walk on.
	]]
	--: Spans. The one kind allowed to be far wider than tall.
	span = { height = 12, spread = 6 },
	--: Stops you. Chest-high by definition, or it is a wall.
	barrier = { height = 5, spread = 5 },
	--: You pass through it, so it is sized against a person.
	opening = { height = 8, spread = 2 },
	--: You walk on it. Almost flat, and as wide as it needs to be.
	ground = { height = 1.5, spread = 20 },

	furniture = { height = 3.5, spread = 3.5 },
	--: Furniture you stand next to rather than sit on. A bookshelf sized as a
	--: chair is the giveaway that a category was doing two jobs.
	cabinet = { height = 7, spread = 2 },
	container = { height = 3.5, spread = 2.6 },
	machine = { height = 6, spread = 3.4 },
	--: Lamps, torches, braziers. Tall and thin by definition.
	light = { height = 11, spread = 1.6 },
	fixture = { height = 6, spread = 2.4 },

	handheld = { height = 3, spread = 4.5 },
	trinket = { height = 1.4, spread = 3 },

	prop = { height = 5, spread = 2.6 },
} :: any) :: { [string]: Kind }

--[[
	Topic name to category, by keyword, in order.

	Order is the whole design. `desk lamp` must meet `desk` before `lamp`, or a
	table lamp is built eleven studs tall; `watchtower` must meet `watchtower`
	before `tower`, or it is sized as a castle. Every pair below that looks
	redundant is there because one of them was wrong.

	Plain substrings, not patterns: Luau patterns have no alternation, so
	`(oak|pine)` is six literal characters that match nothing while looking
	like they should.
]]
local RULES: { { word: string, kind: string } } = {
	--: Specific before general, always.
	{ word = "desk lamp", kind = "furniture" },
	{ word = "watchtower", kind = "building" },
	{ word = "mine cart", kind = "machine" },
	{ word = "shooting target", kind = "fixture" },
	{ word = "grass patch", kind = "undergrowth" },
	{ word = "horror house", kind = "building" },

	{ word = "castle", kind = "landmark" },
	{ word = "fortress", kind = "landmark" },
	{ word = "cathedral", kind = "landmark" },
	{ word = "keep", kind = "landmark" },

	{ word = "tree", kind = "foliage" },
	{ word = "palm", kind = "foliage" },
	{ word = "pine", kind = "foliage" },
	{ word = "oak", kind = "foliage" },
	{ word = "bush", kind = "undergrowth" },
	{ word = "shrub", kind = "undergrowth" },
	{ word = "grass", kind = "undergrowth" },
	{ word = "flower", kind = "undergrowth" },
	{ word = "fern", kind = "undergrowth" },
	{ word = "reed", kind = "undergrowth" },
	{ word = "moss", kind = "undergrowth" },
	{ word = "vine", kind = "undergrowth" },
	{ word = "plant", kind = "undergrowth" },
	{ word = "mushroom", kind = "undergrowth" },

	{ word = "rock", kind = "terrain" },
	{ word = "boulder", kind = "terrain" },
	{ word = "stone", kind = "terrain" },
	{ word = "log", kind = "terrain" },
	{ word = "stump", kind = "terrain" },
	{ word = "ore", kind = "terrain" },

	{ word = "house", kind = "building" },
	{ word = "cabin", kind = "building" },
	{ word = "hut", kind = "building" },
	{ word = "barn", kind = "building" },
	{ word = "tower", kind = "building" },
	{ word = "church", kind = "building" },
	{ word = "mansion", kind = "building" },
	{ word = "building", kind = "building" },

	{ word = "wall", kind = "span" },
	{ word = "bridge", kind = "span" },
	{ word = "ruin", kind = "span" },
	{ word = "pillar", kind = "span" },
	{ word = "column", kind = "span" },

	{ word = "fence", kind = "barrier" },
	{ word = "gate", kind = "barrier" },
	{ word = "barricade", kind = "barrier" },
	{ word = "railing", kind = "barrier" },
	{ word = "hedge", kind = "barrier" },

	{ word = "door", kind = "opening" },
	{ word = "window", kind = "opening" },
	{ word = "ladder", kind = "opening" },
	{ word = "stair", kind = "opening" },
	{ word = "portal", kind = "opening" },
	{ word = "arch", kind = "opening" },

	{ word = "road", kind = "ground" },
	{ word = "path", kind = "ground" },
	{ word = "platform", kind = "ground" },
	{ word = "floor", kind = "ground" },
	{ word = "rug", kind = "ground" },
	{ word = "carpet", kind = "ground" },

	{ word = "chair", kind = "furniture" },
	{ word = "stool", kind = "furniture" },
	{ word = "table", kind = "furniture" },
	{ word = "desk", kind = "furniture" },
	{ word = "bed", kind = "furniture" },
	{ word = "sofa", kind = "furniture" },
	{ word = "couch", kind = "furniture" },
	{ word = "counter", kind = "furniture" },
	{ word = "bench", kind = "furniture" },

	{ word = "shelf", kind = "cabinet" },
	{ word = "bookcase", kind = "cabinet" },
	{ word = "cabinet", kind = "cabinet" },
	{ word = "wardrobe", kind = "cabinet" },
	{ word = "dresser", kind = "cabinet" },
	{ word = "locker", kind = "cabinet" },
	{ word = "refrigerator", kind = "cabinet" },
	{ word = "fridge", kind = "cabinet" },

	{ word = "barrel", kind = "container" },
	{ word = "crate", kind = "container" },
	{ word = "chest", kind = "container" },
	{ word = "coffin", kind = "container" },
	{ word = "sack", kind = "container" },
	{ word = "sandbag", kind = "container" },
	{ word = "ammo box", kind = "container" },
	{ word = "box", kind = "container" },

	{ word = "machine", kind = "machine" },
	{ word = "generator", kind = "machine" },
	{ word = "engine", kind = "machine" },
	{ word = "conveyor", kind = "machine" },
	{ word = "furnace", kind = "machine" },
	{ word = "dropper", kind = "machine" },
	{ word = "reactor", kind = "machine" },
	{ word = "turbine", kind = "machine" },
	{ word = "tank", kind = "machine" },
	{ word = "pipe", kind = "machine" },
	{ word = "cart", kind = "machine" },

	{ word = "lamp", kind = "light" },
	{ word = "lantern", kind = "light" },
	{ word = "torch", kind = "light" },
	{ word = "brazier", kind = "light" },
	{ word = "candle", kind = "trinket" },
	{ word = "campfire", kind = "fixture" },

	{ word = "sign", kind = "fixture" },
	{ word = "altar", kind = "fixture" },
	{ word = "anvil", kind = "fixture" },
	{ word = "statue", kind = "fixture" },
	{ word = "fountain", kind = "fixture" },
	{ word = "well", kind = "fixture" },
	{ word = "stand", kind = "fixture" },
	{ word = "trap", kind = "fixture" },
	{ word = "target", kind = "fixture" },
	{ word = "armor", kind = "fixture" },

	{ word = "sword", kind = "handheld" },
	{ word = "axe", kind = "handheld" },
	{ word = "dagger", kind = "handheld" },
	{ word = "pistol", kind = "handheld" },
	{ word = "rifle", kind = "handheld" },
	{ word = "gun", kind = "handheld" },
	{ word = "bow", kind = "handheld" },
	{ word = "shield", kind = "handheld" },
	{ word = "staff", kind = "handheld" },
	{ word = "wand", kind = "handheld" },
	{ word = "pickaxe", kind = "handheld" },
	{ word = "hammer", kind = "handheld" },
	{ word = "shovel", kind = "handheld" },

	{ word = "coin", kind = "trinket" },
	{ word = "gem", kind = "trinket" },
	{ word = "crystal", kind = "trinket" },
	{ word = "potion", kind = "trinket" },
	{ word = "egg", kind = "trinket" },
	{ word = "key", kind = "trinket" },
	{ word = "scroll", kind = "trinket" },
	{ word = "ring", kind = "trinket" },
	{ word = "rune", kind = "trinket" },
}

local cache: { [string]: string } = {}

--[[
	Which category a topic falls into.

	Two passes, and the order is the fix for a real bug.

	The first version matched rule words as plain substrings anywhere in the
	topic. `street lamp` came back as **foliage, thirty-four studs tall**,
	because `street` contains `tree`: s-TREE-t. Every lamp post in the village
	was built as an oak. The same trap is waiting in `crate`/`rate`,
	`shovel`/`hovel`, `barn`/`bar` -- substring matching over natural language
	finds words inside other words, and it does it silently.

	So pass one compares whole words. A topic is words separated by spaces, and
	`lamp` matching the word `lamp` is what was meant all along.

	Pass two falls back to substrings, because compound topics arrive welded:
	`watchtower`, `pinetree`, `lamppost`. It only runs when no whole word
	matched, so it can no longer outvote the obvious answer.

	Cached: this runs once per prop and a thousand-prop world would otherwise
	walk the list a thousand times for the same dozen answers.
]]
function Scale.classify(topic: string): string
	local known = cache[topic]
	if known then
		return known
	end
	local lowered = string.lower(topic)

	local words: { [string]: boolean } = {}
	for word in string.gmatch(lowered, "%a+") do
		words[word] = true
	end

	local found: string? = nil
	for _, rule in RULES do
		--: A multi-word rule is a phrase and can only be found by searching.
		if string.find(rule.word, " ", 1, true) then
			if string.find(lowered, rule.word, 1, true) then
				found = rule.kind
				break
			end
		elseif words[rule.word] then
			found = rule.kind
			break
		end
	end

	if not found then
		for _, rule in RULES do
			if string.find(lowered, rule.word, 1, true) then
				found = rule.kind
				break
			end
		end
	end

	cache[topic] = found or "prop"
	return cache[topic]
end

--: The target size for a topic. `override` lets a game disagree about one
--: thing without restating the other sixty-six.
function Scale.of(topic: string, override: { [string]: Kind }?): Kind
	local direct = if override then override[topic] else nil
	if direct then
		return direct
	end
	local kind = Scale.classify(topic)
	if override and override[kind] then
		return override[kind]
	end
	return Scale.kinds[kind] or Scale.kinds.prop
end

--[[
	How much to scale a model of this topic, given the box it arrived in.

	Both limits are applied and the smaller wins, so a model that is wide for
	its kind ends up shorter than the target rather than wider than the world.
]]
function Scale.factor(topic: string, size: Vector3, jitter: number?,
                      override: { [string]: Kind }?): number
	local kind = Scale.of(topic, override)
	local wanted = kind.height * (jitter or 1)

	local byHeight = if size.Y > 0.01 then wanted / size.Y else 1
	local widest = math.max(size.X, size.Z)
	local byWidth = if widest > 0.01
		then (wanted * kind.spread) / widest
		else byHeight
	return math.min(byHeight, byWidth)
end

function Scale.describe(): { [string]: any }
	return { kinds = Scale.kinds, rules = #RULES }
end

return Scale
