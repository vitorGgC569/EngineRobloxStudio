local CardCatalog = {}

CardCatalog.Rarities = {
	Common = {order = 1, color = Color3.fromRGB(174, 188, 192), label = "COMMON"},
	Uncommon = {order = 2, color = Color3.fromRGB(105, 224, 156), label = "UNCOMMON"},
	Rare = {order = 3, color = Color3.fromRGB(71, 173, 255), label = "RARE"},
	Epic = {order = 4, color = Color3.fromRGB(184, 107, 255), label = "EPIC"},
	Legendary = {order = 5, color = Color3.fromRGB(242, 193, 83), label = "LEGENDARY"},
	Mythic = {order = 6, color = Color3.fromRGB(255, 113, 105), label = "MYTHIC"},
}

CardCatalog.Cards = {
	field_lantern = {
		id = "field_lantern",
		name = "Field Lantern",
		rarity = "Common",
		power = 4,
		effect = "Reveals nearby ore nodes.",
		effectStyle = "lantern",
		runtimeAssetId = nil,
		localPreviewPath = nil,
	},
	tunnel_mole = {
		id = "tunnel_mole",
		name = "Tunnel Mole",
		rarity = "Uncommon",
		power = 8,
		effect = "Dig actions recharge 5% faster.",
		effectStyle = "moss_sparks",
		runtimeAssetId = nil,
		localPreviewPath = nil,
	},
	mossback_badger_engineer = {
		id = "mossback_badger_engineer",
		name = "Mossback Badger",
		rarity = "Rare",
		power = 16,
		effect = "Reduces building costs by 5%.",
		effectStyle = "ore_sparks",
		runtimeAssetId = nil,
		localPreviewPath = "assets/generated/cards/mossback-badger-engineer-v1.png",
	},
	copper_lynx_prospector = {
		id = "copper_lynx_prospector",
		name = "Copper Lynx",
		rarity = "Epic",
		power = 24,
		effect = "Increases ore yield by 12%.",
		effectStyle = "copper_burst",
		runtimeAssetId = nil,
		localPreviewPath = "assets/generated/cards/copper-lynx-prospector-v1.png",
	},
	storm_raven_surveyor = {
		id = "storm_raven_surveyor",
		name = "Storm Raven",
		rarity = "Legendary",
		power = 36,
		effect = "Reveals the next objective on the ridge.",
		effectStyle = "storm_ring",
		runtimeAssetId = nil,
		localPreviewPath = "assets/generated/cards/storm-raven-surveyor-v1.png",
	},
	ridge_warden = {
		id = "ridge_warden",
		name = "Ridge Warden",
		rarity = "Mythic",
		power = 52,
		effect = "Adds 20% income on unlocked floors.",
		effectStyle = "crown_flare",
		runtimeAssetId = nil,
		localPreviewPath = nil,
	},
}

-- The collection.
--
-- Six cards -- one per rarity -- meant almost every pull returned something the
-- player already owned, which is why the belt felt empty. A collection needs
-- enough breadth per tier for a pull to be a question rather than a formality:
-- commons are plentiful, mythics are the long chase.
local function define(id, name, rarity, power, effect, effectStyle)
	CardCatalog.Cards[id] = {
		id = id,
		name = name,
		rarity = rarity,
		power = power,
		effect = effect,
		effectStyle = effectStyle,
		runtimeAssetId = nil,
		localPreviewPath = nil,
	}
end

-- Common: the working tools of the ridge.
define("pit_canary", "Pit Canary", "Common", 3, "Warns of unstable tunnels.", "lantern")
define("hand_auger", "Hand Auger", "Common", 4, "Small ore veins yield 2% more.", "ore_sparks")
define("dust_sifter", "Dust Sifter", "Common", 5, "Recovers 1% of spent currency.", "moss_sparks")
define("gravel_hound", "Gravel Hound", "Common", 5, "Finds shallow deposits faster.", "moss_sparks")
define("tin_whistle", "Tin Whistle", "Common", 4, "Shift changes come 3% sooner.", "lantern")
define("rope_ladder", "Rope Ladder", "Common", 3, "Descend one floor without a lift.", "lantern")

