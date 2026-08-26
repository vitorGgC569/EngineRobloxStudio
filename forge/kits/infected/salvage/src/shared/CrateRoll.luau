--!strict
-- Pure crate logic: weighted rarity roll + the "card flip" — the winner plus the
-- near-misses shown face-down (STK-style regret loop). rng injected for tests.

local CrateRoll = {}

export type Rarity = { name: string, weight: number }
export type Skin = { id: string, rarity: string }

function CrateRoll.rollRarity(rarities: { Rarity }, rng: () -> number): string
	local total = 0
	for _, r in rarities do
		total += r.weight
	end
	local roll = rng() * total
	local acc = 0
	for _, r in rarities do
		acc += r.weight
		if roll < acc then
			return r.name
		end
	end
	return rarities[#rarities].name
end

function CrateRoll.skinsOfRarity(catalog: { Skin }, rarity: string): { Skin }
	local out = {}
	for _, skin in catalog do
		if skin.rarity == rarity then
			table.insert(out, skin)
		end
	end
	return out
end

-- Returns the won skin id plus (count-1) decoy skin ids for the card-flip reveal.
function CrateRoll.open(
	catalog: { Skin },
	rarities: { Rarity },
	cardCount: number,
	rng: () -> number
): (string, { string })
	local rarity = CrateRoll.rollRarity(rarities, rng)
	local pool = CrateRoll.skinsOfRarity(catalog, rarity)
	assert(#pool > 0, "no skins of rarity " .. rarity)
	local winner = pool[math.floor(rng() * #pool) + 1] or pool[#pool]

	local decoys = {}
	for _ = 1, cardCount - 1 do
		local decoyRarity = CrateRoll.rollRarity(rarities, rng)
		local decoyPool = CrateRoll.skinsOfRarity(catalog, decoyRarity)
		local decoy = decoyPool[math.floor(rng() * #decoyPool) + 1] or decoyPool[#decoyPool]
		table.insert(decoys, decoy.id)
	end
	return winner.id, decoys
end

return CrateRoll
