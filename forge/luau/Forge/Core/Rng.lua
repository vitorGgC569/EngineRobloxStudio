--!strict
--[[
	Rng — deterministic random helpers shared by Forge families.

	Gameplay that can be replayed (tests, scenarios, evidence) must never
	reach for the global math.random. Every module here takes a seed and
	produces the same stream on every machine, so a recorded match or a
	lottery roll can be re-run bit-for-bit.

		local rng = Rng.xorshift(20260811)
		local pick = Rng.weightedPick(rng, { 10, 5, 1 })
]]

local Rng = {}

export type Generator = () -> number

function Rng.xorshift(seed: number?): Generator
	local s = math.floor((seed or 0x9E3779B9) % 4294967296)
	if s <= 0 then
		s += 4294967296
	end
	if s == 0 then
		s = 0x9E3779B9
	end
	return function(): number
		s = bit32.bxor(s, bit32.lshift(s, 13))
		s = bit32.bxor(s, bit32.rshift(s, 17))
		s = bit32.bxor(s, bit32.lshift(s, 5))
		return s / 4294967296
	end
end

function Rng.weightedPick(rng: Generator, weights: { number }): number
	local total = 0
	for _, w in weights do
		assert(w >= 0, "negative weight")
		total += w
	end
	assert(total > 0, "weighted pick needs at least one positive weight")
	local roll = rng() * total
	local acc = 0
	for i, w in weights do
		acc += w
		if roll < acc then
			return i
		end
	end
	return #weights
end

function Rng.range(rng: Generator, min: number, max: number): number
	return min + rng() * (max - min)
end

function Rng.int(rng: Generator, min: number, max: number): number
	return math.floor(Rng.range(rng, min, max + 1 - 1e-9))
end

function Rng.shuffle<T>(rng: Generator, list: { T }): { T }
	local out = table.clone(list)
	for i = #out, 2, -1 do
		local j = Rng.int(rng, 1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

return Rng
