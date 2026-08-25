--!strict
--[[
	FishingMinigame: session GUID, bite windows and level-gated loot.

	The vesteria contract: casting opens a session with a GUID; the fish
	bites at a seeded moment; reeling is only honored inside a small
	forgiveness window after the bite (latency compensation); the loot
	pool filters by profession level and rod tier before rolling. Pure
	state machine. Rod animations and the spawned fish item are callers.
]]

local Rng = require(script.Parent.Parent.Core.Rng)

local FishingMinigame = {}

export type Phase = "idle" | "waiting" | "bite" | "result"

export type Drop = {
	id: string,
	weight: number,
	minProfessionLevel: number,
	minRodTier: number,
}

type Session = {
	guid: string,
	phase: Phase,
	biteAt: number,
	biteDeadline: number,
}

type Self = {
	drops: { Drop },
	waitMin: number,
	waitMax: number,
	biteWindow: number,
	latencyForgiveness: number,
	rng: Rng.Generator,
	now: () -> number,
	session: Session?,
}

FishingMinigame.__index = FishingMinigame

function FishingMinigame.new(config: {
	drops: { Drop },
	waitMin: number?,
	waitMax: number?,
	biteWindow: number?,
	latencyForgiveness: number?,
	seed: number?,
	now: (() -> number)?,
}): Self
	assert(#config.drops > 0, "fishing needs drops")
	return setmetatable({
		drops = table.clone(config.drops),
		waitMin = config.waitMin or 3,
		waitMax = config.waitMax or 12,
		biteWindow = config.biteWindow or 1.2,
		latencyForgiveness = config.latencyForgiveness or 0.35,
		rng = Rng.xorshift(config.seed),
		now = config.now or os.clock,
		session = nil,
	}, FishingMinigame)
end

function FishingMinigame.addDrop(self: Self, drop: Drop): ()
	table.insert(self.drops, drop)
end

-- Casts a line; returns the session GUID. One session at a time.
function FishingMinigame.cast(self: Self): (string?, string?)
	if self.session then
		return nil, "already_cast"
	end
	local now = self.now()
	local guid = tostring(math.floor(now * 1000)) .. "-" .. tostring(math.floor(self.rng() * 1e6))
	self.session = {
		guid = guid,
		phase = "waiting",
		biteAt = now + Rng.range(self.rng, self.waitMin, self.waitMax),
		biteDeadline = 0,
	}
	return guid, nil
end

-- Advances timing; returns events ("bite"/"escape") for this tick.
function FishingMinigame.tick(self: Self): { string }
	local events: { string } = {}
	local s = self.session
	if not s then
		return events
	end
	local now = self.now()

	if s.phase == "waiting" and now >= s.biteAt then
		s.phase = "bite"
		s.biteDeadline = now + self.biteWindow
		table.insert(events, "bite")
	elseif s.phase == "bite" and now > s.biteDeadline then
		s.phase = "result"
		table.insert(events, "escape")
	end
	return events
end

-- Reel attempt. Success requires the bite window (+ latency forgiveness).
function FishingMinigame.reel(self: Self): (string, string?)
	local s = self.session
	if not s then
		return "no_session", nil
	end
	local now = self.now()

	if s.phase == "waiting" then
		return "too_early", nil
	end
	if s.phase == "result" then
		return "missed", nil
	end

	if now <= s.biteDeadline + self.latencyForgiveness then
		s.phase = "result"
		return "success", self:rollLoot()
	end
	s.phase = "result"
	return "missed", nil
end

-- Weighted roll filtered by profession level and rod tier.
function FishingMinigame.rollLoot(self: Self, professionLevel: number?, rodTier: number?): string?
	local level = professionLevel or 0
	local tier = rodTier or 1
	local total = 0
	for _, drop in self.drops do
		if level >= drop.minProfessionLevel and tier >= drop.minRodTier then
			total += drop.weight
		end
	end
	if total <= 0 then
		return nil
	end
	local roll = self.rng() * total
	local acc = 0
	for _, drop in self.drops do
		if level >= drop.minProfessionLevel and tier >= drop.minRodTier then
			acc += drop.weight
			if roll < acc then
				return drop.id
			end
		end
	end
	return nil
end

function FishingMinigame.resetSession(self: Self): ()
	self.session = nil
end

return FishingMinigame
