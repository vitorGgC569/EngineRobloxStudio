--!strict
--[[
	Interactables — physics playground models with server-owned state.

	Spinners, swings, doors and slides are the same shape: a numeric core
	(push, friction, caps) that the caller wires to constraints and
	prompts. These models hold the truth; WorldKit renders it.
]]

local Interactables = {}

-- SpinPlatform: pushes add angular speed; friction decays it each second.
export type Spinner = {
	pushForce: number,
	maxSpeed: number,
	frictionPerSecond: number,
	stopThreshold: number,
	angularSpeed: number,
}

function Interactables.newSpinner(config: { pushForce: number?, maxSpeed: number?, frictionPerSecond: number?, stopThreshold: number? }): Spinner
	return {
		pushForce = config.pushForce or 0.6,
		maxSpeed = config.maxSpeed or 8,
		frictionPerSecond = config.frictionPerSecond or math.log(1 / 0.96),
		stopThreshold = config.stopThreshold or 0.05,
		angularSpeed = 0,
	}
end

function Interactables.pushSpinner(spinner: Spinner): ()
	spinner.angularSpeed = math.min(spinner.angularSpeed + spinner.pushForce, spinner.maxSpeed)
end

function Interactables.updateSpinner(spinner: Spinner, dt: number): number
	spinner.angularSpeed -= spinner.angularSpeed * spinner.frictionPerSecond * dt
	if spinner.angularSpeed < spinner.stopThreshold then
		spinner.angularSpeed = 0
	end
	return spinner.angularSpeed
end

-- PendulumSeat: impulses along current swing direction, capped.
export type Pendulum = {
	pushImpulse: number,
	maxSwingSpeed: number,
	dampingPerSecond: number,
	angleVel: number,
}

function Interactables.newPendulum(config: { pushImpulse: number?, maxSwingSpeed: number?, dampingPerSecond: number? }): Pendulum
	return {
		pushImpulse = config.pushImpulse or 4,
		maxSwingSpeed = config.maxSwingSpeed or 12,
		dampingPerSecond = config.dampingPerSecond or 0.15,
		angleVel = 0,
	}
end

function Interactables.pushPendulum(pendulum: Pendulum, currentDirectionSign: number): ()
	local impulse = pendulum.pushImpulse * (if currentDirectionSign >= 0 then 1 else -1)
	pendulum.angleVel = math.clamp(pendulum.angleVel + impulse, -pendulum.maxSwingSpeed, pendulum.maxSwingSpeed)
end

function Interactables.updatePendulum(pendulum: Pendulum, dt: number): number
	pendulum.angleVel -= pendulum.angleVel * pendulum.dampingPerSecond * dt
	return pendulum.angleVel
end

-- ProximityDoorModel: opens when someone is near; progress drives tweens.
export type Door = {
	openDistance: number,
	progress: number,
	speed: number,
	isOpen: boolean,
}

function Interactables.newDoor(config: { openDistance: number?, openSeconds: number? }): Door
	return {
		openDistance = config.openDistance or 10,
		progress = 0,
		speed = 1 / (config.openSeconds or 0.6),
		isOpen = false,
	}
end

function Interactables.updateDoor(door: Door, nearestCharacterDistance: number?, dt: number): boolean
	local wantOpen = nearestCharacterDistance ~= nil and nearestCharacterDistance <= door.openDistance
	if wantOpen then
		door.progress = math.min(1, door.progress + door.speed * dt)
	else
		door.progress = math.max(0, door.progress - door.speed * dt)
	end
	door.isOpen = door.progress >= 1
	return wantOpen
end

-- RailSlide: periodic impulses while riding; walkspeed bookkeeping outside.
export type RailSlide = {
	force: number,
	interval: number,
	maxSpeed: number,
	accumulator: number,
}

function Interactables.newRailSlide(config: { force: number?, interval: number?, maxSpeed: number? }): RailSlide
	return {
		force = config.force or 40,
		interval = config.interval or 0.1,
		maxSpeed = config.maxSpeed or 60,
		accumulator = 0,
	}
end

-- Returns the impulse magnitude to apply this frame (0 when idle).
function Interactables.updateRailSlide(rail: RailSlide, isRiding: boolean, dt: number, currentSpeed: number): number
	if not isRiding then
		rail.accumulator = 0
		return 0
	end
	rail.accumulator += dt
	if rail.accumulator < rail.interval then
		return 0
	end
	rail.accumulator -= rail.interval
	if currentSpeed >= rail.maxSpeed then
		return 0
	end
	return rail.force
end

return Interactables
