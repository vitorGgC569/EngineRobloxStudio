--!strict
--[[
	Enchanting: costed upgrade rolls over item slots.

	The vesteria contract: an enchant consumes a material item plus gold,
	respects the slot's upgrade cap, and appends one modifier rolled
	inside declared ranges (flat or percent). A blessed variant widens
	the ranges by a multiplier. The caller validates funds/ownership and
	persists the returned slot; this module owns the rules.
]]

local Enchanting = {}

export type ModifierRange = {
	stat: string,
	flatMin: number?,
	flatMax: number?,
	percentMin: number?,
	percentMax: number?,
	weight: number,
}

export type EnchantDef = {
	id: string,
	materialItemId: string,
	goldCost: number,
	maxUpgrades: number,
	modifiers: { ModifierRange },
	blessedChance: number?,
	blessedMultiplier: number?,
}

export type SlotData = {
	itemId: string,
	upgrades: number,
	modifiers: { { stat: string, flat: number?, percent: number? } },
}

type Self = {
	defs: { [string]: EnchantDef },
}

Enchanting.__index = Enchanting

local function rollInRange(rng: () -> number, min: number, max: number): number
	return min + rng() * (max - min)
end

function Enchanting.new(): Self
	return setmetatable({ defs = {} }, Enchanting)
end

function Enchanting.define(self: Self, def: EnchantDef): ()
	assert(not self.defs[def.id], ("duplicate enchant %q"):format(def.id))
	assert(def.maxUpgrades >= 1, "maxUpgrades >= 1")
	assert(def.goldCost >= 0 and #def.materialItemId > 0, "cost required")
	assert(#def.modifiers > 0, "needs modifiers")
	for _, range in def.modifiers do
		assert(range.weight >= 0, "weight >= 0")
	end
	self.defs[def.id] = table.clone(def)
end

function Enchanting.costOf(self: Self, defId: string): (string?, number?)
	local def = self.defs[defId]
	if not def then
		return nil, nil
	end
	return def.materialItemId, def.goldCost
end

-- Rolls one enchant onto a CLONE of the slot. Caller debits materials.
-- blessed doubles range width around the midpoint when it procs.
function Enchanting.roll(self: Self, defId: string, slot: SlotData, rng: () -> number): (SlotData?, string?)
	local def = self.defs[defId]
	if not def then
		return nil, "unknown_enchant"
	end
	if slot.upgrades >= def.maxUpgrades then
		return nil, "max_upgrades"
	end

	local newSlot = table.clone(slot) :: any
	newSlot.modifiers = table.clone(slot.modifiers)

	local blessed = self.rngChance(def, rng)
	local widen = if blessed then (def.blessedMultiplier or 2) else 1

	-- Weighted pick of which stat gets modified.
	local totalWeight = 0
	for _, range in def.modifiers do
		totalWeight += range.weight
	end
	if totalWeight <= 0 then
		return nil, "no_modifiers"
	end
	local pickRoll = rng() * totalWeight
	local acc = 0
	local chosen = def.modifiers[#def.modifiers] :: ModifierRange
	for _, range in def.modifiers do
		acc += range.weight
		if pickRoll < acc then
			chosen = range
			break
		end
	end

	local modifier: { stat: string, flat: number?, percent: number? } = { stat = chosen.stat }
	if chosen.flatMin and chosen.flatMax then
		local mid = (chosen.flatMin + chosen.flatMax) / 2
		local half = (chosen.flatMax - chosen.flatMin) / 2 * widen
		modifier.flat = math.floor((rollInRange(rng, mid - half, mid + half)) * 100 + 0.5) / 100
	elseif chosen.percentMin and chosen.percentMax then
		local mid = (chosen.percentMin + chosen.percentMax) / 2
		local half = (chosen.percentMax - chosen.percentMin) / 2 * widen
		modifier.percent = math.floor((rollInRange(rng, mid - half, mid + half)) * 1000 + 0.5) / 1000
	else
		return nil, "modifier_without_range"
	end

	table.insert(newSlot.modifiers, modifier)
	newSlot.upgrades = slot.upgrades + 1
	return newSlot, nil
end

function Enchanting.rngChance(self: Self, def: EnchantDef, rng: () -> number): boolean
	local chance = def.blessedChance
	if not chance or chance <= 0 then
		return false
	end
	return rng() < chance
end

return Enchanting
