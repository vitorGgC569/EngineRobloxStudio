--[[
	Content — the single source of truth for every number and every name.

	Two kinds of number live here and they are labelled differently:

	  MEASURED   taken from a running engine or a solved pacing table
	  ESTIMATE   chosen by hand for feel; not yet simulated

	Nothing in this file may be duplicated in a service. A service that
	contains a balance number is a service whose balance cannot be audited.

	The pacing was designed against the genre's observed shape (Anime Card
	Clash: 16.5 min average session, 97.5% rating): a free first summon, a
	second summon inside the first minute, and a first ascension inside a
	play session. Exact targets below are ESTIMATE until validated by a
	headless simulation run.
]]

local Content = {}

Content.title = "AURA RIFT"
Content.tagline = "Summon auras. Climb the Infinite Tower."

-- ============================== rarities ====================================
--: Weights are per 10,000. Sum must be exactly 10,000 (asserted below).
Content.rarities = {
	{ id = "common", name = "COMMON", order = 1, weight = 4200, color = Color3.fromRGB(168, 172, 184) },
	{ id = "rare", name = "RARE", order = 2, weight = 2700, color = Color3.fromRGB(86, 156, 255) },
	{ id = "epic", name = "EPIC", order = 3, weight = 1700, color = Color3.fromRGB(186, 118, 255) },
	{ id = "legendary", name = "LEGENDARY", order = 4, weight = 900, color = Color3.fromRGB(255, 190, 72) },
	{ id = "mythic", name = "MYTHIC", order = 5, weight = 380, color = Color3.fromRGB(255, 84, 100) },
	{ id = "divine", name = "DIVINE", order = 6, weight = 110, color = Color3.fromRGB(110, 240, 255) },
	{ id = "transcendent", name = "TRANSCENDENT", order = 7, weight = 10, color = Color3.fromRGB(255, 130, 250) },
}