-- Uncommon: the first real advantages.
define("copper_drill", "Copper Drill", "Uncommon", 9, "Ore yield +4%.", "ore_sparks")
define("ember_moth", "Ember Moth", "Uncommon", 8, "Night shifts keep full output.", "lantern")
define("slate_terrier", "Slate Terrier", "Uncommon", 10, "Belt speed +5%.", "moss_sparks")
define("ridge_surveyor", "Ridge Surveyor", "Uncommon", 11, "Reveals one extra node per floor.", "ore_sparks")
define("brass_lantern", "Brass Lantern", "Uncommon", 9, "Light range +30%.", "lantern")

-- Rare: build-defining.
define("quartz_fox", "Quartz Fox", "Rare", 18, "Rare ore chance +6%.", "ore_sparks")
define("iron_marmot", "Iron Marmot", "Rare", 20, "Building costs -8%.", "moss_sparks")
define("thunder_shrike", "Thunder Shrike", "Rare", 19, "Belt luck +5%.", "storm_sparks")
define("deepvein_badger", "Deepvein Badger", "Rare", 22, "Deep floors yield +10%.", "ore_sparks")

-- Epic: the mid-game chase.
define("magma_lynx", "Magma Lynx", "Epic", 34, "Smelting is twice as fast.", "ore_sparks")
define("aurora_owl", "Aurora Owl", "Epic", 36, "Offline income +15%.", "storm_sparks")
define("cobalt_ram", "Cobalt Ram", "Epic", 38, "Floor upgrades cost -12%.", "moss_sparks")

-- Legendary: the ridge remembers these names.
define("stormvault_raven", "Stormvault Raven", "Legendary", 58, "Belt luck +15%.", "storm_sparks")
define("goldspire_stag", "Goldspire Stag", "Legendary", 62, "All income +20%.", "ore_sparks")

-- Mythic: the long chase.
define("obsidian_wyrm", "Obsidian Wyrm", "Mythic", 96, "All income +35% and belt luck +25%.", "storm_sparks")
define("ridgeheart", "Ridgeheart", "Mythic", 104, "Every floor counts as one deeper.", "ore_sparks")

CardCatalog.PackOrder = {
	"field_lantern",
	"tunnel_mole",
	"mossback_badger_engineer",
	"copper_lynx_prospector",
	"storm_raven_surveyor",
	"ridge_warden",
}

--- Duplicates are paid out rather than discarded: a pull that returns a card
--- the player owns must still be worth pulling, or the belt teaches them to
--- stop using it.
CardCatalog.DuplicateValue = {
	Common = 25,
	Uncommon = 70,
	Rare = 220,
	Epic = 850,
	Legendary = 3200,
	Mythic = 12000,
}

function CardCatalog.duplicateValue(cardId: string): number
	local card = CardCatalog.Cards[cardId]
	return CardCatalog.DuplicateValue[card and card.rarity or "Common"] or 25
end

--- How many cards exist at each rarity, for tuning and for the collection UI.
function CardCatalog.countByRarity(): { [string]: number }
	local counts = {}
	for _, card in pairs(CardCatalog.Cards) do
		counts[card.rarity] = (counts[card.rarity] or 0) + 1
	end
	return counts
end

function CardCatalog.total(): number
	local total = 0
	for _ in pairs(CardCatalog.Cards) do
		total += 1
	end
	return total
end

function CardCatalog.get(cardId)
	return CardCatalog.Cards[cardId]
end

function CardCatalog.rarity(cardId)
	local card = CardCatalog.get(cardId)
	return card and CardCatalog.Rarities[card.rarity] or CardCatalog.Rarities.Common
end

function CardCatalog.nextUnowned(ownedCards)
	local owned = {}
	for _, cardId in ipairs(ownedCards or {}) do
		owned[cardId] = true
	end
	for _, cardId in ipairs(CardCatalog.PackOrder) do
		if not owned[cardId] then
			return cardId
		end
	end
	return CardCatalog.PackOrder[1]
end

return CardCatalog
