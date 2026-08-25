--!strict
--[[
	Rng — seeded randomness in named streams.

	This is where determinism belongs, and the only place Forge insists on it.

	One shared Random is a trap: the moment loot rolls consume numbers from the
	same sequence as terrain, regenerating the same world with a different drop
	becomes impossible, and a bug reproduced yesterday will not reproduce today.
	Streams fix that — `Rng.stream("world")` and `Rng.stream("loot")` are
	independent, both derived from one master seed, both reproducible.

		Rng.seed(20260819)
		local world = Rng.stream("world")
		local h = world:number(0, 1)

	The validation half can capture `Rng.describe()` with a run and replay it.
]]

local Rng = {}

local masterSeed = 0
local streams: { [string]: any } = {}

-- FNV-1a over the stream name, mixed with the master seed. Deterministic across
-- machines, unlike anything derived from a table address or os.clock.
local function deriveSeed(name: string, seed: number): number
	local hash = 2166136261
	for i = 1, #name do
		hash = bit32.bxor(hash, string.byte(name, i))
		hash = (hash * 16777619) % 4294967296
	end
	return (hash + seed * 2654435761) % 2147483647
end

local Stream = {}
Stream.__index = Stream

function Stream:number(min: number?, max: number?): number
	if min and max then
		return self._r:NextNumber(min, max)
	end
	return self._r:NextNumber()
end

function Stream:int(min: number, max: number): number
	return self._r:NextInteger(min, max)
end

function Stream:bool(chance: number?): boolean
	return self._r:NextNumber() < (chance or 0.5)
end

function Stream:unit(): Vector3
	return self._r:NextUnitVector()
end

function Stream:pick<T>(list: { T }): T?
	if #list == 0 then
		return nil
	end
	return list[self._r:NextInteger(1, #list)]
end

-- Weighted pick over entries carrying a `weight` field (default 1).
function Stream:weighted<T>(entries: { T }): T?
	local total = 0
	for _, e in entries do
		total += ((e :: any).weight or 1)
	end
	if total <= 0 then
		return nil
	end
	local roll = self._r:NextNumber() * total
	local acc = 0
	for _, e in entries do
		acc += ((e :: any).weight or 1)
		if roll <= acc then
			return e
		end
	end
	return entries[#entries]
end

function Stream:shuffle<T>(list: { T }): { T }
	for i = #list, 2, -1 do
		local j = self._r:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

-- Point in a disc, uniform by area (naive polar sampling clusters at the centre).
function Stream:inDisc(radius: number): Vector2
	local r = radius * math.sqrt(self._r:NextNumber())
	local a = self._r:NextNumber() * math.pi * 2
	return Vector2.new(math.cos(a) * r, math.sin(a) * r)
end

function Stream:reset()
	self._r = Random.new(self._seed)
end

function Rng.seed(seed: number)
	masterSeed = seed
	table.clear(streams)
end

function Rng.masterSeed(): number
	return masterSeed
end

function Rng.stream(name: string): any
	local existing = streams[name]
	if existing then
		return existing
	end
	local seed = deriveSeed(name, masterSeed)
	local stream = setmetatable({ _seed = seed, _r = Random.new(seed), name = name }, Stream)
	streams[name] = stream
	return stream
end

-- Throwaway stream for a specific coordinate: same tile always rolls the same
-- contents, without keeping any per-tile state.
function Rng.at(name: string, x: number, y: number): any
	local seed = deriveSeed(string.format("%s:%d:%d", name, math.floor(x), math.floor(y)), masterSeed)
	return setmetatable({ _seed = seed, _r = Random.new(seed), name = name }, Stream)
end

-- Fractal noise. The backbone of every heightfield, moisture map and scatter
-- mask, and deterministic for a given seed.
function Rng.fbm(x: number, y: number, options: any?): number
	local o = options or {}
	local octaves = o.octaves or 4
	local frequency = o.frequency or 0.01
	local persistence = o.persistence or 0.5
	local seed = o.seed or masterSeed

	local total, amplitude, maxValue = 0, 1, 0
	local f = frequency
	for _ = 1, octaves do
		total += math.noise(x * f, y * f, seed) * amplitude
		maxValue += amplitude
		amplitude *= persistence
		f *= 2.03 -- non-integer, so harmonics never line up into visible grids
	end
	return total / maxValue
end

-- fbm remapped to 0..1, which is what most callers actually want.
function Rng.fbm01(x: number, y: number, options: any?): number
	return (Rng.fbm(x, y, options) + 1) * 0.5
end

-- Ridged noise: sharp crests instead of rolling hills. Mountains, canyons.
function Rng.ridge(x: number, y: number, options: any?): number
	return 1 - math.abs(Rng.fbm(x, y, options))
end

-- What a run should record so it can be replayed.
function Rng.describe(): { [string]: any }
	local names = {}
	for name in streams do
		table.insert(names, name)
	end
	table.sort(names)
	return { masterSeed = masterSeed, streams = names }
end

-- ============================ a generator you carry =========================
--[[
	A second shape of randomness, and why both belong here.

	Everything above is a *named stream*: `Rng.stream("scatter")` is the same
	sequence on every machine for a given master seed, which is what makes a
	world reproducible from a number. That is the right tool when the caller
	does not want to carry anything.

	This is the other one — a generator you hold and pass. Right when the
	sequence belongs to one lottery roll, one crate, one shuffle, and must not
	advance because something else drew from it. A shared stream is a hidden
	dependency between two systems that never mention each other.

		local rng = Rng.xorshift(20260811)
		local pick = Rng.weightedPick(rng, { 10, 5, 1 })

	Both were in this file at different times. A mining pass replaced the first
	set with the second, which compiled cleanly, passed 1356 tests, passed both
	doctors — and broke every game in the repository, because `Rng.seed` is the
	first line of both bootstraps. Nothing found it until a game was run. They
	coexist now: the names never collided, and losing either was never the
	intent.
]]

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
