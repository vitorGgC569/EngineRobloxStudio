--!strict
--[[
	StrafeJump — quake-style air acceleration.

	Ground movement is Humanoid's job; air control is this module: the
	classic strafe mechanic where pressing A/D while airborne adds speed
	along the wish direction via dot-product acceleration, clamped so it
	adds velocity instead of multiplying it.
]]

local StrafeJump = {}

export type Vec2 = { x: number, z: number }

type Self = {
	airAccelerate: number, -- accel units per second
	maxAirWishSpeed: number, -- cap for the dot-product gain per tick
}

StrafeJump.__index = StrafeJump

function StrafeJump.new(config: { airAccelerate: number?, maxAirWishSpeed: number? }): Self
	return setmetatable({
		airAccelerate = config.airAccelerate or 40,
		maxAirWishSpeed = config.maxAirWishSpeed or 1.2,
	}, StrafeJump)
end

-- velocity and wishDir are unit-scaled horizontal vectors; returns new velocity.
function StrafeJump.step(self: Self, velocity: Vec2, wishDir: Vec2, dt: number): Vec2
	local wishLen = math.sqrt(wishDir.x * wishDir.x + wishDir.z * wishDir.z)
	if wishLen < 1e-6 then
		return velocity
	end
	local wx, wz = wishDir.x / wishLen, wishDir.z / wishLen

	local currentSpeed = velocity.x * wx + velocity.z * wz -- projection on wish dir
	local addSpeed = self.maxAirWishSpeed - currentSpeed
	if addSpeed <= 0 then
		return velocity
	end

	local accelSpeed = math.min(self.airAccelerate * self.maxAirWishSpeed * dt, addSpeed)
	return { x = velocity.x + wx * accelSpeed, z = velocity.z + wz * accelSpeed }
end

return StrafeJump
