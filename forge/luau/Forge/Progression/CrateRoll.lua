--!strict
--[[
	CrateRoll — deterministic crate loot with pity and weighted tables.

	Crates roll from a weighted table under a seeded rng so any drop is
	replayable from (crateId, seed). A pity counter guarantees a rare
	after N unlucky rolls — the retention mechanic that keeps crates
	honest.
]]

local CrateRoll = {}

export type Drop = { id: string, weight: number, rarity: number }

type Self = {
	drops: { Drop },
	totalWeight: number,
	pityThreshold: number,
	pityCounter: number,
	minRarityForPity: number,
}

CrateRoll.__index = CrateRoll

function CrateRoll.new(config: { drops: { Drop }, pityThreshold: number?, minRarityForPity: number? }): Self
	assert(#config.drops > 0, "crates need drops")
	local total = 0
	for _, drop in config.drops do
		assert(drop.weight >= 0 and #drop.id > 0, "invalid drop")
		total += drop.weight
	end
	assert(total > 0, "drop weights must sum positive")
	return setmetatable({
		drops = table.clone(config.drops),
		totalWeight = total,
		pityThreshold = config.pityThreshold or 20,
		pityCounter = 0,
		minRarityForPity = config.minRarityForPity or 3,
	}, CrateRoll)
end

function CrateRoll.roll(self: Self, rng: () -> number): Drop
	local forcedPity = self.pityCounter + 1 >= self.pityThreshold
	local pool: { Drop } = {}
	local total = 0
	for _, drop in self.drops do
		if not forcedPity or drop.rarity >= self.minRarityForPity then
			table.insert(pool, drop)
			total += drop.weight
		end
	end
	if total <= 0 then
		pool, total = self.drops, self.totalWeight
	end

	local roll = rng() * total
	local acc = 0
	local chosen = pool[#pool] :: Drop
	for _, drop in pool do
		acc += drop.weight
		if roll < acc then
			chosen = drop
			break
		end
	end

	if chosen.rarity >= self.minRarityForPity then
		self.pityCounter = 0
	else
		self.pityCounter += 1
	end
	return chosen
end

return CrateRoll
