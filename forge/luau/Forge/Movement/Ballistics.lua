--!strict
--[[
	Ballistics — shared spread cone and trajectory validation.

	The anti-cheat rule from production survival games: the aim the
	client shows is a projection of the cone the server actually rolls.
	Sampling and validation live here, shared by shooter, tracer and
	server, so they can never disagree.
]]

local Ballistics = {}

export type Vec3 = { x: number, y: number, z: number }

local function normalize(v: Vec3): Vec3
	local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	assert(len > 1e-9, "zero-length direction")
	return { x = v.x / len, y = v.y / len, z = v.z / len }
end

function Ballistics.sampleCone(baseDir: Vec3, spreadDeg: number, rng: () -> number): Vec3
	local dir = normalize(baseDir)
	if spreadDeg <= 0 then
		return dir
	end
	local angle = math.rad(spreadDeg) * math.sqrt(rng())
	local around = rng() * math.pi * 2

	local up = if math.abs(dir.y) > 0.99 then { x = 1, y = 0, z = 0 } else { x = 0, y = 1, z = 0 }
	local rightX = dir.y * up.z - dir.z * up.y
	local rightY = dir.z * up.x - dir.x * up.z
	local rightZ = dir.x * up.y - dir.y * up.x
	local rl = math.sqrt(rightX * rightX + rightY * rightY + rightZ * rightZ)
	rightX, rightY, rightZ = rightX / rl, rightY / rl, rightZ / rl

	local trueUpX = dir.z * rightY - dir.y * rightZ
	local trueUpY = dir.x * rightZ - dir.z * rightX
	local trueUpZ = dir.y * rightX - dir.x * rightY

	local cosA, sinA = math.cos(angle), math.sin(angle)
	local cosB, sinB = math.cos(around), math.sin(around)

	return normalize({
		x = dir.x * cosA + (rightX * cosB + trueUpX * sinB) * sinA,
		y = dir.y * cosA + (rightY * cosB + trueUpY * sinB) * sinA,
		z = dir.z * cosA + (rightZ * cosB + trueUpZ * sinB) * sinA,
	})
end

-- True when actual stays within maxDeg of predicted (7 deg default).
function Ballistics.withinAngle(predicted: Vec3, actual: Vec3, maxDeg: number?): boolean
	local a = normalize(predicted)
	local b = normalize(actual)
	local dot = math.clamp(a.x * b.x + a.y * b.y + a.z * b.z, -1, 1)
	local angle = math.deg(math.acos(dot))
	return angle <= (maxDeg or 7)
end

-- Time-of-flight for gravity-free travel; callers compare against elapsed.
function Ballistics.timeOfFlight(distance: number, speed: number): number
	assert(speed > 0, "speed must be positive")
	return distance / speed
end

-- Gravity drop over flight time (world units), for predictive arcs.
function Ballistics.gravityDrop(distance: number, speed: number, gravity: number?): number
	local t = Ballistics.timeOfFlight(distance, speed)
	local g = gravity or 196.2
	return 0.5 * g * t * t
end

return Ballistics
