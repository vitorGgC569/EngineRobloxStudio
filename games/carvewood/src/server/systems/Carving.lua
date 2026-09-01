--!strict
--[[
	Carving — the bench minigame, and the only thing that decides quality.

	Shaped after `Progression/FishingMinigame`: a session with phases, a tick
	that reports where the marker is, and a strike that scores it. Kept local to
	this game for now; it moves into Forge the day a second game wants a timing
	bench, which is this repo's extract-after-second-use rule.

	Three strokes, one grade
	------------------------

	A marker sweeps back and forth across a bar. Somewhere on that bar is a
	zone. Press inside it three times and the piece is Flawless; miss
	everything and it is Rough -- which is also exactly what the crew produces,
	so a player who cannot be bothered has lost nothing but the multiplier.

	The zone narrows with the species' hardness and widens with the chisel, so
	a Starheart is genuinely harder to carve well than a Pine and an upgrade is
	felt rather than read.

	Why the server owns the clock
	-----------------------------

	The client sends "I pressed now" and never a score. Marker position is
	recomputed here from `now - startedAt`, so a client that lies about when it
	pressed is lying about a number the server measures itself.

	It does have to be *told* where the zone is, because it has to draw it, and
	a client that knows where the zone is can press perfectly. That is accepted
	deliberately: the exploit's whole prize is 1.8x on one carving, it is gated
	behind owning a log, and the alternative -- trusting a client-computed score
	-- is strictly worse.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trees = require(ReplicatedStorage.Shared.Trees)

local Carving = {}

Carving.STROKES = 3

--: How long the marker takes to cross the bar and come back. Slow enough to
--: read, fast enough that three strokes is a few seconds and not a chore.
Carving.SWEEP = 1.45

--: A stroke abandoned this long after it started scores zero and moves on, so
--: a player who walks away mid-carve does not hold a log hostage.
Carving.PATIENCE = Carving.SWEEP * 3

Carving.clock = os.clock

export type Stroke = { at: number, score: number, perfect: boolean }

export type Session = {
	species: string,
	chisel: number,
	strokes: { Stroke },
	index: number,
	startedAt: number,
	centre: number,
	halfWidth: number,
	done: boolean,
}

--[[
	How wide the zone is for this species and chisel.

	Hardness is `toughness`, reused: the tree that resists an axe resists a
	chisel. One number driving both is why a Starheart reads as *hard* rather
	than merely as slow.
]]
function Carving.zoneWidth(speciesId: string, chisel: number): number
	local species = Trees.get(speciesId)
	local toughness = if species then species.toughness else 3
	--: 0.18 of the bar for a Pine at chisel 1, down to about 0.07 for a
	--: Starheart, back up past 0.2 with a good chisel.
	local base = 0.20 * (1 + (chisel - 1) * 0.16)
	return math.clamp(base * (3 / math.max(3, toughness)) ^ 0.42, 0.045, 0.32)
end

--: Where the marker is at a moment, as 0..1 across the bar. A triangle wave:
--: it travels out and comes back rather than jumping, because a marker that
--: teleports to the start cannot be anticipated and anticipation is the skill.
function Carving.markerAt(elapsed: number): number
	local phase = (elapsed % Carving.SWEEP) / Carving.SWEEP
	return if phase <= 0.5 then phase * 2 else (1 - phase) * 2
end

function Carving.begin(speciesId: string, chisel: number,
                       rng: (() -> number)?, now: number?): Session
	local roll = rng or math.random
	local half = Carving.zoneWidth(speciesId, chisel) / 2
	return {
		species = speciesId,
		chisel = chisel,
		strokes = {},
		index = 1,
		startedAt = now or Carving.clock(),
		--: Never against the ends of the bar, where the marker slows to a stop
		--: and turns around -- a zone there would be free.
		centre = half + 0.12 + roll() * (1 - 2 * (half + 0.12)),
		halfWidth = half,
		done = false,
	}
end

--[[
	Score the stroke happening right now, and set up the next one.

	Returns the score, whether it was a perfect, and whether that was the last
	stroke. A stroke struck outside the zone scores zero rather than failing the
	session: a bad carve is a Rough piece, never a lost log.
]]
function Carving.strike(session: Session, now: number?): (number, boolean, boolean)
	if session.done then
		return 0, false, true
	end
	local at = now or Carving.clock()
	local marker = Carving.markerAt(at - session.startedAt)
	local distance = math.abs(marker - session.centre)
	local score = math.clamp(1 - distance / session.halfWidth, 0, 1)
	--: The inner fifth of the zone. At a third, a player landing merely
	--: *well* scored three perfects and Flawless stopped being a story --
	--: the simulation graded 80%-accurate strokes as Flawless.
	local perfect = distance <= session.halfWidth * 0.18

	table.insert(session.strokes,
		{ at = marker, score = score, perfect = perfect })
	session.index += 1
	session.startedAt = at
	if session.index > Carving.STROKES then
		session.done = true
	end
	return score, perfect, session.done
end

--: A stroke the player never took. Called by the server's own timer, so an
--: abandoned bench resolves itself instead of waiting forever.
function Carving.timeout(session: Session, now: number?): boolean
	if session.done then
		return true
	end
	if (now or Carving.clock()) - session.startedAt < Carving.PATIENCE then
		return false
	end
	table.insert(session.strokes, { at = 0, score = 0, perfect = false })
	session.index += 1
	session.startedAt = now or Carving.clock()
	if session.index > Carving.STROKES then
		session.done = true
	end
	return session.done
end

--[[
	Three scores become one grade.

	Flawless needs every stroke perfect, which is why it is worth 3x and why
	most players will see it a handful of times. Everything below is an average,
	so one bad stroke costs a grade rather than the whole carve.
]]
function Carving.grade(session: Session): string
	local total, perfects = 0, 0
	for _, stroke in session.strokes do
		total += stroke.score
		if stroke.perfect then
			perfects += 1
		end
	end
	if perfects >= Carving.STROKES then
		return "flawless"
	end
	local average = total / math.max(1, Carving.STROKES)
	if average >= 0.74 then
		return "master"
	end
	if average >= 0.38 then
		return "fine"
	end
	return "rough"
end

--: Everything the client needs to draw the bar, and nothing it needs to cheat
--: beyond what drawing already requires.
function Carving.describe(session: Session): { [string]: any }
	return {
		species = session.species,
		stroke = math.min(session.index, Carving.STROKES),
		strokes = Carving.STROKES,
		centre = session.centre,
		halfWidth = session.halfWidth,
		sweep = Carving.SWEEP,
		done = session.done,
	}
end

return Carving
