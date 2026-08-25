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
	return setmetatable({
		maxSpeed = config.maxSpeed or 16,
		accelMoving = config.accelMoving or 8,
		accelStopping = config.accelStopping or 6,
		velocity = { x = 0, z = 0 },
	}, AccelMove)
end

-- desiredDir need not be normalized; zero means "brake".
function AccelMove.step(self: Self, desiredDir: Vec2, dt: number): Vec2
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
