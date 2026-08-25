--!strict
--[[
	VisualKit.Motion — analytical spring solver with motion presets.

	Closed-form damped spring (Fraktality's solution, the same math otter
	ships): given dampingRatio and frequency the position/velocity after
	dt is computed directly — no per-frame integration drift, fully
	headless-testable. Presets encode the RBX-UI vocabulary: durations
	Fast/Normal/Slow and dampings Smooth/Snappy/Soft.
]]

local Motion = {}

export type SpringState = {
	position: number,
	velocity: number,
	goal: number,
	dampingRatio: number,
	frequency: number,
}

Motion.Duration = { Fast = 0.16, Normal = 0.2, Slow = 0.24 }
Motion.Damping = { Smooth = 1.0, Snappy = 0.85, Soft = 0.9 }

function Motion.newSpring(goal: number, options: { dampingRatio: number?, frequency: number?, velocity: number? }?): SpringState
	local opts = options or {}
	return {
		position = goal,
		velocity = opts.velocity or 0,
		goal = goal,
		dampingRatio = opts.dampingRatio or Motion.Damping.Smooth,
		frequency = opts.frequency or 4,
	}
end

function Motion.setGoal(spring: SpringState, goal: number): ()
	spring.goal = goal
end

-- Analytic step: exact solution for a linear second-order system.
function Motion.step(spring: SpringState, dt: number): number
	local x = spring.position - spring.goal
	local v = spring.velocity
	local zeta = spring.dampingRatio
	local omega = spring.frequency * 2 * math.pi

	local expTerm = math.exp(-zeta * omega * dt)
	local newPos: number
	local newVel: number

	if zeta < 1 then
		-- underdamped
		local omegaD = omega * math.sqrt(1 - zeta * zeta)
		local cosT = math.cos(omegaD * dt)
		local sinT = math.sin(omegaD * dt)
		local A = x
		local B = (v + zeta * omega * x) / omegaD
		local dA = -zeta * omega * A + B * omegaD
		local dB = -zeta * omega * B - A * omegaD
		newPos = expTerm * (A * cosT + B * sinT) + spring.goal
		newVel = expTerm * (dA * cosT + dB * sinT)
	elseif zeta == 1 then
		-- critically damped
		local A = x
		local B = v + omega * x
		newPos = expTerm * (A + B * dt) + spring.goal
		newVel = expTerm * (B - omega * (A + B * dt))
	else
		-- overdamped
		local zeta2 = math.sqrt(zeta * zeta - 1)
		local r1 = -omega * (zeta - zeta2)
		local r2 = -omega * (zeta + zeta2)
		local B = (v - r1 * x) / (r2 - r1)
		local A = x - B
		newPos = A * math.exp(r1 * dt) + B * math.exp(r2 * dt) + spring.goal
		newVel = A * r1 * math.exp(r1 * dt) + B * r2 * math.exp(r2 * dt)
	end

	spring.position = newPos
	spring.velocity = newVel

	if math.abs(newVel) < 1e-3 and math.abs(newPos - spring.goal) < 1e-2 then
		spring.position = spring.goal
		spring.velocity = 0
	end
	return spring.position
end

-- hoverPressScale from RBX-UI: target scale for the interaction state.
function Motion.hoverPressScale(hovered: boolean, pressed: boolean, disabled: boolean): number
	if disabled then
		return 1
	end
	if pressed then
		return 0.97
	elseif hovered then
		return 1.02
	end
	return 1
end

-- ============================ gesture easings ============================
-- TweenInfo-equivalent descriptors per gesture intention; presentation
-- maps {style, direction} to Enum.EasingStyle/Direction.
Motion.Easing = {
	hover = { duration = 0.2, style = "Quart", direction = "Out" },
	click = { duration = 0.1, style = "Quart", direction = "Out" },
	slide = { duration = 0.3, style = "Quart", direction = "Out" },
	pop = { duration = 0.4, style = "Back", direction = "Out" },
	fade = { duration = 0.24, style = "Sine", direction = "InOut" },
}

function Motion.easingFor(gesture: string): { duration: number, style: string, direction: string }
	local preset = Motion.Easing[gesture]
	assert(preset, ("unknown gesture %q"):format(gesture))
	return preset
end

-- ============================== group motor ==============================
-- N springs advanced by one tick call; springs are keyed so screens can
-- animate many properties without N RunService connections.
export type GroupMotor = { [string]: SpringState }

function Motion.newGroupMotor(): GroupMotor
	return {}
end

function Motion.groupAdd(motor: GroupMotor, key: string, goal: number, options: { dampingRatio: number?, frequency: number? }): ()
	motor[key] = Motion.newSpring(goal, options)
end

function Motion.groupSetGoal(motor: GroupMotor, key: string, goal: number): ()
	local spring = motor[key]
	if spring then
		Motion.setGoal(spring, goal)
	end
end

-- Advances every spring once; returns { key = position } for consumers.
function Motion.groupStep(motor: GroupMotor, dt: number): { [string]: number }
	local out: { [string]: number } = {}
	for key, spring in motor do
		out[key] = Motion.step(spring, dt)
	end
	return out
end

function Motion.groupSettled(motor: GroupMotor): boolean
	for _, spring in motor do
		if math.abs(spring.velocity) >= 1e-3 or math.abs(spring.position - spring.goal) >= 1e-2 then
			return false
		end
	end
	return true
end

return Motion
