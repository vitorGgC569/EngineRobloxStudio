--!strict
--[[
	MobCatalog — weighted spawner specification.

	Spawn choice and spawn placement are data, not code: entries with
	size/speed/weight, geometric-weighted size rolls, ring placement
	around a centre. Deterministic under the injected rng so QA can
	reproduce any wave.
]]

local Rng = require(script.Parent.Parent.Core.Rng)

local MobCatalog = {}

export type Entry = {
	id: string,
	size: number,
	speed: number?,
	weight: number?,
}

export type SpawnPoint = {
	x: number,
	z: number,
}

type Self = {
	entries: { Entry },
	weights: { number },
}

MobCatalog.__index = MobCatalog

function MobCatalog.new(entries: { Entry }): Self
	assert(#entries > 0, "MobCatalog needs entries")
	local weights: { number } = {}
	local total = 0
	for _, entry in entries do
		assert(entry.size > 0, ("entry %q has invalid size"):format(entry.id))
		local w = math.max(0, entry.weight or 1)
		table.insert(weights, w)
		total += w
	end
	assert(total > 0, "catalog weights must sum to a positive value")
	return setmetatable({ entries = table.clone(entries), weights = weights }, MobCatalog)
end

function MobCatalog.pick(self: Self, rng: Rng.Generator): Entry
	return self.entries[Rng.weightedPick(rng, self.weights)]
end

-- Uniform point on an annulus around centre.
function MobCatalog.ringPoint(center: SpawnPoint, minRadius: number, maxRadius: number, rng: Rng.Generator): SpawnPoint
	assert(maxRadius >= minRadius and minRadius >= 0)
	local radius = math.sqrt(Rng.range(rng, minRadius * minRadius, maxRadius * maxRadius))
	local angle = rng() * math.pi * 2
	return { x = center.x + math.cos(angle) * radius, z = center.z + math.sin(angle) * radius }
end

return MobCatalog
