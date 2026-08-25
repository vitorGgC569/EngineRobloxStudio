--!strict
--[[
	TraitBrain — weighted-trait AI brain with state hysteresis.

	Each mob rolls its own personality (weights for wander / chase / flee /
	circle) and re-decides on a slow tick. The hysteresis rule from
	production games: once a state is chosen it holds for at least
	minDwell seconds, and the target is only lost past loseSightRange —
	this kills the flip-flopping that makes crowds look broken.

	Pure: positions are plain tables, randomness comes from the seeded
	generator, so a recorded crowd replays identically.
]]

local Rng = require(script.Parent.Parent.Core.Rng)

local TraitBrain = {}

export type Traits = {
	chaseWeight: number?,
	fleeWeight: number?,
	circleWeight: number?,
	wanderWeight: number?,
	detectRange: number,
	loseSightRange: number?,
	fleeDistance: number?,
	preferDistance: number?,
	minDwell: number?,
}

export type Vec2 = { x: number, z: number }

type Target = {
	key: string,
	pos: Vec2,
	dist: number,
}

type BrainState = {
	currentState: string,
	stateUntil: number,
	targetKey: string?,
	circleSign: number,
}

type Self = {
	traits: {
		chase: number,
		flee: number,
		circle: number,
		wander: number,
		detectRange: number,
		loseSightRange: number,
		fleeDistance: number,
		preferDistance: number,
		minDwell: number,
	},
	rng: Rng.Generator,
}

TraitBrain.__index = TraitBrain

function TraitBrain.new(config: { traits: Traits, rngSeed: number? }): Self
	local t = config.traits or {} :: any
	return setmetatable({
		traits = {
			chase = t.chaseWeight or 1,
			flee = t.fleeWeight or 0,
			circle = t.circleWeight or 0.5,
			wander = t.wanderWeight or 0.5,
			detectRange = t.detectRange or 40,
			loseSightRange = t.loseSightRange or (t.detectRange or 40) * 1.4,
			fleeDistance = t.fleeDistance or 12,
			preferDistance = t.preferDistance or 10,
			minDwell = t.minDwell or 0.45,
		},
		rng = Rng.xorshift(config.rngSeed),
	}, TraitBrain)
end

function TraitBrain.initialState(self: Self): BrainState
	return { currentState = "wander", stateUntil = 0, targetKey = nil, circleSign = if self.rng() < 0.5 then -1 else 1 }
end

local function nearestTarget(targets: { Target }): Target?
	local best: Target? = nil
	for _, target in targets do
		if not best or target.dist < best.dist then
			best = target
		end
	end
	return best
end

local function normalized(dx: number, dz: number): Vec2
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 1e-6 then
		return { x = 0, z = 0 }
	end
	return { x = dx / len, z = dz / len }
end

function TraitBrain.decide(self: Self, mobPos: Vec2, targets: { Target }, state: BrainState, now: number): { nextState: string, target: Target?, moveDir: Vec2 }
	local traits = self.traits
	local nearest = nearestTarget(targets)
	local visible = nearest and nearest.dist <= traits.detectRange

	if not visible and nearest and nearest.dist > traits.loseSightRange then
		state.targetKey = nil
	elseif visible and nearest then
		state.targetKey = nearest.key
	end

	local remembered = nil :: Target?
	if state.targetKey and nearest and nearest.key == state.targetKey then
		remembered = nearest
	end

	local canChange = now >= state.stateUntil
	local nextName = state.currentState
	local chosen: Target? = remembered

	if canChange then
		local weights: { number } = {}
		local names: { string } = {}
		if remembered then
			if remembered.dist < traits.fleeDistance and traits.flee > 0 then
				table.insert(names, "flee")
				table.insert(weights, traits.flee)
			else
				table.insert(names, "chase")
				table.insert(weights, traits.chase)
				table.insert(names, "circle")
				table.insert(weights, traits.circle)
			end
		end
		table.insert(names, "wander")
		table.insert(weights, traits.wander)
		nextName = names[Rng.weightedPick(self.rng, weights)]
		if nextName ~= state.currentState then
			state.currentState = nextName
			state.stateUntil = now + traits.minDwell
			if self.rng() < 0.5 then
				state.circleSign *= -1
			end
		end
	end

	local moveDir = { x = 0, z = 0 }
	local anchor = remembered or nearest
	if nextName == "chase" and anchor then
		moveDir = normalized(anchor.pos.x - mobPos.x, anchor.pos.z - mobPos.z)
	elseif nextName == "flee" and anchor then
		moveDir = normalized(mobPos.x - anchor.pos.x, mobPos.z - anchor.pos.z)
	elseif nextName == "circle" and anchor then
		local toX, toZ = anchor.pos.x - mobPos.x, anchor.pos.z - mobPos.z
		local radial = normalized(toX, toZ)
		local dist = math.sqrt(toX * toX + toZ * toZ)
		local radialScale = if dist > traits.preferDistance then 0.35 elseif dist < traits.preferDistance * 0.7 then -0.5 else 0
		moveDir = {
			x = -radial.z * state.circleSign + radial.x * radialScale,
			z = radial.x * state.circleSign + radial.z * radialScale,
		}
		local len = math.sqrt(moveDir.x * moveDir.x + moveDir.z * moveDir.z)
		if len > 1e-6 then
			moveDir.x /= len
			moveDir.z /= len
		end
	else
		local angle = self.rng() * math.pi * 2
		moveDir = { x = math.cos(angle), z = math.sin(angle) }
	end

	return { nextState = state.currentState, target = remembered, moveDir = moveDir }
end

return TraitBrain
