--!strict
-- Rebirth: trade the farm you built for a permanent multiplier.
--
-- The move that keeps an idle game alive past its first ceiling. Costs rise
-- steeply and rewards rise faster, so the second run is short and the fifth is
-- shorter still -- the point is to make the early game feel different each
-- time, not to make it repeat.

local RebirthCatalog = {}

export type Tier = {
	level: number,
	name: string,
	requirement: number,
	cashMultiplier: number,
	luckBonus: number,
	slotBonus: number,
}

RebirthCatalog.Tiers = {
	{ level = 1, name = "Prospector", requirement = 50000, cashMultiplier = 1.5, luckBonus = 0.10, slotBonus = 2 },
	{ level = 2, name = "Forager", requirement = 400000, cashMultiplier = 2.2, luckBonus = 0.25, slotBonus = 4 },
	{ level = 3, name = "Ridgehand", requirement = 3.2e6, cashMultiplier = 3.4, luckBonus = 0.45, slotBonus = 6 },
	{ level = 4, name = "Deepdigger", requirement = 2.6e7, cashMultiplier = 5.4, luckBonus = 0.70, slotBonus = 9 },
	{ level = 5, name = "Vaultkeeper", requirement = 2.1e8, cashMultiplier = 8.8, luckBonus = 1.00, slotBonus = 12 },
	{ level = 6, name = "Ridgelord", requirement = 1.7e9, cashMultiplier = 14.5, luckBonus = 1.40, slotBonus = 16 },
	{ level = 7, name = "Ascendant", requirement = 1.4e10, cashMultiplier = 24, luckBonus = 1.90, slotBonus = 20 },
}

RebirthCatalog.MaxLevel = #RebirthCatalog.Tiers

function RebirthCatalog.tier(level: number): Tier?
	return RebirthCatalog.Tiers[level]
end

function RebirthCatalog.next(level: number): Tier?
	return RebirthCatalog.Tiers[level + 1]
end

--- Cumulative effect of every rebirth so far, not just the latest one.
function RebirthCatalog.bonuses(level: number)
	local cash, luck, slots = 1, 0, 0
	for index = 1, math.min(level, RebirthCatalog.MaxLevel) do
		local tier = RebirthCatalog.Tiers[index]
		cash *= tier.cashMultiplier
		luck += tier.luckBonus
		slots += tier.slotBonus
	end
	return { cashMultiplier = cash, luckBonus = luck, slotBonus = slots }
end

function RebirthCatalog.canRebirth(level: number, lifetimeCash: number): (boolean, Tier?)
	local next = RebirthCatalog.next(level)
	if next == nil then
		return false, nil
	end
	return lifetimeCash >= next.requirement, next
end

return RebirthCatalog