-- ================================ cards =====================================
--: Original characters in the genre's idiom. No licensed names — the game is
--: a shape of game, not a licence.
Content.cards = {
	-- common
	{ id = "dojo_initiate", name = "Dojo Initiate", rarity = 1, family = "Spirit" },
	{ id = "talisman_runner", name = "Talisman Runner", rarity = 1, family = "Spirit" },
	{ id = "bamboo_scout", name = "Bamboo Scout", rarity = 1, family = "Blade" },
	{ id = "street_brawler", name = "Street Brawler", rarity = 1, family = "Beast" },
	{ id = "teahouse_regular", name = "Teahouse Regular", rarity = 1, family = "Spirit" },
	{ id = "trail_student", name = "Trail Student", rarity = 1, family = "Storm" },
	{ id = "straw_trainee", name = "Straw Trainee", rarity = 1, family = "Beast" },
	{ id = "lantern_keeper", name = "Lantern Keeper", rarity = 1, family = "Spirit" },

	-- rare
	{ id = "kitsune_messenger", name = "Kitsune Messenger", rarity = 2, family = "Spirit" },
	{ id = "storm_apprentice", name = "Storm Apprentice", rarity = 2, family = "Storm" },
	{ id = "masked_ronin", name = "Masked Ronin", rarity = 2, family = "Blade" },
	{ id = "crane_duelist", name = "Crane Duelist", rarity = 2, family = "Blade" },
	{ id = "iron_fist", name = "Iron Fist Novice", rarity = 2, family = "Beast" },
	{ id = "shrine_guardian", name = "Shrine Guardian", rarity = 2, family = "Spirit" },
	{ id = "shadow_step", name = "Shadow Step", rarity = 2, family = "Void" },
	{ id = "tide_caller", name = "Tide Caller", rarity = 2, family = "Storm" },

	-- epic
	{ id = "thunder_fang", name = "Thunder Fang", rarity = 3, family = "Storm" },
	{ id = "sakura_blade", name = "Sakura Blade", rarity = 3, family = "Blade" },
	{ id = "mirror_sage", name = "Mirror Sage", rarity = 3, family = "Spirit" },
	{ id = "crimson_archer", name = "Crimson Archer", rarity = 3, family = "Crimson" },
	{ id = "wolf_alpha", name = "Wolf Pack Alpha", rarity = 3, family = "Beast" },
	{ id = "moonlight_dancer", name = "Moonlight Dancer", rarity = 3, family = "Void" },
	{ id = "ember_monk", name = "Ember Monk", rarity = 3, family = "Crimson" },
	{ id = "clockwork_ninja", name = "Clockwork Ninja", rarity = 3, family = "Void" },

	-- legendary
	{ id = "void_ripper", name = "Void Ripper", rarity = 4, family = "Void" },
	{ id = "phoenix_general", name = "Phoenix General", rarity = 4, family = "Crimson" },
	{ id = "oni_warlord", name = "Oni Warlord", rarity = 4, family = "Beast" },
	{ id = "star_weaver", name = "Star Weaver", rarity = 4, family = "Celestial" },
	{ id = "frost_monarch", name = "Frost Monarch", rarity = 4, family = "Storm" },
	{ id = "blade_saint", name = "Blade Saint", rarity = 4, family = "Blade" },
	{ id = "storm_empress", name = "Storm Empress", rarity = 4, family = "Storm" },

	-- mythic
	{ id = "abyss_sovereign", name = "Abyss Sovereign", rarity = 5, family = "Void" },
	{ id = "solar_samurai", name = "Solar Samurai", rarity = 5, family = "Celestial" },
	{ id = "chrono_assassin", name = "Chrono Assassin", rarity = 5, family = "Void" },
	{ id = "dragon_shogun", name = "Dragon Shogun", rarity = 5, family = "Beast" },
	{ id = "cursed_idol", name = "Cursed Idol", rarity = 5, family = "Crimson" },

	-- divine
	{ id = "celestial_dragon", name = "Celestial Dragon", rarity = 6, family = "Celestial" },
	{ id = "kami_of_the_rift", name = "Kami of the Rift", rarity = 6, family = "Spirit" },
	{ id = "infinite_sage", name = "Infinite Sage", rarity = 6, family = "Celestial" },

	-- transcendent
	{ id = "the_first_aura", name = "The First Aura", rarity = 7, family = "Celestial" },
	{ id = "zero_point_sensei", name = "Zero Point Sensei", rarity = 7, family = "Void" },
}

-- ============================ card power math ===============================
--: ESTIMATE. power(r) = 12 * 2.05^(r-1), income(r) = 3 * 2.3^(r-1).
Content.powerBase = 12
Content.powerGrowth = 2.05
Content.incomeBase = 3
Content.incomeGrowth = 2.3
--: Each duplicate past the first adds +5% to that card, capped at +200%.
Content.dupeBonusPerDup = 0.05
Content.dupeBonusCap = 2.0

-- ============================ account upgrades ==============================
Content.powerPerLevel = 0.12
Content.incomePerLevel = 0.15
Content.luckPerLevel = 0.08
Content.collectionIncomeBonusPerUnique = 0.01
Content.essenceMultiplierPer = 0.35

-- ================================ summoning =================================
Content.roll = {
	baseCost = 25,
	costGrowth = 1.17,
	--: The first summon is free. A player must see the reveal loop before
	--: they are asked to understand the economy.
	freeFirstRoll = true,
	pityThreshold = 40,
	pityMinRarity = 4,
	--: Rarities at or above this order are announced to the whole server.
	announceRarity = 6,
	startingRift = 150,
	startingGems = 10,
	gemRollCost = 25,
	gemRollMinRarity = 4,
	--: Batch summons are upgrades, in order.
	batches = {
		{ count = 1, upgrade = nil },
		{ count = 5, upgrade = "batch5" },
		{ count = 20, upgrade = "batch20" },
	},
}

