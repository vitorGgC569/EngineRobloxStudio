--!strict
--[[
	Spring — damped harmonic motion for numbers and Vector3.

	Why this exists: tweens are for things that must arrive on a schedule (a
	menu sliding in). Springs are for things that must feel physical (a camera
	catching up, a weapon settling after a swing, a health bar overshooting).
	Almost everything an agent reaches for a tween to do, in gameplay, wants a
	spring instead — and gets a better result for less code, because a spring
	survives being interrupted mid-flight.

		local s = Spring.new(0, { frequency = 4, damping = 0.7 })
		s:impulse(12)          -- kick it
		s.goal = 30            -- retarget any time
		local v = s:step(dt)   -- integrate, returns current value
]]

local Spring = {}
Spring.__index = Spring

export type Config = {
	frequency: number?, -- oscillations per second (stiffness)
	damping: number?, -- 1 = critically damped, <1 springy, >1 sluggish
}

local function zeroLike(value: any): any
	if typeof(value) == "Vector3" then
		return Vector3.zero
	elseif typeof(value) == "Vector2" then
		return Vector2.zero
	end
	return 0
end

function Spring.new(initial: any, config: Config?): any
	local cfg = config or {}
	return setmetatable({
		value = initial,
		goal = initial,
		velocity = zeroLike(initial),
		frequency = cfg.frequency or 5,
		damping = cfg.damping or 1,
	}, Spring)
end

-- Semi-implicit Euler, clamped so a frame hitch cannot make it explode.
-- Long frames are subdivided rather than integrated in one leap.
function Spring:step(dt: number): any
	if dt <= 0 then
		return self.value
	end
	local maxStep = 1 / 90
	local remaining = math.min(dt, 0.25)

	local omega = self.frequency * 2 * math.pi
	local zeta = self.damping

	while remaining > 0 do
		local h = math.min(maxStep, remaining)
		remaining -= h

		local displacement = self.value - self.goal
		local accel = -(omega * omega) * displacement - (2 * zeta * omega) * self.velocity
		self.velocity += accel * h
		self.value += self.velocity * h
	end

	return self.value
end

function Spring:impulse(amount: any)
	self.velocity += amount
end

-- Teleport: no motion, no overshoot. Use on respawn, never mid-animation.
function Spring:reset(value: any?)
	if value ~= nil then
		self.value = value
		self.goal = value
	else
		self.value = self.goal
	end
	self.velocity = zeroLike(self.value)
end

function Spring:settled(epsilon: number?): boolean
	local eps = epsilon or 0.01
	local d = self.value - self.goal
	local dist = typeof(d) == "number" and math.abs(d) or (d :: any).Magnitude
	local speed = typeof(self.velocity) == "number" and math.abs(self.velocity) or (self.velocity :: any).Magnitude
	return dist < eps and speed < eps
end

return Spring
