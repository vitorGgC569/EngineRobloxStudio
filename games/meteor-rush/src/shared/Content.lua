--!strict
local Content = {}

Content.rarities = {
	[1] = { name = "Common", color = Color3.fromRGB(197, 184, 151) },
	[2] = { name = "Uncommon", color = Color3.fromRGB(100, 155, 91) },
	[3] = { name = "Rare", color = Color3.fromRGB(73, 139, 126) },
	[4] = { name = "Epic", color = Color3.fromRGB(200, 108, 59) },
	[5] = { name = "Legendary", color = Color3.fromRGB(243, 174, 48) },
	[6] = { name = "Cosmic", color = Color3.fromRGB(171, 66, 74) },
}

-- Meteor rarity is visible in the world before the player commits to a run.
-- Each row changes silhouette, scale, lifetime value and VFX rather than only
-- changing a label or color.
Content.meteors = {
	{
		id = "duststone", name = "Duststone", rarity = 1, weight = 50,
		scale = 0.88, fragments = 4, burstMultiplier = 1.0,
		rock = Color3.fromRGB(102, 91, 75), core = Color3.fromRGB(230, 178, 94),
		style = "stone",
	},
	{
		id = "ironfall", name = "Ironfall", rarity = 2, weight = 25,
		scale = 1.02, fragments = 5, burstMultiplier = 1.35,
		rock = Color3.fromRGB(94, 88, 79), core = Color3.fromRGB(190, 124, 73),
		style = "iron",
	},
	{
		id = "verdant-shard", name = "Verdant Shard", rarity = 3, weight = 12,
		scale = 1.12, fragments = 6, burstMultiplier = 1.8,
		rock = Color3.fromRGB(77, 91, 69), core = Color3.fromRGB(119, 183, 107),
		style = "crystal",
	},
	{
		id = "magma-heart", name = "Magma Heart", rarity = 4, weight = 6,
		scale = 1.27, fragments = 7, burstMultiplier = 2.7,
		rock = Color3.fromRGB(71, 57, 49), core = Color3.fromRGB(244, 105, 39),
		style = "molten",
	},
	{
		id = "ancient-core", name = "Ancient Core", rarity = 5, weight = 2.5,
		scale = 1.45, fragments = 8, burstMultiplier = 4.2,
		rock = Color3.fromRGB(96, 83, 62), core = Color3.fromRGB(248, 190, 67),
		style = "ancient",
	},
	{
		id = "starbreaker", name = "Starbreaker", rarity = 6, weight = 0.55,
		scale = 1.72, fragments = 10, burstMultiplier = 7.5,
		rock = Color3.fromRGB(42, 36, 39), core = Color3.fromRGB(184, 67, 77),
		style = "cosmic",
	},
}

Content.specimens = {
	{ id = "moon-pebble", name = "Moon Pebble", rarity = 1, weight = 45, income = 1 },
	{ id = "spark-mite", name = "Spark Mite", rarity = 1, weight = 28, income = 2 },
	{ id = "comet-pup", name = "Comet Pup", rarity = 2, weight = 15, income = 4 },
	{ id = "orbit-owl", name = "Orbit Owl", rarity = 3, weight = 7, income = 9 },
	{ id = "solar-fox", name = "Solar Fox", rarity = 4, weight = 3.2, income = 22 },
	{ id = "nova-whale", name = "Nova Whale", rarity = 5, weight = 1.5, income = 58 },
	{ id = "singularity-cat", name = "Singularity Cat", rarity = 6, weight = 0.3, income = 180 },
}

Content.upgrades = {
	speed = { label = "Meteor Boots", max = 12, base = 80, growth = 1.72 },
	vault = { label = "Vault Slots", max = 10, base = 120, growth = 1.88 },
	reactor = { label = "Stardust Reactor", max = 8, base = 150, growth = 1.95 },
}

Content.palette = {
	sky = Color3.fromRGB(226, 199, 150),
	ground = Color3.fromRGB(109, 112, 68),
	ground2 = Color3.fromRGB(156, 126, 84),
	accent = Color3.fromRGB(224, 112, 48),
	gold = Color3.fromRGB(242, 183, 68),
	danger = Color3.fromRGB(194, 73, 62),
	panel = Color3.fromRGB(48, 42, 34),
	wood = Color3.fromRGB(126, 83, 52),
	leaf = Color3.fromRGB(91, 125, 68),
	cream = Color3.fromRGB(239, 224, 190),
	rust = Color3.fromRGB(150, 74, 43),
}

local specimenById = {}
local drops = {}
for _, specimen in Content.specimens do
	specimenById[specimen.id] = specimen
	table.insert(drops, {
		id = specimen.id,
		weight = specimen.weight,
		rarity = specimen.rarity,
	})
end
Content.drops = drops

local meteorById = {}
local meteorWeight = 0
for _, meteor in Content.meteors do
	meteorById[meteor.id] = meteor
	meteorWeight += meteor.weight
end

function Content.specimen(id: string): any?
	return specimenById[id]
end

function Content.meteor(id: string): any?
	return meteorById[id]
end

function Content.rarity(tier: number): any
	return Content.rarities[math.clamp(tier, 1, #Content.rarities)]
end

function Content.rollMeteor(random: Random, luck: number?): any
	-- Shower luck compresses common weight but does not guarantee rarity.
	local boost = math.max(0, luck or 0)
	local total = 0
	local adjusted = {}
	for _, meteor in Content.meteors do
		local rarityBoost = 1 + boost * math.max(0, meteor.rarity - 1) * 0.32
		local weight = meteor.weight * rarityBoost
		total += weight
		table.insert(adjusted, { meteor = meteor, weight = weight })
	end
	local pick = random:NextNumber(0, total)
	local cursor = 0
	for _, row in adjusted do
		cursor += row.weight
		if pick <= cursor then return row.meteor end
	end
	return Content.meteors[1]
end

function Content.upgradeCost(id: string, level: number): number
	local spec = Content.upgrades[id]
	if not spec then return math.huge end
	return math.floor(spec.base * (spec.growth ^ level))
end

function Content.income(specimenId: string, mutation: string?): number
	local specimen = specimenById[specimenId]
	if not specimen then return 0 end
	local multiplier = if mutation == "radiant" then 2 elseif mutation == "void" then 5 else 1
	return specimen.income * multiplier
end

return Content