-- ====================== repeatable upgrades and unlocks =====================
Content.upgrades = {
	{ id = "power", name = "Aura Power", desc = "+12% summon power per level", maxLevel = 40, baseCost = 120, growth = 1.5, icon = "combat.sword" },
	{ id = "income", name = "Rift Flow", desc = "+15% rift per second per level", maxLevel = 40, baseCost = 100, growth = 1.5, icon = "economy.coin" },
	{ id = "luck", name = "Fortune", desc = "+8% Legendary+ odds per level", maxLevel = 25, baseCost = 150, growth = 1.55, icon = "status.medal" },
	{ id = "batch5", name = "x5 Summon", desc = "Summon five auras at once", maxLevel = 1, baseCost = 2000, growth = 1, icon = "action.add" },
	{ id = "batch20", name = "x20 Summon", desc = "Summon twenty auras at once", maxLevel = 1, baseCost = 45000, growth = 1, icon = "action.add" },
	{ id = "autoroll", name = "Auto Summon", desc = "Summon again automatically while affordable", maxLevel = 1, baseCost = 5000, growth = 1, icon = "action.refresh" },
	{ id = "offline", name = "Dream Training", desc = "+2h offline earnings; base 4h", maxLevel = 4, baseCost = 800, growth = 2.2, icon = "status.timer" },
}

-- ============================== battle tower ================================
--: ESTIMATE. HP grows 28%/floor; rewards grow 35%/floor, so clearing floors
--: outruns summon cost (17%/roll) only while the player keeps upgrading.
Content.battle = {
	--: Floor 1 is 220 HP: a single Common card (12 power) clears it in
	--: ~18s of the 20s window. The first fight must be won or the tower
	--: teaches the player it is not for them.
	hpBase = 220,
	hpGrowth = 1.28,
	bossEvery = 10,
	bossMult = 5,
	timeLimit = 20,
	tickHz = 4,
	rewardBase = 60,
	rewardGrowth = 1.35,
	repeatReward = 0.35,
	gemEvery = 5,
	gemsPerClear = 2,
	--: Floors behind the best are replayable for reduced rewards.
	replayWindow = 4,
	critVariance = 0.15,
}

-- ================================ ascension =================================
Content.ascend = {
	firstFloor = 25,
	floorGrowth = 1.6,
	essenceBase = 3,
	essencePer25Floors = 1,
	essencePer8Uniques = 1,
}

-- =============================== daily gifts ================================
Content.daily = {
	cycleLength = 7,
	milestones = {
		[1] = { rift = 500 },
		[2] = { rift = 1500 },
		[3] = { gems = 5 },
		[4] = { rift = 6000 },
		[5] = { gems = 10 },
		[6] = { rift = 30000 },
		[7] = { gems = 25, rift = 100000 },
	},
}

-- ============================ offline earnings ==============================
Content.offline = {
	minSeconds = 600,
	relativeCapMultiple = 500,
	baseHours = 4,
	hoursPerLevel = 2,
}

-- =============================== derivations ================================
--: The derivations below are the only way a caller reaches the numbers above.

local rarityByOrder = {}
local cardById = {}
local drops = {}

for _, rarity in ipairs(Content.rarities) do
	rarityByOrder[rarity.order] = rarity
end

local weightSum = 0
for _, rarity in ipairs(Content.rarities) do
	weightSum += rarity.weight
end
assert(weightSum == 10000, string.format("[Content] rarity weights sum to %d, not 10000", weightSum))

for _, card in ipairs(Content.cards) do
	assert(cardById[card.id] == nil, "[Content] duplicate card id " .. card.id)
	assert(rarityByOrder[card.rarity] ~= nil, "[Content] card " .. card.id .. " has no rarity")
	cardById[card.id] = card
end

local upgradeById = {}
for _, upgrade in ipairs(Content.upgrades) do
	upgradeById[upgrade.id] = upgrade
end

function Content.rarityByOrder(order)
	return rarityByOrder[order]
end

function Content.card(cardId)
	return cardById[cardId]
end

