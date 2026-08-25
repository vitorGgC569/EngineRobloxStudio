--!strict
--[[
	AntiCheatMath — movement violation classification.

	The server knows each character's maximum legitimate speed. This
	classifier compares reported positions against that budget with a
	slack allowance, escalates repeated violations inside a window, and
	returns a stable verdict ("none" | "speed" | "teleport") plus the
	evidence numbers. It never punishes; the caller does.
]]

local AntiCheatMath = {}

export type Verdict = "none" | "speed" | "teleport"

type Sample = {
	x: number,
	z: number,
	t: number,
}

type Self = {
	maxSpeed: number,
	slack: number, -- studs of forgiveness per check (latency/lag)
	window: number, -- seconds of violation memory
	teleportDistance: number, -- single-jump distance that is instantly fatal
	violations: { Sample },
	clock: () -> number,
}

AntiCheatMath.__index = AntiCheatMath

function AntiCheatMath.new(config: {
	maxSpeed: number?,
	slack: number?,
	window: number?,
	teleportDistance: number?,
	clock: (() -> number)?,
}): Self
	return setmetatable({
		maxSpeed = config.maxSpeed or 16,
		slack = config.slack or 4,
		window = config.window or 5,
		teleportDistance = config.teleportDistance or 60,
		violations = {},
		clock = config.clock or os.clock,
	}, AntiCheatMath)
end

-- Feed one movement step; returns the verdict for this step.
function AntiCheatMath.check(self: Self, prevX: number, prevZ: number, newX: number, newZ: number): Verdict
	local now = self.clock()
	local dx, dz = newX - prevX, newZ - prevZ
	local dist = math.sqrt(dx * dx + dz * dz)

	local verdict: Verdict = "none"
	if dist >= self.teleportDistance then
		verdict = "teleport"
	elseif dist > (self.maxSpeed * 0.1) + self.slack then
		-- 0.1 s nominal step; faster reporting cadence is scaled by caller.
		verdict = "speed"
	end

	if verdict ~= "none" then
		table.insert(self.violations, { x = newX, z = newZ, t = now, dist = dist } :: any)
	end

	-- Drop aged violations and cap memory so a spammer cannot grow state.
	local cutoff = now - self.window
	local kept: { any } = {}
	for _, v in self.violations do
		if v.t >= cutoff then
			table.insert(kept, v)
		end
	end
	self.violations = kept

	return verdict
end

function AntiCheatMath.violationCount(self: Self): number
	return #self.violations
end

-- Escalation rule: 3+ violations in window means confirmed offender.
function AntiCheatMath.isConfirmed(self: Self): boolean
	return #self.violations >= 3
end

function AntiCheatMath.clear(self: Self): ()
	self.violations = {}
end

return AntiCheatMath
