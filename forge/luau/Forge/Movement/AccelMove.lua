--!strict
--[[
	AccelMove — plane-velocity movement feel with split accel/brake.

	Source-style movement: a LinearVelocity-style plane whose target is
	`desired direction * max speed`, approached with different rates for
	accelerating and stopping. Pure integrator over plain vectors so the
	client controller stays a thin shell and the feel lives in config.
]]

local AccelMove = {}

export type Vec2 = { x: number, z: number }

type Self = {
	maxSpeed: number,
	accelMoving: number,
	accelStopping: number,
	velocity: Vec2,
}

AccelMove.__index = AccelMove

function AccelMove.new(config: {
	maxSpeed: number?,
	accelMoving: number?,
	accelStopping: number?,
}): Self
	-- A negative max speed is truthy, so `or 16` would keep it. step then
	-- aims backward and the velocity points the wrong way.
	local maxSpeed = if config.maxSpeed ~= nil then config.maxSpeed else 16
	assert(
		type(maxSpeed) == "number" and maxSpeed > 0 and maxSpeed < math.huge,
		"maxSpeed must be a finite number > 0"
	)
	-- A negative moving rate is truthy, so `or 8` would keep it. step then
	-- uses 1 - exp(-rate * dt), and a negative rate pushes velocity away
	-- from the target.
	local accelMoving = if config.accelMoving ~= nil then config.accelMoving else 8
	assert(type(accelMoving) == "number" and accelMoving >= 0, "accelMoving must be a number >= 0")
	-- A negative braking rate is truthy, so `or 6` would keep it. step uses
	-- that rate when the wish is zero, and a negative factor pushes velocity
	-- away from rest.
	local accelStopping = if config.accelStopping ~= nil then config.accelStopping else 6
	assert(type(accelStopping) == "number" and accelStopping >= 0, "accelStopping must be a number >= 0")
	return setmetatable({
		maxSpeed = maxSpeed,
		accelMoving = accelMoving,
		accelStopping = accelStopping,
		velocity = { x = 0, z = 0 },
	}, AccelMove)
end

-- desiredDir need not be normalized; zero means "brake".
function AccelMove.step(self: Self, desiredDir: Vec2, dt: number): Vec2
	-- A NaN dt makes 1 - exp(-rate * dt) NaN, and every later step stays NaN.
	if type(dt) ~= "number" or dt ~= dt or dt < 0 or dt >= math.huge then
		return { x = self.velocity.x, z = self.velocity.z }
	end
	local dirLenSq = desiredDir.x * desiredDir.x + desiredDir.z * desiredDir.z
	local targetX, targetZ = 0, 0
	if dirLenSq > 1e-8 then
		local invLen = 1 / math.sqrt(dirLenSq)
		targetX = desiredDir.x * invLen * self.maxSpeed
		targetZ = desiredDir.z * invLen * self.maxSpeed
	end

	local moving = dirLenSq > 1e-8
	local rate = if moving then self.accelMoving else self.accelStopping
	local alpha = 1 - math.exp(-rate * dt)

	self.velocity.x += (targetX - self.velocity.x) * alpha
	self.velocity.z += (targetZ - self.velocity.z) * alpha
	return { x = self.velocity.x, z = self.velocity.z }
end

function AccelMove.impulse(self: Self, ix: number, iz: number): ()
	self.velocity.x += ix
	self.velocity.z += iz
end

function AccelMove.stop(self: Self): ()
	self.velocity.x = 0
	self.velocity.z = 0
end

return AccelMove