function Content.upgrade(upgradeId)
	return upgradeById[upgradeId]
end

function Content.cardCount()
	return #Content.cards
end

function Content.dupeMultiplier(dupes)
	local capped = math.min(dupes, Content.dupeBonusCap / Content.dupeBonusPerDup)
	return 1 + Content.dupeBonusPerDup * capped
end

function Content.cardPower(cardId, dupes)
	local card = cardById[cardId]
	if card == nil then
		return 0
	end
	return Content.powerBase * Content.powerGrowth ^ (card.rarity - 1) * Content.dupeMultiplier(dupes or 0)
end

function Content.cardIncome(cardId, dupes)
	local card = cardById[cardId]
	if card == nil then
		return 0
	end
	return Content.incomeBase * Content.incomeGrowth ^ (card.rarity - 1) * Content.dupeMultiplier(dupes or 0)
end

--: Cost of the next single summon given how many the player has ever made.
function Content.rollCost(rolls)
	return math.floor(Content.roll.baseCost * Content.roll.costGrowth ^ rolls)
end

--: Sum of marginal prices for `count` consecutive summons.
function Content.rollCostSum(rolls, count)
	local total = 0
	for index = 0, count - 1 do
		if Content.roll.freeFirstRoll and rolls + index == 0 then
			continue
		end
		total += Content.rollCost(rolls + index)
	end
	return total
end

function Content.upgradeCost(upgradeId, level)
	local upgrade = upgradeById[upgradeId]
	if upgrade == nil then
		return math.huge
	end
	return math.floor(upgrade.baseCost * upgrade.growth ^ level)
end

--: The weighted drop pool CrateRoll and Luck consume. One entry per card;
--: every card inside a rarity is equally likely.
function Content.drops()
	local pool = {}
	for _, card in ipairs(Content.cards) do
		table.insert(pool, {
			id = card.id,
			weight = rarityByOrder[card.rarity].weight / 1000,
			rarity = card.rarity,
		})
	end
	return pool
end

function Content.floorHp(floor)
	local hp = Content.battle.hpBase * Content.battle.hpGrowth ^ (floor - 1)
	if Content.isBoss(floor) then
		hp *= Content.battle.bossMult
	end
	return hp
end

function Content.isBoss(floor)
	return floor % Content.battle.bossEvery == 0
end

function Content.floorReward(floor, firstClear)
	local reward = Content.battle.rewardBase * Content.battle.rewardGrowth ^ (floor - 1)
	if not firstClear then
		reward *= Content.battle.repeatReward
	end
	return reward
end

function Content.floorGems(floor)
	if floor % Content.battle.gemEvery ~= 0 then
		return 0
	end
	return Content.battle.gemsPerClear * math.max(1, math.floor(floor / Content.battle.gemEvery / 2))
end

function Content.ascendRequiredFloor(life)
	return math.floor(Content.ascend.firstFloor * Content.ascend.floorGrowth ^ life)
end

function Content.ascendEssenceGain(bestFloor, unique)
	return Content.ascend.essenceBase
		+ math.floor(bestFloor / Content.ascend.firstFloor) * Content.ascend.essencePer25Floors
		+ math.floor(unique / 8) * Content.ascend.essencePer8Uniques
end

function Content.offlineCapSeconds(offlineLevel)
	return (Content.offline.baseHours + Content.offline.hoursPerLevel * (offlineLevel or 0)) * 3600
end

function Content.equippedSlotsFor(bestFloor, life)
	local slots = 1
	if bestFloor >= 10 then
		slots += 1
	end
	if life >= 1 then
		slots += 1
	end
	return slots
end

function Content.dailyRewardText(reward)
	local parts = {}
	if reward.rift then
		table.insert(parts, "+" .. tostring(reward.rift) .. " Rift")
	end
	if reward.gems then
		table.insert(parts, "+" .. tostring(reward.gems) .. " Gems")
	end
	return table.concat(parts, "  ")
end

return Content
