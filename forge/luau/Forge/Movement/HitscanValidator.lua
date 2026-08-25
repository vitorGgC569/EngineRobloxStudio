--!strict
--[[
	HitscanValidator — server-side validation for instant-shot weapons.

	The client reports "I fired from here along this ray"; the server
	decides truth. Cooldown per shooter, range check against the claimed
	hit point, and line-of-sight through an injected probe. The visual
	tracer is the client's business; this module only says yes or no.
]]

local HitscanValidator = {}

type Self = {
	range: number,
	cooldown: number,
	lastFireAt: { [string]: number },
	clock: () -> number,
	lineOfSight: ((ox: number, oy: number, oz: number, hx: number, hy: number, hz: number) -> boolean)?,
}

HitscanValidator.__index = HitscanValidator

function HitscanValidator.new(config: {
	range: number?,
	cooldown: number?,
	clock: (() -> number)?,
	lineOfSight: ((number, number, number, number, number, number) -> boolean)?,
}): Self
	return setmetatable({
		range = config.range or 1000,
		cooldown = config.cooldown or 0.1,
		lastFireAt = {},
		clock = config.clock or os.clock,
		lineOfSight = config.lineOfSight,
	}, HitscanValidator)
end

-- Rate gate; returns false while cooling down.
function HitscanValidator.tryFire(self: Self, shooterKey: string): (boolean, string?)
	local now = self.clock()
	local last = self.lastFireAt[shooterKey]
	if last and now - last < self.cooldown then
		return false, "cooldown"
	end
	self.lastFireAt[shooterKey] = now
	return true, nil
end

-- Validates a claimed hit: within range and visible.
function HitscanValidator.checkHit(
	self: Self,
	origin: { x: number, y: number, z: number },
	hitPoint: { x: number, y: number, z: number }
): (boolean, string?)
	local dx, dy, dz = hitPoint.x - origin.x, hitPoint.y - origin.y, hitPoint.z - origin.z
	local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
	if dist > self.range then
		return false, "out_of_range"
	end
	local los = self.lineOfSight
	if los and not los(origin.x, origin.y, origin.z, hitPoint.x, hitPoint.y, hitPoint.z) then
		return false, "no_line_of_sight"
	end
	return true, nil
end

return HitscanValidator
