--!strict
--[[
	FishCatalog — every fish in the game and where it lives.

	Each species is data and only data: the roll that picks it lives in Roll,
	the card that draws it lives on the client, and neither knows the other.
	Adding a fish is adding a row here; nothing else has to change, which is
	the only way a catalogue this size stays maintainable.

	`tags` tilt the odds rather than gating the fish. A `night` fish can still
	take a bait at noon -- it is just three times as likely after dusk. Gating
	reads as a bug to a player who did everything right; tilting reads as
	knowledge, and knowledge is the thing a bestiary rewards.
]]

local FishCatalog = {}

-- ================================= rarities =================================
--: `weight` is the base draw; `luckBias` is how hard a lucky rod pulls this
--: tier up. Commons barely move, mythics move a lot, which is the shape every
--: fishing game converges on for a reason: luck should shorten the tail, not
--: delete it.
FishCatalog.rarities = {
	{ id = "common", name = "Common", order = 1, weight = 100, xpBonus = 6, luckBias = 0.0, color = Color3.fromRGB(178, 186, 196) },
	{ id = "uncommon", name = "Uncommon", order = 2, weight = 38, xpBonus = 18, luckBias = 0.03, color = Color3.fromRGB(126, 214, 138) },
	{ id = "rare", name = "Rare", order = 3, weight = 12, xpBonus = 55, luckBias = 0.07, color = Color3.fromRGB(90, 168, 240) },
	{ id = "epic", name = "Epic", order = 4, weight = 4.2, xpBonus = 140, luckBias = 0.12, color = Color3.fromRGB(176, 115, 240) },
	{ id = "legendary", name = "Legendary", order = 5, weight = 1.4, xpBonus = 380, luckBias = 0.2, color = Color3.fromRGB(240, 200, 96) },
	{ id = "mythic", name = "Mythic", order = 6, weight = 0.45, xpBonus = 900, luckBias = 0.3, color = Color3.fromRGB(255, 95, 122) },
}

FishCatalog.rarityById = {}
for _, tier in FishCatalog.rarities do
	FishCatalog.rarityById[tier.id] = tier
end

