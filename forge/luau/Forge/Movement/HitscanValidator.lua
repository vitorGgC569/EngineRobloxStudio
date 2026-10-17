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
	-- A negative cooldown is truthy, so `or 0.1` would keep it. After the
	-- first shot the elapsed time is 0, and 0 < -1 is false, so the gate
	-- never blocks. math.huge would also never open again.
	local cooldown = if config.cooldown ~= nil then config.cooldown else 0.1
	assert(
		type(cooldown) == "number" and cooldown >= 0 and cooldown < math.huge,
		"cooldown must be a finite number >= 0"
	)
	-- A negative range is truthy, so `or 1000` would keep it. Every distance
	-- is then greater than -1, and a point-blank hit is out of range.
	local range = if config.range ~= nil then config.range else 1000
	assert(
		type(range) == "number" and range >= 0 and range < math.huge,
		"range must be a finite number >= 0"
	)
	return setmetatable({
		range = range,
		cooldown = cooldown,
		lastFireAt = {},
		clock = config.clock or os.clock,
		lineOfSight = config.lineOfSight,
	}, HitscanValidator)
end

-- Rate gate; returns false while cooling down.
function HitscanValidator.tryFire(self: Self, shooterKey: string): (boolean, string?)
	assert(type(shooterKey) == "string" and #shooterKey > 0, "shooterKey must be a non-empty string")
	local now = self.clock()
	-- NaN < cooldown is false, so a bad clock would fire and then poison
	-- lastFireAt. Every later real timestamp would also be NaN.
	if type(now) ~= "number" or now ~= now or now <= -math.huge or now >= math.huge then
		return false, "bad_clock"
	end
	local last = self.lastFireAt[shooterKey]
	if last and now - last < self.cooldown then
		return false, "cooldown"
	end
	self.lastFireAt[shooterKey] = now
	return true, nil
end

-- Validates a claimed hit: within range and visible.
-- NaN > range is false, so a bad coordinate would be accepted as a hit.
local function finiteCoordinate(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

function HitscanValidator.checkHit(
	self: Self,
	origin: { x: number, y: number, z: number },
	hitPoint: { x: number, y: number, z: number }
): (boolean, string?)
	if not (
		finiteCoordinate(origin.x) and finiteCoordinate(origin.y) and finiteCoordinate(origin.z)
		and finiteCoordinate(hitPoint.x) and finiteCoordinate(hitPoint.y) and finiteCoordinate(hitPoint.z)
	) then
		return false, "bad_point"
	end
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
