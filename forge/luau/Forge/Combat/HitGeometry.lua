--!strict
--[[
	HitGeometry — analytical OBB / sphere / cone overlap tests.

	Volume hits do not need physics queries: projection onto an oriented
	box, sphere-sphere overlap and cone membership are closed-form math,
	which makes them deterministic, cheap for crowds, and identical on
	client preview and server authority.
]]

local HitGeometry = {}

export type Vec2 = { x: number, z: number }

local function dot(ax: number, az: number, bx: number, bz: number): number
	return ax * bx + az * bz
end

-- Point inside an XZ-oriented box (yaw radians around Y).
function HitGeometry.pointInBox(point: Vec2, center: Vec2, halfExtents: Vec2, yaw: number): boolean
	local c, s = math.cos(-yaw), math.sin(-yaw)
	local dx, dz = point.x - center.x, point.z - center.z
	local localX = dx * c - dz * s
	local localZ = dx * s + dz * c
	return math.abs(localX) <= halfExtents.x and math.abs(localZ) <= halfExtents.z
end

function HitGeometry.sphereOverlap(aCenter: Vec2, aRadius: number, bCenter: Vec2, bRadius: number): boolean
	local dx, dz = bCenter.x - aCenter.x, bCenter.z - aCenter.z
	return dx * dx + dz * dz <= (aRadius + bRadius) ^ 2
end

-- Closest point of an oriented box to a point, then distance test.
function HitGeometry.boxSphereOverlap(boxCenter: Vec2, halfExtents: Vec2, yaw: number, sphereCenter: Vec2, radius: number): boolean
	local c, s = math.cos(-yaw), math.sin(-yaw)
	local dx, dz = sphereCenter.x - boxCenter.x, sphereCenter.z - boxCenter.z
	local lx = math.clamp(dx * c - dz * s, -halfExtents.x, halfExtents.x)
	local lz = math.clamp(dx * s + dz * c, -halfExtents.z, halfExtents.z)
	local px, pz = lx - (dx * c - dz * s), lz - (dx * s + dz * c)
	return px * px + pz * pz <= radius * radius
end

-- Distance from point to oriented box surface (0 when inside).
function HitGeometry.distanceToBox(point: Vec2, center: Vec2, halfExtents: Vec2, yaw: number): number
	local c, s = math.cos(-yaw), math.sin(-yaw)
	local dx, dz = point.x - center.x, point.z - center.z
	local ox = math.abs(dx * c - dz * s) - halfExtents.x
	local oz = math.abs(dx * s + dz * c) - halfExtents.z
	return math.hypot(math.max(ox, 0), math.max(oz, 0))
end

-- Cone membership: within half-angle AND range.
function HitGeometry.inCone(origin: Vec2, dirX: number, dirZ: number, halfAngleDeg: number, range: number, point: Vec2): boolean
	local dx, dz = point.x - origin.x, point.z - origin.z
	local distSq = dx * dx + dz * dz
	if distSq > range * range then
		return false
	end
	local dist = math.sqrt(distSq)
	if dist < 1e-6 then
		return true
	end
	local cosHalf = math.cos(math.rad(halfAngleDeg))
	return (dx / dist) * dirX + (dz / dist) * dirZ >= cosHalf
end

return HitGeometry
