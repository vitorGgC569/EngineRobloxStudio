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

-- wealthWeight used to close over the caller's bands. Zeroing a multiplier
-- after add then made the next roll return nothing.
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

function Lottery.new(): Self
	return setmetatable({ entries = {} }, Lottery)
end

-- Static weight or dynamic rule; the function wins when both given.
-- A missing weight still means 0. math.huge is a number, so it used to be
-- stored, and a roll above 0 then skipped that entry for the last finite one.
function Lottery.add(self: Self, id: string, spec: { weight: number?, weightFn: ((RollContext) -> number)? }): ()
	-- An empty id is a real key, so roll can return an entry with no name.
	assert(type(id) == "string" and #id > 0, "invalid id")
	assert(not self:idIndex(id), ("duplicate pool entry %q"):format(id))
	local weight = spec.weight
	if weight == nil then
		weight = 0
	else
		assert(
			type(weight) == "number" and weight == weight and weight >= 0 and weight < math.huge,
			"invalid weight"
		)
	end
	table.insert(self.entries, {
		id = id,
		weight = weight,
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
	-- A weight function can return a string. math.max throws on that, so
	-- the named entry already in the pool is never reached. A missing
	-- type, a NaN, a negative, or an infinite result counts as no weight.
	if type(w) ~= "number" or w ~= w or w < 0 or not (w < math.huge) then
		w = 0
	end
	-- math.huge is > 0, and 0 * math.huge is NaN, so the first entry is
	-- skipped. Only a finite multiplier above zero may scale the weight.
	local multiplier = ctx.multiplier
	if type(multiplier) == "number" and multiplier == multiplier and multiplier > 0 and multiplier < math.huge then
		w *= multiplier
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
	-- NaN is not < any accumulated weight, and neither is math.huge, so
	-- both fall through to the last entry. A sample that is not a number
	-- does the same. Only a finite sample may walk the pool.
	local sample = rng()
	if type(sample) ~= "number" or sample ~= sample or not (sample > -math.huge and sample < math.huge) then
		return nil
	end
	local roll = sample * total
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
	-- math.huge is a number, so it used to be closed over and every roll
	-- of that weight was infinite.
	assert(type(base) == "number" and base == base and base >= 0 and base < math.huge, "invalid base")
	local sealed = deepCopy(bands, {}) :: { { above: number, mult: number } }
	-- math.huge survives the copy, and base * math.huge is the infinity
	-- that makes a later roll of 0 skip the first entry.
	for _, band in sealed do
		assert(type(band.mult) == "number" and band.mult == band.mult and band.mult >= 0 and band.mult < math.huge, "invalid band multiplier")
		-- A missing above is nil, and wealth >= nil throws inside the closure.
		assert(type(band.above) == "number" and band.above == band.above and band.above > -math.huge and band.above < math.huge, "invalid band threshold")
	end
	return function(ctx: RollContext): number
		local wealth = ctx.wealth or 0
		local mult = 1
		for _, band in sealed do
			if wealth >= band.above then
				mult = band.mult
			end
		end
		return base * mult
	end
end

return Lottery
