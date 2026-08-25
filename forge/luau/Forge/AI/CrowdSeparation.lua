--!strict
--[[
	CrowdSeparation — soft-body bubble separation for dense crowds.

	~150 agents walking straight will stack into one glowing pile. Every
	tick each entity sums a push-out vector from neighbours whose personal
	bubble (radius = size * radiusFactor) it overlaps; the caller adds the
	correction to the entity's movement. Cheap, stateless, deterministic.
]]

local CrowdSeparation = {}

export type EntityPos = {
	id: string,
	x: number,
	z: number,
	size: number,
}

type Self = {
	radiusFactor: number,
	strength: number,
	accumulator: number,
	period: number,
}

CrowdSeparation.__index = CrowdSeparation

function CrowdSeparation.new(config: { radiusFactor: number?, strength: number?, hz: number? }): Self
	return setmetatable({
		radiusFactor = config.radiusFactor or 0.25,
		strength = config.strength or 1,
		accumulator = 0,
		period = 1 / (config.hz or 10),
	}, CrowdSeparation)
end

-- Returns {[id] = {x, z}} corrections to add to movement this tick.
function CrowdSeparation.compute(self: Self, entities: { EntityPos }): { [string]: { x: number, z: number } }
	local corrections: { [string]: { x: number, z: number } } = {}
	local n = #entities
	for i = 1, n do
		for j = i + 1, n do
			local a, b = entities[i], entities[j]
			local dx, dz = b.x - a.x, b.z - a.z
			local minDist = (a.size + b.size) * self.radiusFactor
			local distSq = dx * dx + dz * dz
			if distSq >= minDist * minDist then
				continue
			end
			local dist = math.sqrt(distSq)
			if dist < 1e-6 then
				dx, dz, dist = 1, 0, 1
			end
			local push = (minDist - dist) * self.strength
			local ux, uz = dx / dist * push, dz / dist * push
			local ca = corrections[a.id] or { x = 0, z = 0 }
			ca.x -= ux
			ca.z -= uz
			corrections[a.id] = ca
			local cb = corrections[b.id] or { x = 0, z = 0 }
			cb.x += ux
			cb.z += uz
			corrections[b.id] = cb
		end
	end
	return corrections
end

function CrowdSeparation.tick(self: Self, dt: number): boolean
	self.accumulator += dt
	if self.accumulator >= self.period then
		self.accumulator -= self.period
		return true
	end
	return false
end

return CrowdSeparation
