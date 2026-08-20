--!strict
-- Farm economy: slots, production, mutations, offline earnings.
--
-- Follows the Anime Card Farm loop: pull a card from the belt, slot it, wait
-- out its activation, and it produces Card Boxes every second which are sold
-- for cash. Rarer cards take longer to come online and then out-earn the rest
-- by a wide margin -- that tension is the whole economy.
--
-- Public sources for that game do not publish exact figures ("no authoritative
-- public list of every card, rarity, price, or income value"), so the numbers
-- here are this game's own, tuned against measured play rather than copied.

local FarmCatalog = {}

--- Slots a farm starts with, and the ceiling it can grow to.
FarmCatalog.StartingSlots = 10
FarmCatalog.MaxSlots = 40

--- Boxes produced per second, before mutation and upgrade multipliers.
FarmCatalog.ProductionByRarity = {
	Common = 0.5,
	Uncommon = 1.1,
	Rare = 2.6,
	Epic = 6.5,
	Legendary = 17,
	Mythic = 48,
}

--- Cash a single Card Box sells for, by the rarity that produced it.
FarmCatalog.BoxValueByRarity = {
	Common = 4,
	Uncommon = 9,
	Rare = 24,
	Epic = 70,
	Legendary = 210,
	Mythic = 720,
}

--- Seconds a card spends warming up after being slotted. Rarer is slower: the
--- wait is what makes a Mythic feel like an event rather than a number.
FarmCatalog.ActivationSeconds = {
	Common = 2,
	Uncommon = 4,
	Rare = 8,
	Epic = 15,
	Legendary = 30,
	Mythic = 60,
}

--- Boxes a slot holds before it stops producing. Full slots are the reason to
--- come back rather than idle forever.
FarmCatalog.SlotCapacity = 250

--- Mutations. Rare variants that multiply everything a card earns.
FarmCatalog.Mutations = {
	{ id = "none", name = "", multiplier = 1.0, weight = 1000, color = { 200, 205, 210 } },
	{ id = "shiny", name = "Shiny", multiplier = 1.6, weight = 150, color = { 255, 236, 140 } },
	{ id = "frozen", name = "Frozen", multiplier = 2.4, weight = 70, color = { 140, 216, 255 } },
	{ id = "molten", name = "Molten", multiplier = 3.6, weight = 32, color = { 255, 130, 78 } },
	{ id = "void", name = "Void", multiplier = 6.0, weight = 11, color = { 168, 108, 255 } },
	{ id = "prismatic", name = "Prismatic", multiplier = 12.0, weight = 3, color = { 120, 255, 214 } },
	{ id = "celestial", name = "Celestial", multiplier = 25.0, weight = 1, color = { 255, 214, 120 } },
}

FarmCatalog.MutationById = {}
for _, mutation in ipairs(FarmCatalog.Mutations) do
	FarmCatalog.MutationById[mutation.id] = mutation
end

--- Slot prices grow geometrically so expansion stays a real decision.
function FarmCatalog.slotPrice(slotIndex: number): number
	if slotIndex <= FarmCatalog.StartingSlots then
		return 0
	end
	local step = slotIndex - FarmCatalog.StartingSlots
	return math.floor(500 * (1.55 ^ step))
end

function FarmCatalog.production(rarity: string): number
	return FarmCatalog.ProductionByRarity[rarity] or FarmCatalog.ProductionByRarity.Common
end

function FarmCatalog.boxValue(rarity: string): number
	return FarmCatalog.BoxValueByRarity[rarity] or FarmCatalog.BoxValueByRarity.Common
end

function FarmCatalog.activationSeconds(rarity: string): number
	return FarmCatalog.ActivationSeconds[rarity] or 2
end

--- Roll a mutation. Luck lifts the rare tiers the same way it lifts rarity.
function FarmCatalog.rollMutation(luck: number, random: Random): string
	local total = 0
	local weights = {}
	for _, mutation in ipairs(FarmCatalog.Mutations) do
		-- "none" gets rarer as luck rises; everything else gets likelier.
		local weight = if mutation.id == "none"
			then mutation.weight / math.max(1, luck * 0.85)
			else mutation.weight * math.max(1, luck * 0.6)
		weights[mutation.id] = weight
		total += weight
	end

	local pick = random:NextNumber(0, total)
	for index = #FarmCatalog.Mutations, 1, -1 do
		local mutation = FarmCatalog.Mutations[index]
		pick -= weights[mutation.id]
		if pick <= 0 then
			return mutation.id
		end
	end
	return "none"
end

function FarmCatalog.mutationMultiplier(mutationId: string): number
	local mutation = FarmCatalog.MutationById[mutationId]
	return mutation and mutation.multiplier or 1
end

--- Boxes per second for one slotted card, all multipliers applied.
function FarmCatalog.slotRate(rarity: string, mutationId: string, upgradeLevel: number?): number
	local base = FarmCatalog.production(rarity)
	local mutation = FarmCatalog.mutationMultiplier(mutationId)
	local upgrade = 1 + 0.25 * ((upgradeLevel or 1) - 1)
	return base * mutation * upgrade
end

--- Cash per second, for showing a player what a card is actually worth.
function FarmCatalog.slotIncome(rarity: string, mutationId: string, upgradeLevel: number?): number
	return FarmCatalog.slotRate(rarity, mutationId, upgradeLevel) * FarmCatalog.boxValue(rarity)
end

--- Offline production. Capped so leaving for a week is not a shortcut past the
--- whole mid-game, and rated below live play so being present still matters.
FarmCatalog.OfflineRate = 0.6
FarmCatalog.OfflineCapSeconds = 8 * 3600

function FarmCatalog.offlineBoxes(ratePerSecond: number, awaySeconds: number): number
	local counted = math.min(awaySeconds, FarmCatalog.OfflineCapSeconds)
	return math.floor(ratePerSecond * counted * FarmCatalog.OfflineRate)
end

return FarmCatalog
