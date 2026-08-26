--!strict
-- Bot decision-making, as a real state machine.
--
-- The old logic was a straight-line if/else re-evaluated from scratch every tick with no
-- memory and no hysteresis, so a bot sitting exactly at the flee radius would flip between
-- fleeing and wandering several times a second, and a bot that lost sight of you forgot you
-- existed instantly — mid-firefight.
--
-- Pure and scalar-only (no Vector3/Instance) so it runs under Lune in tests. The service
-- feeds it a flattened perception snapshot and acts on the state it returns.

local BotBrain = {}

export type Perception = {
	threatDist: number?, -- distance to the most relevant threat, nil if none known
	threatVisible: boolean?, -- currently in the vision cone with clear line of sight
	hasLastKnown: boolean?, -- we remember where it was even if we can't see it
	timeSinceContact: number?, -- seconds since we last actually saw it
	health01: number?, -- 0..1
	allyCount: number?, -- nearby friendly survivors
	justDamaged: boolean?, -- took a hit since the last tick
	ammo01: number?, -- 0..1, reserved for reload behaviour
}

export type Config = {
	fleeRadius: number,
	fleeExitMult: number, -- exit flee at fleeRadius * this (hysteresis band)
	engageRange: number,
	memorySeconds: number, -- how long a lost target stays worth searching for
	staggerSeconds: number,
	minDwell: number, -- minimum time in a state before it may change
	regroupBelowAllies: number, -- seek friends when fewer than this many nearby
	braveryHealth: number, -- flee early below this health fraction
}

BotBrain.Defaults = {
	fleeRadius = 26,
	fleeExitMult = 1.6,
	engageRange = 60,
	memorySeconds = 6,
	staggerSeconds = 0.35,
	minDwell = 0.45,
	regroupBelowAllies = 1,
	braveryHealth = 0.35,
} :: Config

-- Per-personality deviations. "aggressive" and "roamer" used to be byte-identical strings
-- with no behavioural difference at all.
BotBrain.Personalities = {
	roamer = { fleeRadius = 26, engageRange = 60, regroupBelowAllies = 0 },
	grouper = { fleeRadius = 30, engageRange = 55, regroupBelowAllies = 2 },
	cautious = { fleeRadius = 40, engageRange = 70, braveryHealth = 0.6, regroupBelowAllies = 2 },
	aggressive = { fleeRadius = 14, engageRange = 75, braveryHealth = 0.15, regroupBelowAllies = 0 },
} :: { [string]: { [string]: number } }

function BotBrain.configFor(personality: string?, overrides: { [string]: number }?): Config
	local cfg: { [string]: number } = table.clone(BotBrain.Defaults :: any)
	local tuning = personality and BotBrain.Personalities[personality]
	if tuning then
		for k, v in tuning do
			cfg[k] = v
		end
	end
	if overrides then
		for k, v in overrides do
			cfg[k] = v
		end
	end
	return cfg :: any
end

export type Memory = {
	state: string,
	since: number, -- timestamp the current state began
	staggerUntil: number,
}

function BotBrain.newMemory(state: string, now: number): Memory
	return { state = state, since = now, staggerUntil = 0 }
end

-- Survivor states: PATROL / ENGAGE / FLEE / SEARCH / REGROUP / STAGGER
-- Infected states: HUNT / STALK / SEARCH / STAGGER
local function surviveNext(memory: Memory, p: Perception, cfg: Config, now: number): string
	local dist = p.threatDist
	local visible = p.threatVisible == true
	local health = p.health01 or 1

	-- Being shot always interrupts: a bot that ignores incoming fire reads as furniture.
	if p.justDamaged then
		return "STAGGER"
	end
	if memory.state == "STAGGER" and now < memory.staggerUntil then
		return "STAGGER"
	end

	-- Minimum dwell keeps a bot from twitching between states on borderline input. A
	-- finished stagger is exempt: its own window is its dwell, and applying both would
	-- leave the bot frozen after a hit for longer than intended.
	local settled = (now - memory.since) >= cfg.minDwell or memory.state == "STAGGER"

	if visible and dist then
		-- Hysteresis: enter flee inside fleeRadius, but don't leave until meaningfully
		-- further out, so standing at exactly the boundary doesn't oscillate.
		local fleeing = memory.state == "FLEE"
		local threshold = fleeing and cfg.fleeRadius * cfg.fleeExitMult or cfg.fleeRadius
		if dist <= threshold or health < cfg.braveryHealth then
			return "FLEE"
		end
		if dist <= cfg.engageRange then
			return "ENGAGE"
		end
	end

	if not settled then
		return memory.state
	end

	-- Lost contact but still remember where they were: go look instead of forgetting.
	if p.hasLastKnown and (p.timeSinceContact or math.huge) < cfg.memorySeconds then
		return "SEARCH"
	end

	if (p.allyCount or 0) < cfg.regroupBelowAllies then
		return "REGROUP"
	end

	return "PATROL"
end

local function infectedNext(memory: Memory, p: Perception, cfg: Config, now: number): string
	if p.justDamaged then
		return "STAGGER"
	end
	if memory.state == "STAGGER" and now < memory.staggerUntil then
		return "STAGGER"
	end

	if p.threatVisible and p.threatDist then
		-- Close in openly once committed; hang back and shadow at range.
		if p.threatDist <= cfg.engageRange * 0.4 then
			return "HUNT"
		end
		return "STALK"
	end

	if p.hasLastKnown and (p.timeSinceContact or math.huge) < cfg.memorySeconds then
		return "SEARCH"
	end
	return "STALK"
end

-- Returns the next state. Callers persist `memory` and act on the result.
function BotBrain.next(memory: Memory, role: string, p: Perception, cfg: Config, now: number): string
	local infected = role == "ZOMBIE" or role == "PATIENT_ZERO"
	local nextState = if infected then infectedNext(memory, p, cfg, now) else surviveNext(memory, p, cfg, now)

	if nextState ~= memory.state then
		memory.state = nextState
		memory.since = now
		if nextState == "STAGGER" then
			memory.staggerUntil = now + cfg.staggerSeconds
		end
	elseif nextState == "STAGGER" and p.justDamaged then
		-- Re-hit while already staggering: extend, don't reset the clock backwards.
		memory.staggerUntil = math.max(memory.staggerUntil, now + cfg.staggerSeconds)
	end
	return nextState
end

return BotBrain
