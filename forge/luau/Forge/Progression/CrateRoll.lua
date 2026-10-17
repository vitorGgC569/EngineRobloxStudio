--!strict
--[[
	CrateRoll — deterministic crate loot with pity and weighted tables.

	Crates roll from a weighted table under a seeded rng so any drop is
	replayable from (crateId, seed). A pity counter guarantees a rare
	after N unlucky rolls — the retention mechanic that keeps crates
	honest.
]]

local CrateRoll = {}

-- The pool used to be a shallow clone, and roll() handed that same table
-- back. Editing a weight on the caller's drop, or on the drop just returned,
-- rewrote later rolls while totalWeight still described the old numbers.
local function deepCopy(value: any, seen: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in value :: { [any]: any } do
		copy[key] = deepCopy(item, seen)
	end
	return copy
end

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
	-- A negative threshold is truthy, so `or 20` would keep it. Pity then
	-- fires on the first roll because the counter already meets -1.
	local pityThreshold = if config.pityThreshold ~= nil then config.pityThreshold else 20
	assert(type(pityThreshold) == "number" and pityThreshold >= 1, "pityThreshold must be at least 1")
	-- A negative floor is truthy, so `or 3` would keep it. Pity then
	-- keeps every drop because rarity >= -1.
	local minRarityForPity = if config.minRarityForPity ~= nil then config.minRarityForPity else 3
	assert(type(minRarityForPity) == "number" and minRarityForPity >= 1, "minRarityForPity must be at least 1")
	return setmetatable({
		drops = deepCopy(config.drops, {}) :: { Drop },
		totalWeight = total,
		pityThreshold = pityThreshold,
		pityCounter = 0,
		minRarityForPity = minRarityForPity,
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
	return deepCopy(chosen, {}) :: Drop
end

return CrateRoll
