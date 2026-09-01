--!strict
--[[
	Theme — everything about this game that is not the game.

	This file is the parameter. Swap it and the same machine ships as anime
	capsules, dragon eggs, car crates or trading-card packs, which is how this
	entire genre reproduces itself on Roblox: the loop is identical and the
	fantasy is not.

	The rule that makes the swap safe
	---------------------------------

	**A theme supplies names, art and copy. It never supplies a number that the
	balance depends on.** Power, drop weight, cost and pity all live in `Sim`,
	keyed by rarity tier. A theme says "tier 5 is called a Void Drake and looks
	like this"; it cannot say how strong a Void Drake is.

	Without that rule the second theme is a rebalance, the third is a rewrite,
	and the machine was never a machine. With it, a new theme is a list of
	names and a palette, and it cannot break anything.

	What a theme must provide
	-------------------------

	  * a name for the currency and the thing you collect
	  * `pets[tier]` -- at least one name per rarity tier, in ladder order
	  * `eggs[i]` -- a name per egg tier the machine defines
	  * `zones[i]` -- a name per zone the machine defines
	  * a palette and the catalogue topics its art comes from

	`Theme.check` fails loudly at boot if any of that is short, because a theme
	with four pet names for seven tiers produces a game whose top three rarities
	are nameless and which nobody notices until somebody hatches one.
]]

local Theme = {}

Theme.id = "pets"
Theme.title = "Hatchling"
Theme.tagline = "Hatch it. Grow it. Fill the book."

--: What the player earns and what they break to earn it.
Theme.currency = { name = "Coins", short = "c", icon = "economy.coin" }
Theme.premium = { name = "Gems", short = "g", icon = "economy.gem" }
Theme.collectible = { noun = "crate", verb = "Break", icon = "economy.chest" }

--[[
	The creatures, by rarity tier.

	Ordered lists, one per tier, indexed by the ladder in `Sim.RARITIES`. More
	than one name in a tier means more than one creature can drop there, which
	is what makes a collection index worth filling.

	`topic` is what the model catalogue is asked for. A theme that names a topic
	the catalogue does not hold falls back to a tinted primitive rather than to
	nothing -- see `Hatch.model`.
]]
Theme.pets = {
	{ -- 1 Common
		{ id = "pup", name = "Pup", topic = "monster" },
		{ id = "kitten", name = "Kitten", topic = "monster" },
		{ id = "chick", name = "Chick", topic = "egg" },
	},
	{ -- 2 Uncommon
		{ id = "fox", name = "Fox Kit", topic = "monster" },
		{ id = "bunny", name = "Lop Bunny", topic = "monster" },
	},
	{ -- 3 Rare
		{ id = "wolf", name = "Frost Wolf", topic = "monster" },
		{ id = "owl", name = "Ember Owl", topic = "monster" },
	},
	{ -- 4 Epic
		{ id = "griffin", name = "Griffin", topic = "monster" },
		{ id = "turtle", name = "Ancient Turtle", topic = "monster" },
	},
	{ -- 5 Legendary
		{ id = "drake", name = "Emberdrake", topic = "monster" },
		{ id = "unicorn", name = "Starmane", topic = "monster" },
	},
	{ -- 6 Mythic
		{ id = "phoenix", name = "Phoenix", topic = "monster" },
	},
	{ -- 7 Secret
		{ id = "void", name = "Voidwyrm", topic = "monster" },
	},
}

--: One per egg tier the machine defines. The machine decides what each costs
--: and how its drop table leans; this decides what it is called.
Theme.eggs = {
	{ name = "Cracked Egg", topic = "egg" },
	{ name = "Forest Egg", topic = "egg" },
	{ name = "Frozen Egg", topic = "egg" },
	{ name = "Ember Egg", topic = "egg" },
	{ name = "Celestial Egg", topic = "egg" },
	{ name = "Void Egg", topic = "egg" },
}

--: One per zone. The machine decides what each costs to enter and how much its
--: crates are worth.
Theme.zones = {
	{ name = "Meadow", ground = Color3.fromRGB(126, 186, 92),
	  crate = Color3.fromRGB(178, 138, 92), prop = "bush" },
	{ name = "Deep Wood", ground = Color3.fromRGB(84, 138, 82),
	  crate = Color3.fromRGB(132, 104, 74), prop = "tree" },
	{ name = "Frostfell", ground = Color3.fromRGB(206, 222, 232),
	  crate = Color3.fromRGB(148, 178, 198), prop = "rock" },
	{ name = "Emberwaste", ground = Color3.fromRGB(176, 106, 74),
	  crate = Color3.fromRGB(120, 68, 52), prop = "rock" },
	{ name = "Skyreach", ground = Color3.fromRGB(148, 176, 226),
	  crate = Color3.fromRGB(198, 206, 236), prop = "bush" },
	{ name = "The Void", ground = Color3.fromRGB(58, 48, 78),
	  crate = Color3.fromRGB(96, 74, 128), prop = "rock" },
}

--: The look. Read by the interface and by the world dresser; nothing here
--: touches a rule.
Theme.palette = {
	sky = Color3.fromRGB(150, 198, 236),
	accent = Color3.fromRGB(255, 186, 64),
	rare = Color3.fromRGB(120, 176, 246),
}

--[[
	A theme is checked at boot, not trusted.

	The failure this prevents is silent and late: a theme one name short means
	the rarest creature in the game has no name, and the only way to find out is
	to hatch one, which by construction almost never happens.
]]
function Theme.check(tiers: number, eggTiers: number, zones: number): (boolean, string?)
	if #Theme.pets < tiers then
		return false, string.format("theme '%s' names %d rarity tiers, the machine has %d",
			Theme.id, #Theme.pets, tiers)
	end
	for tier, list in Theme.pets do
		if #list < 1 then
			return false, string.format("rarity tier %d has no creature in it", tier)
		end
	end
	if #Theme.eggs < eggTiers then
		return false, string.format("theme names %d eggs, the machine has %d tiers",
			#Theme.eggs, eggTiers)
	end
	if #Theme.zones < zones then
		return false, string.format("theme names %d zones, the machine has %d",
			#Theme.zones, zones)
	end
	return true, nil
end

--: Every creature, flattened, with its tier attached. The index screen and the
--: drop tables both want this shape and neither should have to build it.
function Theme.roster(): { { id: string, name: string, topic: string, tier: number } }
	local out = {}
	for tier, list in Theme.pets do
		for _, pet in list do
			table.insert(out, { id = pet.id, name = pet.name,
				topic = pet.topic, tier = tier })
		end
	end
	return out
end

local byId: { [string]: any } = {}
for _, pet in Theme.roster() do
	byId[pet.id] = pet
end

function Theme.pet(id: string): any?
	return byId[id]
end

return Theme
