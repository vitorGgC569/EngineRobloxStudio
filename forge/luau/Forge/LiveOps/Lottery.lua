--!strict
--[[
	Lottery — cumulative-range loot rolls with contextual weights.

	A loot pool is a list of entries whose weights are computed at roll
	time from context: the player's wealth band, VIP status, event
	multipliers. Weights become adjacent numeric ranges over one integer
	space; a single roll lands in exactly one range. Deterministic under
	the injected rng — QA replays any drop.
]]

local Lottery = {}

export type RollContext = {
	wealth: number?,
	vip: boolean?,
	multiplier: number?,
}

export type Entry = {
	id: string,
	weight: number,
	weightFn: ((RollContext) -> number)?,
}

type Self = {
	entries: { Entry },
}

Lottery.__index = Lottery

function Lottery.new(): Self
	return setmetatable({ entries = {} }, Lottery)
end

-- Static weight or dynamic rule; the function wins when both given.
function Lottery.add(self: Self, id: string, spec: { weight: number?, weightFn: ((RollContext) -> number)? }): ()
	assert(not self:idIndex(id), ("duplicate pool entry %q"):format(id))
	table.insert(self.entries, {
		id = id,
		weight = spec.weight or 0,
		weightFn = spec.weightFn,
	})
end

function Lottery.idIndex(self: Self, id: string): number?
	for index, entry in self.entries do
		if entry.id == id then
			return index
		end
	end
	return nil
end

local function effectiveWeight(entry: Entry, ctx: RollContext): number
	local w = if entry.weightFn then entry.weightFn(ctx) else entry.weight
	if ctx.multiplier and ctx.multiplier > 0 then
		w *= ctx.multiplier
	end
	return math.max(0, w)
end

-- Rolls an entry id; nil only when every weight is zero.
function Lottery.roll(self: Self, rng: () -> number, ctx: RollContext?): string?
	local c = ctx or {}
	local total = 0
	for _, entry in self.entries do
		total += effectiveWeight(entry, c)
	end
	if total <= 0 then
		return nil
	end
	local roll = rng() * total
	local acc = 0
	for _, entry in self.entries do
		acc += effectiveWeight(entry, c)
		if roll < acc then
			return entry.id
		end
	end
	return self.entries[#self.entries].id
end

-- Wealth-band helper: scale a base weight by how rich the roller is.
-- bands = {{above=0, mult=1}, {above=10000, mult=1.5}, ...} evaluated top-down.
function Lottery.wealthWeight(base: number, bands: { { above: number, mult: number } }): (RollContext) -> number
	return function(ctx: RollContext): number
		local wealth = ctx.wealth or 0
		local mult = 1
		for _, band in bands do
			if wealth >= band.above then
				mult = band.mult
			end
		end
		return base * mult
	end
end

return Lottery
