--!strict
-- Pure round state machine. No Roblox APIs — time is passed in, side effects come out
-- as an effects list the service layer executes. This keeps the entire round flow
-- unit-testable outside Roblox (see tests/round-machine.spec.luau).

export type State = "WAITING" | "INTERMISSION" | "ACTIVE" | "ROUND_END"

export type Effect =
	{ type: "StartIntermission", endsAt: number }
	| { type: "StartRound", endsAt: number }
	| { type: "ExtendRound", endsAt: number, conversions: number }
	| { type: "EndRound", winner: "SURVIVORS" | "INFECTED" | "NOBODY", endsAt: number }
	| { type: "ReturnToIntermission" }
	| { type: "ReturnToWaiting" }

export type RoundConfig = {
	MinPlayersToStart: number,
	IntermissionSeconds: number,
	BaseRoundSeconds: number,
	SecondsPerConversion: number,
	MaxRoundSeconds: number,
	RevealSeconds: number,
}

export type RoundMachine = {
	state: State,
	deadline: number?, -- unix-ish clock supplied by caller
	roundStartedAt: number?,
	-- Until this clock time, survivorCount <= 0 must NOT end the round. Covers the
	-- assignRoles → spawnBots setup window where humans-only can briefly read as 0
	-- survivors (solo Patient Zero before bots exist).
	setupGraceUntil: number?,
	playerCount: number,
	survivorCount: number,
	conversions: number,

	setPlayerCount: (self: RoundMachine, n: number, now: number) -> { Effect },
	forceEnd: (self: RoundMachine, winner: "SURVIVORS" | "INFECTED" | "NOBODY", now: number) -> { Effect },
	setSurvivorCount: (self: RoundMachine, n: number, now: number) -> { Effect },
	recordConversion: (self: RoundMachine, now: number) -> { Effect },
	tick: (self: RoundMachine, now: number) -> { Effect },
}

-- Seconds after StartRound during which a zero survivor count is ignored.
local SETUP_GRACE_SECONDS = 5

local RoundMachine = {}
RoundMachine.__index = RoundMachine

local function new(config: RoundConfig): RoundMachine
	local self = setmetatable({
		config = config,
		state = "WAITING" :: State,
		deadline = nil :: number?,
		roundStartedAt = nil :: number?,
		setupGraceUntil = nil :: number?,
		playerCount = 0,
		survivorCount = 0,
		conversions = 0,
	}, RoundMachine)
	return (self :: any) :: RoundMachine
end

local function enterIntermission(self, now: number): Effect
	self.state = "INTERMISSION"
	self.deadline = now + self.config.IntermissionSeconds
	return { type = "StartIntermission", endsAt = self.deadline :: number }
end

local function enterRoundEnd(self, now: number, winner): Effect
	self.state = "ROUND_END"
	self.deadline = now + self.config.RevealSeconds
	self.setupGraceUntil = nil
	return { type = "EndRound", winner = winner, endsAt = self.deadline :: number }
end

function RoundMachine.setPlayerCount(self, n: number, now: number): { Effect }
	self.playerCount = n
	local effects = {}
	if self.state == "WAITING" and n >= self.config.MinPlayersToStart then
		table.insert(effects, enterIntermission(self, now))
	elseif self.state == "INTERMISSION" and n < self.config.MinPlayersToStart then
		self.state = "WAITING"
		self.deadline = nil
		table.insert(effects, { type = "ReturnToWaiting" })
	end
	-- ACTIVE rounds continue even if players leave; survivor/infected counts decide the end.
	return effects
end

function RoundMachine.setSurvivorCount(self, n: number, now: number): { Effect }
	self.survivorCount = n
	local effects = {}
	if self.state == "ACTIVE" and n <= 0 then
		local grace = self.setupGraceUntil
		if grace ~= nil and now < grace then
			-- Setup still in flight (roles/bots); do not crown INFECTED yet.
			return effects
		end
		table.insert(effects, enterRoundEnd(self, now, "INFECTED"))
	end
	return effects
end

-- Immediate round end regardless of counts (e.g. Patient Zero left before first blood).
function RoundMachine.forceEnd(self, winner: "SURVIVORS" | "INFECTED" | "NOBODY", now: number): { Effect }
	if self.state ~= "ACTIVE" then
		return {}
	end
	return { enterRoundEnd(self, now, winner) }
end

function RoundMachine.recordConversion(self, _now: number): { Effect }
	if self.state ~= "ACTIVE" then
		return {}
	end
	self.conversions += 1
	local startedAt = self.roundStartedAt :: number
	local maxDeadline = startedAt + self.config.MaxRoundSeconds
	local extended = math.min((self.deadline :: number) + self.config.SecondsPerConversion, maxDeadline)
	self.deadline = extended
	return { { type = "ExtendRound", endsAt = extended, conversions = self.conversions } }
end

function RoundMachine.tick(self, now: number): { Effect }
	-- Setup grace can expire mid-round (before the timer deadline). If the post-setup
	-- count is still zero survivors, end as INFECTED without waiting out BaseRoundSeconds.
	if self.state == "ACTIVE" and self.setupGraceUntil ~= nil and now >= self.setupGraceUntil then
		self.setupGraceUntil = nil
		if self.survivorCount <= 0 then
			return { enterRoundEnd(self, now, "INFECTED") }
		end
	end

	local deadline = self.deadline
	if deadline == nil or now < deadline then
		return {}
	end

	if self.state == "INTERMISSION" then
		if self.playerCount >= self.config.MinPlayersToStart then
			self.state = "ACTIVE"
			self.roundStartedAt = now
			self.setupGraceUntil = now + SETUP_GRACE_SECONDS
			self.conversions = 0
			-- One player is Patient Zero, not a survivor. RoleService reports the
			-- authoritative count after spawning, but that loop yields — this keeps
			-- the interim value correct (finding #5). playerCount includes planned bots.
			self.survivorCount = math.max(self.playerCount - 1, 0)
			self.deadline = now + self.config.BaseRoundSeconds
			return { { type = "StartRound", endsAt = self.deadline :: number } }
		else
			self.state = "WAITING"
			self.deadline = nil
			self.setupGraceUntil = nil
			return { { type = "ReturnToWaiting" } }
		end
	elseif self.state == "ACTIVE" then
		-- Timer expired with survivors alive -> survivors win.
		local winner = if self.survivorCount > 0 then "SURVIVORS" else "INFECTED"
		return { enterRoundEnd(self, now, winner) }
	elseif self.state == "ROUND_END" then
		if self.playerCount >= self.config.MinPlayersToStart then
			return { enterIntermission(self, now), { type = "ReturnToIntermission" } }
		else
			self.state = "WAITING"
			self.deadline = nil
			return { { type = "ReturnToWaiting" } }
		end
	end
	return {}
end

return { new = new }
