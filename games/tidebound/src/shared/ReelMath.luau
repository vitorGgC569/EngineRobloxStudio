--!strict
--[[
	ReelMath — the fight at the end of the line, as arithmetic.

	The minigame is: a safety bar the fish drags around, a tension marker the
	player drives by holding or releasing, and two meters — progress and line
	integrity — that race each other. Everything here is a pure function of
	`(state, input, dt, params)`, so the client runs it for feel and the test
	suite runs the same function with a scripted input to prove the hardest
	fish is merely hard and not impossible.

	The parameters travel with the bite: seed, difficulty, duration. The same
	seed draws the same fish dance on every machine, and the server never has
	to simulate anything to know the fight was fair.
]]

local ReelMath = {}

export type Params = {
	seed: number,
	difficulty: number, -- 0.3 (small fish, strong rod) .. 1.5 (record fish)
	duration: number,   -- outer clock, seconds
}

local TAU = math.pi * 2

--: Deterministic pseudo-noise for one seed. SplitMix-style; small and stable.
local function hash(seed: number, salt: number): number
	local x = (seed * 2654435761 + salt * 2246822519) % 4294967296
	x = (x * 1664525 + 1013904223) % 4294967296
	return x / 4294967296
end

--: Where the safe band's centre is at time t.
function ReelMath.zoneCentre(params: Params, t: number): number
	local d = params.difficulty
	local phase1 = hash(params.seed, 1) * TAU
	local phase2 = hash(params.seed, 2) * TAU
	local w1 = 0.75 + 0.35 * d
	local w2 = 1.6 + 0.8 * d
	local swing1 = 0.24 * math.sin(w1 * t + phase1)
	local swing2 = 0.12 * math.sin(w2 * t + phase2)
	return math.clamp(0.5 + swing1 + swing2, 0.12, 0.88)
end

--: Half-width of the band. Better rod (lower difficulty) means a wider band.
function ReelMath.zoneHalf(params: Params): number
	return math.max(0.30 - 0.115 * params.difficulty, 0.10)
end

--: How many seconds in the band it takes to land the fish.
function ReelMath.requiredProgress(params: Params): number
	return 1.5 + 2.0 * params.difficulty
end

--: Integrity lost per second outside the band.
function ReelMath.strainRate(params: Params): number
	return 0.13 + 0.17 * params.difficulty
end

function ReelMath.new(params: Params): any
	return {
		params = params,
		t = 0,
		marker = 0.35,
		velocity = 0,
		progress = 0,
		integrity = 1,
		done = false,
		won = false,
		reason = nil,
	}
end

--[[
	One tick. `hold` is whether the player is pulling. Mutates and returns the
	state so a caller can chain calls without rebinding.
]]
function ReelMath.step(state: any, hold: boolean, dt: number): any
	if state.done then
		return state
	end
	local params = state.params
	local d = params.difficulty

	state.t += dt
	local centre = ReelMath.zoneCentre(params, state.t)
	local half = ReelMath.zoneHalf(params)

	--: Pull accelerates toward 1, release accelerates toward 0, and both drag.
	local accel = if hold then (3.4 - 0.5 * d) else -2.1
	state.velocity = (state.velocity + accel * dt) * math.exp(-4.6 * dt)
	state.marker = state.marker + state.velocity * dt
	if state.marker <= 0 then
		state.marker = 0
		state.velocity = math.max(state.velocity, 0)
	elseif state.marker >= 1 then
		state.marker = 1
		state.velocity = math.min(state.velocity, 0)
	end

	local inBand = math.abs(state.marker - centre) <= half
	if inBand then
		state.progress += (dt / ReelMath.requiredProgress(params)) * (1 + 0.04 * d)
		state.integrity = math.min(1, state.integrity + dt * 0.015)
	else
		state.integrity -= dt * ReelMath.strainRate(params)
	end

	if state.progress >= 1 then
		state.done, state.won, state.reason = true, true, "landed"
	elseif state.integrity <= 0 then
		state.integrity = 0
		state.done, state.won, state.reason = true, false, "snapped"
	elseif state.t >= params.duration then
		state.done, state.won, state.reason = true, false, "escaped"
	end
	return state
end

--[[
	A competent bot that plays by the same rules a person does.

	Used by the tests to prove a fight is fair at the difficulty floor and at
	the ceiling. It leads the band a little, which is what a player learns to
	do within three catches.
]]
function ReelMath.autoplay(params: Params, stepSeconds: number?): any
	local dt = stepSeconds or 1 / 60
	local state = ReelMath.new(params)
	while not state.done do
		local centre = ReelMath.zoneCentre(params, state.t)
		local ahead = ReelMath.zoneCentre(params, state.t + 0.12)
		local target = centre + (ahead - centre) * 0.8
		local hold = state.marker < target - 0.005
		ReelMath.step(state, hold, dt)
	end
	return state
end

return ReelMath
