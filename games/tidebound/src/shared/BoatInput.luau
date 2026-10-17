--!strict
--[[
	BoatInput — raw device state in, one helm intent out.

	Keyboard, gamepad and touch disagree about what a stick *is*: keys are
	booleans, a thumbstick carries a sign convention, a finger is a pixel
	delta. The helm must not care, so the conversion lives here and this is
	the only place it is tested.

	Pure on purpose: no services, no connections, no engine tables. The same
	numbers the harness runs are the numbers the helm runs.
]]

local BoatInput = {}

export type Axes = {
	throttle: number, -- -REVERSE_SCALE..1, forward positive
	steer: number, -- -1..1, positive turns left (the seat's positive yaw)
}

BoatInput.DEADZONE = 0.16
BoatInput.CURVE = 1.6
BoatInput.REVERSE_SCALE = 0.55

--: Sign-preserving response curve: gentler near the centre, full at the edge.
--: A boat with hair-trigger throttle at 5% stick is not a boat.
function BoatInput.curve(value: number): number
	local magnitude = math.clamp(math.abs(value), 0, 1) ^ BoatInput.CURVE
	return if value < 0 then -magnitude else magnitude
end

--: The keyboard keeps exactly the feel the helm always had: W full ahead, S
--: reverse scaled to 0.55, A/D full-rate steer. Deliberately no curve.
function BoatInput.fromKeyboard(forward: boolean, back: boolean, left: boolean, right: boolean): Axes
	local throttle = 0
	if forward then
		throttle += 1
	end
	if back then
		throttle -= BoatInput.REVERSE_SCALE
	end
	local steer = 0
	if left then
		steer += 1
	end
	if right then
		steer -= 1
	end
	return { throttle = throttle, steer = steer }
end

--[[
	Semantic stick axes: x right-positive, y up (forward) positive. That is
	the gamepad convention — pushing the stick forward reports +Y — and every
	screen-space flip stays inside `stickFromDrag`, so no caller has to
	remember which way a finger runs.

	Radial deadzone: inside the ring the stick is silent; outside it, the
	deadzone edge maps to zero so there is no jump when control engages.
]]
function BoatInput.fromStick(x: number, y: number): Axes
	x = math.clamp(x, -1, 1)
	y = math.clamp(y, -1, 1)
	local magnitude = math.sqrt(x * x + y * y)
	if magnitude <= BoatInput.DEADZONE then
		return { throttle = 0, steer = 0 }
	end
	local strength = BoatInput.curve((math.min(magnitude, 1) - BoatInput.DEADZONE) / (1 - BoatInput.DEADZONE))
	local nx, ny = x / magnitude, y / magnitude
	local throttle = ny * strength
	if throttle < 0 then
		throttle *= BoatInput.REVERSE_SCALE
	end
	return { throttle = throttle, steer = -nx * strength }
end

--: A touch drag, in screen pixels, against the ring's radius. Screen y grows
--: downward, a helm throttle grows upward; the flip happens here and only here.
function BoatInput.stickFromDrag(dx: number, dy: number, radius: number): (number, number)
	return math.clamp(dx / radius, -1, 1), math.clamp(-dy / radius, -1, 1)
end

export type Sources = {
	keys: { forward: boolean, back: boolean, left: boolean, right: boolean }?,
	stick: { x: number, y: number }?,
	touch: { x: number, y: number }?,
}

--[[
	One intent per frame. A finger that is down is driving (even at the ring's
	centre — coasting is a decision); then a deflected gamepad stick; then the
	keys. Touch outranks because it can only be present while a human is
	holding the helm stick, which is the least ambiguous statement of intent
	the game can receive.
]]
function BoatInput.resolve(sources: Sources): Axes
	if sources.touch then
		return BoatInput.fromStick(sources.touch.x, sources.touch.y)
	end
	local stick = sources.stick
	if stick and (stick.x * stick.x + stick.y * stick.y) > BoatInput.DEADZONE * BoatInput.DEADZONE then
		return BoatInput.fromStick(stick.x, stick.y)
	end
	local keys = sources.keys
	if keys then
		return BoatInput.fromKeyboard(keys.forward, keys.back, keys.left, keys.right)
	end
	return { throttle = 0, steer = 0 }
end

return BoatInput
