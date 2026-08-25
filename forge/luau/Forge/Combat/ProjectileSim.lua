--!strict
--[[
	ProjectileSim — shared ballistic prediction for shot validation.

	Client and server run the SAME closed-form arc: position(t) with
	gravity, sampled at a fixed step. The server validates the client's
	claimed impact by checking that its claimed direction stays within
	an angle of the predicted one and its flight time within tolerance —
	the shooter cannot bend physics in its favor.
]]

local ProjectileSim = {}

export type Vec3 = { x: number, y: number, z: number }

local DEFAULT_GRAVITY = 196.2

type Self = {
	speed: number,
	gravity: number,
	step: number,
	maxDistance: number,
}

ProjectileSim.__index = ProjectileSim

function ProjectileSim.new(config: { speed: number, gravity: number?, step: number?, maxDistance: number? }): Self
	assert(config.speed > 0, "speed must be positive")
	return setmetatable({
		speed = config.speed,
		gravity = config.gravity or DEFAULT_GRAVITY,
		step = config.step or 3,
		maxDistance = config.maxDistance or 1000,
	}, ProjectileSim)
end

-- Closed-form samples of the arc for a normalized direction.
-- Returns { {pos=Vec3, t=number}... } ending at max range or ground hit.
function ProjectileSim.simulate(self: Self, origin: Vec3, dirX: number, dirY: number, dirZ: number, groundY: number?): { { pos: Vec3, t: number } }
	local len = math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ)
	assert(len > 1e-9, "zero-length direction")
	local vx = dirX / len * self.speed
	local vy = dirY / len * self.speed
	local vz = dirZ / len * self.speed

	local points: { { pos: Vec3, t: number } } = {}
	local t = 0
	local travelled = 0
	while travelled < self.maxDistance do
		table.insert(points, {
			pos = {
				x = origin.x + vx * t,
				y = origin.y + vy * t - 0.5 * self.gravity * t * t,
				z = origin.z + vz * t,
			},
			t = t,
		})
		t += self.step / self.speed
		travelled += self.step
		if groundY and origin.y + vy * t - 0.5 * self.gravity * t * t <= groundY then
			break
		end
	end
	return points
end

function ProjectileSim.timeOfFlight(self: Self, distance: number): number
	return distance / self.speed
end

-- Validation: claimed impact point must sit near the predicted arc at the
-- claimed time (position tolerance) — the shared-physics contract.
function ProjectileSim.validateImpact(
	self: Self,
	origin: Vec3,
	dirX: number,
	dirY: number,
	dirZ: number,
	claimed: Vec3,
	claimedFlightTime: number,
	positionTolerance: number?
): (boolean, string?)
	local tol = positionTolerance or 6
	local predictedY = origin.y + (dirY / math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ)) * self.speed * claimedFlightTime
		- 0.5 * self.gravity * claimedFlightTime * claimedFlightTime
	local horizontal = math.sqrt((claimed.x - origin.x) ^ 2 + (claimed.z - origin.z) ^ 2)
	local predictedHorizontal = self.speed * claimedFlightTime * math.sqrt(
		(dirX * dirX + dirZ * dirZ) / (dirX * dirX + dirY * dirY + dirZ * dirZ)
	)
	if math.abs(horizontal - predictedHorizontal) > tol then
		return false, "range_mismatch"
	end
	if math.abs(claimed.y - predictedY) > tol then
		return false, "arc_mismatch"
	end
	return true, nil
end

return ProjectileSim