-- ================================= species ==================================
--: cclass picks the emblem the catch card draws: fish | eel | ray | shark |
--: squid | crab | jelly | legend.
FishCatalog.species = {
	-- ------------------------- Saltwind Shallows -------------------------
	{ id = "minnow", name = "Speckled Minnow", zone = "shallows", rarity = "common", cclass = "fish", minKg = 0.2, maxKg = 1.4, value = 7,
		blurb = "Small, quick, and endlessly forgiving. It is the first fish of most stories." },
	{ id = "perch", name = "Greenback Perch", zone = "shallows", rarity = "common", cclass = "fish", minKg = 0.4, maxKg = 2.8, value = 10,
		blurb = "Holds the green of the shallows so well that anglers miss it in the net." },
	{ id = "ruffe", name = "Striped Ruffe", zone = "shallows", rarity = "common", cclass = "fish", minKg = 0.2, maxKg = 1.9, value = 9,
		blurb = "Its stripes darken with the tide, and old sailors say that means weather." },
	{ id = "flounder", name = "Sandy Flounder", zone = "shallows", rarity = "common", cclass = "ray", minKg = 0.8, maxKg = 4.6, value = 15,
		blurb = "Half fish, half seafloor. You usually see it only after the hook does." },
	{ id = "mackerel", name = "Harbor Mackerel", zone = "shallows", rarity = "common", cclass = "fish", minKg = 1.2, maxKg = 5.8, value = 19,
		blurb = "Runs in tight silver crowds beneath every working dock in the world." },
	{ id = "herring", name = "Silver Herring", zone = "shallows", rarity = "uncommon", cclass = "fish", minKg = 0.3, maxKg = 2.2, value = 60, tags = { night = 2.4 },
		blurb = "Only shows its silver when the sun is down. Some say it is hiding from mirrors." },
	{ id = "bream", name = "Copper Bream", zone = "shallows", rarity = "uncommon", cclass = "fish", minKg = 1.6, maxKg = 6.8, value = 72,
		blurb = "Tastes of the salt it grew in. The market knows the difference." },
	{ id = "gar", name = "Dusk Gar", zone = "shallows", rarity = "uncommon", cclass = "eel", minKg = 2.2, maxKg = 9.5, value = 84, tags = { night = 2.2 },
		blurb = "A long low shadow that patrols the grass flats after sundown." },
	{ id = "bass", name = "Sunspine Bass", zone = "shallows", rarity = "rare", cclass = "fish", minKg = 3.0, maxKg = 15.0, value = 340, tags = { day = 2.4 },
		blurb = "Its dorsal spines catch light like a weather vane catches wind." },
	{ id = "saltray", name = "Saltflat Ray", zone = "shallows", rarity = "epic", cclass = "ray", minKg = 8.0, maxKg = 44.0, value = 1250,
		blurb = "Glides over sand like a rumour of something much larger." },
	{ id = "snapper", name = "Gilded Snapper", zone = "shallows", rarity = "legendary", cclass = "fish", minKg = 9.0, maxKg = 52.0, value = 3600, tags = { day = 1.6 },
		blurb = "Wears its weight in gold. The first trophy most crews remember." },
	{ id = "coelacanth", name = "Elder Coelacanth", zone = "shallows", rarity = "mythic", cclass = "legend", minKg = 40.0, maxKg = 120.0, value = 11000, tags = { night = 3.0, storm = 3.0 },
		blurb = "Declared extinct twice. It has read the papers and disagrees." },

	-- --------------------------- Kelp Hollow -----------------------------
	{ id = "anchovy", name = "Kelp Anchovy", zone = "kelp", rarity = "common", cclass = "fish", minKg = 0.2, maxKg = 1.3, value = 11,
		blurb = "Their schools move through the kelp like weather moves through wheat." },
	{ id = "wrasse", name = "Frond Wrasse", zone = "kelp", rarity = "common", cclass = "fish", minKg = 0.5, maxKg = 3.2, value = 14,
		blurb = "Sleeps buried in fronds at night, wakes up hungry at first light." },
	{ id = "ling", name = "Hollow Ling", zone = "kelp", rarity = "common", cclass = "eel", minKg = 1.0, maxKg = 5.4, value = 17,
		blurb = "Weaves between the stalks so tightly that the weed seems to move itself." },
	{ id = "grouper", name = "Mottled Grouper", zone = "kelp", rarity = "common", cclass = "fish", minKg = 2.5, maxKg = 12.0, value = 27,
		blurb = "All shoulders. It does not flee so much as refuse to be moved." },
	{ id = "mullet", name = "Grey Mullet", zone = "kelp", rarity = "common", cclass = "fish", minKg = 1.4, maxKg = 7.2, value = 22,
		blurb = "Eats anything, fears nothing, and is never where you cast." },
	{ id = "ribboneel", name = "Ribbon Eel", zone = "kelp", rarity = "uncommon", cclass = "eel", minKg = 1.5, maxKg = 7.6, value = 96, tags = { night = 2.3 },
		blurb = "A bright green question mark unspooling from a hole in the reef." },
	{ id = "jadesnap", name = "Jadescale Snapper", zone = "kelp", rarity = "uncommon", cclass = "fish", minKg = 3.0, maxKg = 14.0, value = 120,
		blurb = "Scales like cut stone. Divers say the reef grows them, not the fish." },
	{ id = "cardinal", name = "Lantern Cardinal", zone = "kelp", rarity = "uncommon", cclass = "fish", minKg = 0.4, maxKg = 2.4, value = 135, tags = { night = 2.6 },
		blurb = "A small night lamp of a fish. The kelp leans toward it when it passes." },
	{ id = "vray", name = "Verdant Ray", zone = "kelp", rarity = "rare", cclass = "ray", minKg = 8.0, maxKg = 38.0, value = 420,
		blurb = "Its back is a kelp forest in miniature; the trick has saved it often." },
	{ id = "stalker", name = "Hollow Stalker", zone = "kelp", rarity = "epic", cclass = "angler", minKg = 14.0, maxKg = 62.0, value = 1600, tags = { night = 2.2 },
		blurb = "The light it carries is patient, and the dark it keeps is not." },
	{ id = "monarch", name = "Kelp Monarch", zone = "kelp", rarity = "legendary", cclass = "fish", minKg = 14.0, maxKg = 70.0, value = 4400,
		blurb = "Where it swims the canopy bends and stays bent for a while." },
	{ id = "vleviathan", name = "Verdant Leviathan", zone = "kelp", rarity = "mythic", cclass = "legend", minKg = 70.0, maxKg = 210.0, value = 13500, tags = { night = 2.4, rain = 2.6 },
		blurb = "Gardeners of the deep weed. The hollow is their garden and their crown." },

	-- --------------------------- Coral Steps -----------------------------
	{ id = "damsel", name = "Candy Damsel", zone = "coral", rarity = "common", cclass = "fish", minKg = 0.2, maxKg = 1.1, value = 13,
		blurb = "Bright, bold, and territorial about a patch of coral the size of a boot." },
	{ id = "goby", name = "Coral Goby", zone = "coral", rarity = "common", cclass = "fish", minKg = 0.2, maxKg = 0.9, value = 12,
		blurb = "Spends its whole life within sight of the coral it was born under." },
	{ id = "parrot", name = "Parrot Wrasse", zone = "coral", rarity = "common", cclass = "fish", minKg = 0.8, maxKg = 4.4, value = 21,
		blurb = "Chews coral into sand. Every white beach started as one of its meals." },
	{ id = "tilegrouper", name = "Tile Grouper", zone = "coral", rarity = "common", cclass = "fish", minKg = 3.0, maxKg = 14.0, value = 33,
		blurb = "Better camouflage than most of the reef that it is hiding against." },
	{ id = "bandedserge", name = "Banded Sergeant", zone = "coral", rarity = "common", cclass = "fish", minKg = 0.3, maxKg = 1.8, value = 16,
		blurb = "Five stripes, endless attitude. Guards a territory no one else wants." },
	{ id = "anthia", name = "Clown Anthia", zone = "coral", rarity = "uncommon", cclass = "fish", minKg = 0.6, maxKg = 3.4, value = 130, tags = { day = 2.3 },
		blurb = "Descends from the light in streams, as if colour could be rained." },
	{ id = "moray", name = "Porcelain Moray", zone = "coral", rarity = "uncommon", cclass = "eel", minKg = 3.0, maxKg = 15.0, value = 165,
		blurb = "White as a teacup until it decides otherwise. Teeth by prior arrangement." },
	{ id = "bubblecrab", name = "Bubble Coral Crab", zone = "coral", rarity = "uncommon", cclass = "crab", minKg = 1.2, maxKg = 6.8, value = 180,
		blurb = "Wears a living coral hat. The hat gets a share of every meal." },
	{ id = "prismtang", name = "Prism Tang", zone = "coral", rarity = "rare", cclass = "fish", minKg = 2.0, maxKg = 11.0, value = 480, tags = { day = 2.5 },
		blurb = "Turns sunlight into small rainbows along the terrace walls." },
	{ id = "dragonet", name = "Terrace Dragonet", zone = "coral", rarity = "epic", cclass = "fish", minKg = 4.0, maxKg = 20.0, value = 1850, tags = { day = 2.2 },
		blurb = "Walks the steps on fins like hands, and wears more colours than it needs." },
	{ id = "lionfish", name = "Crowned Lionfish", zone = "coral", rarity = "legendary", cclass = "fish", minKg = 6.0, maxKg = 28.0, value = 5200,
		blurb = "A floating crown with a very clear opinion about being touched." },
	{ id = "emperor", name = "Prismatic Emperor", zone = "coral", rarity = "mythic", cclass = "legend", minKg = 30.0, maxKg = 95.0, value = 16000, tags = { day = 2.6 },
		blurb = "The reef's wardrobe: it swims through light and leaves colour behind." },

	-- ------------------------- Stormbreak Shelf --------------------------
	{ id = "squallherring", name = "Squall Herring", zone = "storm", rarity = "common", cclass = "fish", minKg = 0.4, maxKg = 2.6, value = 18,
		blurb = "Arrives with the front and leaves with it. Locals set their watches by it." },
	{ id = "slat", name = "Grey Slat", zone = "storm", rarity = "common", cclass = "fish", minKg = 3.0, maxKg = 16.0, value = 31,
		blurb = "Flat, dour, and too stubborn to be bothered by rough water." },
	{ id = "barracuda", name = "Windcut Barracuda", zone = "storm", rarity = "common", cclass = "fish", minKg = 5.0, maxKg = 24.0, value = 39,
		blurb = "Hangs in the current like a knife on a wall, and is just as patient." },
	{ id = "pollock", name = "Brine Pollock", zone = "storm", rarity = "common", cclass = "fish", minKg = 4.0, maxKg = 19.0, value = 35,
		blurb = "The shelf's working class. It has never once been surprised." },
	{ id = "slatemack", name = "Slate Mackerel", zone = "storm", rarity = "common", cclass = "fish", minKg = 2.5, maxKg = 12.0, value = 28,
		blurb = "Painted in the exact grey of the weather it swims under." },
	{ id = "halibut", name = "Trawler Halibut", zone = "storm", rarity = "uncommon", cclass = "ray", minKg = 9.0, maxKg = 48.0, value = 190,
		blurb = "Wide enough to feed a crew, patient enough to test one." },
	{ id = "raincod", name = "Rainrunner Cod", zone = "storm", rarity = "uncommon", cclass = "fish", minKg = 7.0, maxKg = 34.0, value = 225, tags = { rain = 2.8 },
		blurb = "Surfaces when rain starts in what can only be described as celebration." },
	{ id = "thundertuna", name = "Thunderfin Tuna", zone = "storm", rarity = "uncommon", cclass = "shark", minKg = 16.0, maxKg = 78.0, value = 280, tags = { storm = 3.0, rain = 2.0 },
		blurb = "Runs with the squall line. Sounds like applause when a school passes." },
	{ id = "marlin", name = "Mastcracker Marlin", zone = "storm", rarity = "rare", cclass = "shark", minKg = 40.0, maxKg = 160.0, value = 720, tags = { day = 2.0 },
		blurb = "Named for what it does to small boats' rigging when hooked by surprise." },
	{ id = "herald", name = "Storm Herald", zone = "storm", rarity = "epic", cclass = "shark", minKg = 90.0, maxKg = 320.0, value = 2900, tags = { storm = 3.2 },
		blurb = "It arrives before the storm does. Forecasters hate it and rely on it." },
	{ id = "gale", name = "Gale Swordfish", zone = "storm", rarity = "legendary", cclass = "shark", minKg = 55.0, maxKg = 210.0, value = 6800, tags = { day = 2.0 },
		blurb = "The shelf's oldest duel. Every scratch on it is a story with a survivor." },
	{ id = "serpent", name = "Tempest Serpent", zone = "storm", rarity = "mythic", cclass = "legend", minKg = 180.0, maxKg = 560.0, value = 20000, tags = { storm = 3.4, rain = 2.4 },
		blurb = "Sailors swear the lightning does not miss it; it simply refuses." },

	-- ---------------------------- Abyss Trench ---------------------------
	{ id = "grenadier", name = "Pale Grenadier", zone = "abyss", rarity = "common", cclass = "fish", minKg = 1.5, maxKg = 8.5, value = 24, tags = { night = 2.0 },
		blurb = "Pallid as paper and twice as patient. Eats whatever the dark forgets." },
	{ id = "trenchshrimp", name = "Trench Shrimp", zone = "abyss", rarity = "common", cclass = "crab", minKg = 0.3, maxKg = 1.8, value = 21,
		blurb = "Cleaner of the trench floor. It has seen everything and repeats nothing." },
	{ id = "glasseye", name = "Glasseye Fang", zone = "abyss", rarity = "common", cclass = "fish", minKg = 2.0, maxKg = 11.0, value = 32, tags = { night = 2.2 },
		blurb = "Eyes like headlamps and a mouth lined with the answers." },
	{ id = "anglerjelly", name = "Angler Jelly", zone = "abyss", rarity = "common", cclass = "jelly", minKg = 0.8, maxKg = 5.5, value = 27, tags = { night = 2.4 },
		blurb = "A lantern with no ship attached, drifting down where light went to retire." },
	{ id = "blindsole", name = "Blind Sole", zone = "abyss", rarity = "common", cclass = "ray", minKg = 1.0, maxKg = 6.0, value = 25,
		blurb = "Gave up its eyes for the floor, and the floor keeps the trade." },
	{ id = "oilfish", name = "Oilfish Ghost", zone = "abyss", rarity = "uncommon", cclass = "fish", minKg = 6.0, maxKg = 30.0, value = 260, tags = { night = 2.4 },
		blurb = "Grey and drifting, more apparition than animal, and slippery as a rumour." },
	{ id = "midnightsquid", name = "Midnight Squid", zone = "abyss", rarity = "uncommon", cclass = "squid", minKg = 4.0, maxKg = 24.0, value = 300, tags = { night = 2.6 },
		blurb = "Its ink is darker than the water it hides in, which should be impossible." },
	{ id = "gulper", name = "Dumbo Gulper", zone = "abyss", rarity = "uncommon", cclass = "fish", minKg = 5.0, maxKg = 28.0, value = 330,
		blurb = "Fins like ears, a mouth like a business decision, and no size limit on ambition." },
	{ id = "sixgill", name = "Fangtooth Sixgill", zone = "abyss", rarity = "rare", cclass = "shark", minKg = 30.0, maxKg = 130.0, value = 880,
		blurb = "Older than trees. The trench keeps it as a souvenir of deeper eras." },
	{ id = "chimaera", name = "Abyssal Chimaera", zone = "abyss", rarity = "epic", cclass = "shark", minKg = 90.0, maxKg = 340.0, value = 3400, tags = { night = 2.2 },
		blurb = "Half shark, half ghost story, entirely uninterested in being catalogued." },
	{ id = "moonfish", name = "Ghost Moonfish", zone = "abyss", rarity = "legendary", cclass = "ray", minKg = 45.0, maxKg = 190.0, value = 8200, tags = { night = 2.6 },
		blurb = "Round, silver, and always where the surface light cannot follow to check." },
	{ id = "crownshark", name = "Abyssal Crownshark", zone = "abyss", rarity = "mythic", cclass = "legend", minKg = 380.0, maxKg = 980.0, value = 26000, tags = { night = 2.4, storm = 2.8 },
		blurb = "The trench does not have a king. The trench has a crown, and it swims." },
}

FishCatalog.byId = {}
FishCatalog.byZone = {}
for _, entry in FishCatalog.species do
	FishCatalog.byId[entry.id] = entry
	local list = FishCatalog.byZone[entry.zone]
	if not list then
		list = {}
		FishCatalog.byZone[entry.zone] = list
	end
	table.insert(list, entry)
end

function FishCatalog.total(): number
	return #FishCatalog.species
end

return FishCatalog
