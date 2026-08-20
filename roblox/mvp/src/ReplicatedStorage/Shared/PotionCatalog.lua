--!strict
-- Potions: timed boosts the player stacks before a session.
--
-- Six kinds, matching the reference's set. They are the reason to log in
-- before a play session rather than during one, and the reason a lucky pull
-- feels earned rather than random: a player who drank a Mutation potion first
-- made that outcome likelier on purpose.
--
-- Effects multiply. Two potions of the same kind extend duration rather than
-- stacking multipliers, so the ceiling stays predictable and the economy
-- cannot be broken by hoarding.

local PotionCatalog = {}

export type Potion = {
	id: string,
	name: string,
	description: string,
	--- Which multiplier this potion raises.
	affects: string,
	multiplier: number,
	durationSeconds: number,
	price: number,
	color: { number },
	icon: string,
}

PotionCatalog.Potions = {
	{
		id = "cash",
		name = "Cash Potion",
		description = "Card boxes sell for more.",
		affects = "cash",
		multiplier = 2,
		durationSeconds = 600,
		price = 2500,
		color = { 118, 226, 118 },
		icon = "💰",
	},
	{
		id = "luck",
		name = "Luck Potion",
		description = "Rarer cards on the belt.",
		affects = "luck",
		multiplier = 2,
		durationSeconds = 600,
		price = 4000,
		color = { 108, 178, 255 },
		icon = "🍀",
	},
	{
		id = "mutation",
		name = "Mutation Potion",
		description = "Mutated cards appear far more often.",
		affects = "mutation",
		multiplier = 3,
		durationSeconds = 480,
		price = 9000,
		color = { 190, 122, 255 },
		icon = "🧬",
	},
	{
		id = "production",
		name = "Production Potion",
		description = "Slots fill with boxes faster.",
		affects = "production",
		multiplier = 2.5,
		durationSeconds = 600,
		price = 6500,
		color = { 250, 206, 80 },
		icon = "⚙️",
	},
	{
		id = "time",
		name = "Time Potion",
		description = "Cards activate instantly and belts run faster.",
		affects = "time",
		multiplier = 2,
		durationSeconds = 300,
		price = 5000,
		color = { 92, 214, 236 },
		icon = "⏱️",
	},
	{
		id = "time2",
		name = "Time II Potion",
		description = "A stronger Time Potion, and it lasts longer.",
		affects = "time",
		multiplier = 4,
		durationSeconds = 600,
		price = 18000,
		color = { 255, 118, 110 },
		icon = "⏳",
	},
}

PotionCatalog.ById = {}
for _, potion in ipairs(PotionCatalog.Potions) do
	PotionCatalog.ById[potion.id] = potion
end

function PotionCatalog.get(id: string): Potion?
	return PotionCatalog.ById[id]
end

--- Combine active potions into one multiplier per affected stat.
---
--- `active` maps potion id -> unix expiry. Expired entries are ignored rather
--- than trusted, because a client that lies about its own timers must not be
--- able to keep a boost alive.
function PotionCatalog.multipliers(active: { [string]: number }, now: number): { [string]: number }
	local result = { cash = 1, luck = 1, mutation = 1, production = 1, time = 1 }
	for id, expiresAt in pairs(active or {}) do
		if expiresAt > now then
			local potion = PotionCatalog.ById[id]
			if potion then
				result[potion.affects] = (result[potion.affects] or 1) * potion.multiplier
			end
		end
	end
	return result
end

--- Drop anything that has run out, so saved data does not grow forever.
function PotionCatalog.prune(active: { [string]: number }, now: number): { [string]: number }
	local kept = {}
	for id, expiresAt in pairs(active or {}) do
		if expiresAt > now then
			kept[id] = expiresAt
		end
	end
	return kept
end

return PotionCatalog
