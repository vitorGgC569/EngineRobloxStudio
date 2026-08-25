--!strict
--[[
	GroundLocomotion — kinematic crowd movement with wall-stop and
	ground-snap, driven by injected probes.

	PathfindingService per mob does not survive a hundred agents. This
	mover walks straight, stops one margin before walls, snaps to the
	ground under the desired position (with a step-up limit), and refuses
	to walk off edges. The engine only answers two questions through the
	injected probes: "how far until a wall?" and "where is the ground?".
]]

local GroundLocomotion = {}

export type Vec3 = { x: number, y: number, z: number }

export type Probes = {
	forwardProbe: (origin: Vec3, dirX: number, dirZ: number, distance: number) -> number?,
	groundProbe: (x: number, z: number, fromY: number, maxDrop: number) -> number?,
}

export type Config = {
	speed: number,
	stepUpMax: number?,
	wallMargin: number?,
	maxDrop: number?,
	hz: number?,
}

type Self = {
	speed: number,
	stepUpMax: number,
	wallMargin: number,
	maxDrop: number,
	accumulator: number,
	period: number,
	probes: Probes,
}

GroundLocomotion.__index = GroundLocomotion

function GroundLocomotion.new(config: Config, probes: Probes): Self
	assert(config.speed > 0, "speed must be positive")
	return setmetatable({
		speed = config.speed,
		stepUpMax = config.stepUpMax or 3,
		wallMargin = config.wallMargin or 1,
		maxDrop = config.maxDrop or 30,
		accumulator = 0,
		period = 1 / (config.hz or 20),
		probes = probes,
	}, GroundLocomotion)
end

-- Advances one entity. Runs its internal probe tick at `hz` regardless of
-- frame rate; between probes it integrates the last decided velocity.
function GroundLocomotion.step(self: Self, entity: { pos: Vec3, dirX: number, dirZ: number }, dt: number): Vec3
	local pos = entity.pos
	self.accumulator += dt
	if self.accumulator < self.period then
		return pos
	end
	self.accumulator -= self.period
	if self.accumulator > self.period then
		self.accumulator = self.period
	end

	local lenSq = entity.dirX * entity.dirX + entity.dirZ * entity.dirZ
	if lenSq < 1e-8 then
		return pos
	end
	local invLen = 1 / math.sqrt(lenSq)
	local dx = entity.dirX * invLen
	local dz = entity.dirZ * invLen

	local travel = self.speed * self.period
	local allowed = self.probes.forwardProbe(pos, dx, dz, travel + self.wallMargin)
	local stepDistance = if allowed then math.min(travel, allowed - self.wallMargin) else 0

	local nx = pos.x + dx * stepDistance
	local nz = pos.z + dz * stepDistance
	local groundY = self.probes.groundProbe(nx, nz, pos.y + self.stepUpMax, self.maxDrop)

	if not groundY then
		return pos
	end
	local rise = groundY - pos.y
	if rise > self.stepUpMax then
		return pos
	end

	pos.x = nx
	pos.z = nz
	pos.y = groundY
	return pos
end

return GroundLocomotion
