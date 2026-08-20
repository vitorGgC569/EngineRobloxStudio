--!strict
-- Rarity odds and the luck that bends them.
--
-- Kept as data so the economy can be tuned, tested and reasoned about without
-- reading dispenser code. Luck multiplies the *weight* of rarer outcomes rather
-- than adding a flat chance, so an upgrade feels meaningful at every tier
-- instead of being decisive once and irrelevant after.

local LuckCatalog = {}

--- Base pull weights. Higher is more common.
LuckCatalog.BaseWeights = {
	Common = 1000,
	Uncommon = 420,
	Rare = 150,
	Epic = 42,
	Legendary = 9,
	Mythic = 1,
}

--- How strongly luck lifts each tier. Common is deliberately below 1: luck has
--- to take probability *from* somewhere, or every tier just inflates.
LuckCatalog.LuckResponse = {
	Common = -0.55,
	Uncommon = 0.15,
	Rare = 0.60,
	Epic = 1.10,
	Legendary = 1.70,
	Mythic = 2.40,
}

LuckCatalog.Upgrades = {
	{ level = 1, luck = 1.0, price = 0, name = "Standard Belt" },
	{ level = 2, luck = 1.35, price = 750, name = "Polished Rollers" },
	{ level = 3, luck = 1.85, price = 2400, name = "Magnetic Sorter" },
	{ level = 4, luck = 2.60, price = 7200, name = "Resonance Coils" },
	{ level = 5, luck = 3.80, price = 19000, name = "Ridge Prospector" },
	{ level = 6, luck = 5.50, price = 52000, name = "Mythic Lattice" },
}

LuckCatalog.MaxLuckLevel = #LuckCatalog.Upgrades

--- Belt speed rises with the luck tier so an upgrade is visible, not just felt.
---
--- Tuned against the belt's length for a ~3s ride at level 1, falling to ~1.7s
--- at the top. Measured first at 8 studs/s over a 126-stud belt: 16 seconds per
--- card, long enough that pulls outran their own deliveries and the collection
--- looked broken.
LuckCatalog.BeltSpeedByLevel = { 5, 6, 7, 8, 9, 11 }

function LuckCatalog.upgradeFor(level: number)
	return LuckCatalog.Upgrades[math.clamp(level, 1, LuckCatalog.MaxLuckLevel)]
end

function LuckCatalog.nextUpgrade(level: number)
	return LuckCatalog.Upgrades[level + 1]
end

function LuckCatalog.luckFor(level: number): number
	return LuckCatalog.upgradeFor(level).luck
end

function LuckCatalog.beltSpeedFor(level: number): number
	return LuckCatalog.BeltSpeedByLevel[math.clamp(level, 1, #LuckCatalog.BeltSpeedByLevel)]
end

--- Effective weights at a given luck value.
function LuckCatalog.weights(luck: number): { [string]: number }
	local result = {}
	for rarity, base in pairs(LuckCatalog.BaseWeights) do
		local response = LuckCatalog.LuckResponse[rarity] or 0
		-- luck 1.0 leaves the table untouched, whatever the response is.
		local factor = math.max(0.02, 1 + (luck - 1) * response)
		result[rarity] = base * factor
	end
	return result
end

--- Roll a rarity. `random` is injected so a test can pin the sequence.
function LuckCatalog.roll(luck: number, random: Random): string
	local weights = LuckCatalog.weights(luck)
	local total = 0
	for _, weight in pairs(weights) do
		total += weight
	end

	local pick = random:NextNumber(0, total)
	-- Walk rarest first so a lucky roll cannot be swallowed by ordering.
	for _, rarity in ipairs({ "Mythic", "Legendary", "Epic", "Rare", "Uncommon", "Common" }) do
		local weight = weights[rarity]
		if weight then
			pick -= weight
			if pick <= 0 then
				return rarity
			end
		end
	end
	return "Common"
end

--- Odds as percentages, for showing the player what an upgrade actually buys.
function LuckCatalog.odds(luck: number): { [string]: number }
	local weights = LuckCatalog.weights(luck)
	local total = 0
	for _, weight in pairs(weights) do
		total += weight
	end
	local result = {}
	for rarity, weight in pairs(weights) do
		result[rarity] = math.round((weight / total) * 10000) / 100
	end
	return result
end

return LuckCatalog
