--!strict
--[[
	AutoTarget — which of these am I actually hitting?

	Not aggro, and not a hitbox
	---------------------------

	`AggroTable` answers "who is the enemy angry at" — a server question about
	threat. `HitGeometry` answers "did this swing connect" — a geometry
	question about one attack. This answers the third question, which sits
	between them and is the one players feel: **out of everything in front of
	me, which one does the game think I mean.**

	Get it wrong and the game feels broken in a way nobody can articulate. The
	sword swings at the husk behind you instead of the one you are looking at.
	The heal goes to the full-health ally. The lock-on snaps to a corpse.

	The rule that makes it feel right
	---------------------------------

	Distance alone is wrong, and it is what everybody writes first. The nearest
	enemy is frequently not the one you are facing, so a purely nearest-target
	system swings sideways at something behind your shoulder.

	Facing alone is also wrong: the thing you are most precisely aimed at may
	be forty studs away behind the one in your face.

	So it is both, weighted, with facing dominant — a target twenty degrees off
	and close beats one dead ahead and distant. That single weighting is the
	whole difference between combat that feels like it obeys you and combat
	that feels like it argues.

		AutoTarget.pick(fromCFrame, candidates, {
			range = 30, arc = 100, prefer = "hostile",
		})

	Pure, and injected
	------------------

	It takes positions and returns a choice. No raycasts, no CollectionService,
	no Humanoid reads — the game supplies candidates, this decides among them,
	and the whole thing is testable with three vectors and no DataModel.
]]

local AutoTarget = {}

export type Candidate = {
	instance: any,
	position: Vector3,
	--: Lower sorts first when scores tie — for "wounded first" healing or
	--: "biggest threat first" targeting, supplied by the game.
	priority: number?,
	valid: boolean?,
}

export type Options = {
	range: number?,
	arc: number?,
	facingWeight: number?,
	requireLineOfSight: ((from: Vector3, to: Vector3) -> boolean)?,
	stickiness: number?,
	current: any?,
}

--[[
	How much facing matters against distance.

	0.7 means a target's angle is worth about twice its distance. Arrived at
	the way these numbers always are — by playing it — and exposed because a
	twin-stick game and a first-person game want different answers.
]]
AutoTarget.facingWeight = 0.7

--[[
	How much the current target is favoured to keep it.

	Without this, two enemies at nearly equal score swap the lock every frame
	and the reticle flickers between them. A little hysteresis costs nothing
	and removes an artefact that reads as a bug.
]]
AutoTarget.stickiness = 0.15

-- ================================== picking =================================
--[[
	Score one candidate. Higher is better; nil means it is out.

	Returned rather than compared inline so the reasoning is inspectable — an
	agent debugging "why did it pick that one" can score every candidate and
	look, instead of reading the loop and guessing.
]]
function AutoTarget.score(from: CFrame, candidate: Candidate, options: Options?): number?
	if candidate.valid == false then
		return nil
	end

	local opts = options or {}
	local range = opts.range or 30
	local arc = opts.arc or 120

	local offset = candidate.position - from.Position
	local distance = offset.Magnitude
	if distance > range then
		return nil
	end
	-- A candidate sitting exactly on the origin has no direction to compare,
	-- and normalising a zero vector produces NaN that silently poisons every
	-- later comparison.
	if distance < 1e-3 then
		return 1
	end

	local facing = from.LookVector:Dot(offset.Unit)
	local halfArc = math.rad(arc * 0.5)
	if facing < math.cos(halfArc) then
		return nil
	end

	--[[
		Both terms are 0..1 where 1 is best, so the weighting is legible.

		`facing` comes back as a dot product in -1..1; mapping it to 0..1
		against the arc's own edge means a target at the very edge of the cone
		scores zero for facing rather than some arbitrary negative that would
		fight the distance term.
	]]
	local edge = math.cos(halfArc)
	local facingScore = (facing - edge) / math.max(1e-6, 1 - edge)
	local distanceScore = 1 - (distance / range)

	local weight = opts.facingWeight or AutoTarget.facingWeight
	local score = facingScore * weight + distanceScore * (1 - weight)

	if opts.requireLineOfSight and not opts.requireLineOfSight(from.Position, candidate.position) then
		return nil
	end

	return score
end

--[[
	Choose one, or nothing.

	Ties broken by `priority` then by distance, so a game that wants "wounded
	ally first" gets it without this module knowing what a wound is.
]]
function AutoTarget.pick(from: CFrame, candidates: { Candidate }, options: Options?): (any, number?)
	local opts = options or {}
	local bestCandidate: Candidate? = nil
	local bestScore: number? = nil

	for _, candidate in candidates do
		local score = AutoTarget.score(from, candidate, opts)
		if not score then
			continue
		end

		-- The incumbent gets a bonus, which is what stops the lock flickering
		-- between two enemies that are equally good targets.
		if opts.current ~= nil and candidate.instance == opts.current then
			score += (opts.stickiness or AutoTarget.stickiness)
		end

		if not bestScore or score > bestScore then
			bestCandidate, bestScore = candidate, score
		elseif math.abs(score - bestScore) < 1e-6 and bestCandidate then
			local mine = candidate.priority or 0
			local theirs = bestCandidate.priority or 0
			if mine < theirs then
				bestCandidate, bestScore = candidate, score
			end
		end
	end

	if not bestCandidate then
		return nil, nil
	end
	return bestCandidate.instance, bestScore
end

--[[
	Everything in the cone, best first.

	For cleaves, chain lightning, area heals and any ability that wants more
	than one — and for a debug view that shows what the picker was choosing
	between.
]]
function AutoTarget.ranked(from: CFrame, candidates: { Candidate }, options: Options?): { any }
	local scored = {}
	for _, candidate in candidates do
		local score = AutoTarget.score(from, candidate, options)
		if score then
			table.insert(scored, {
				instance = candidate.instance,
				score = score,
				distance = (candidate.position - from.Position).Magnitude,
			})
		end
	end
	table.sort(scored, function(a, b)
		return a.score > b.score
	end)
	return scored
end

--[[
	Is the current target still worth keeping?

	Called each frame by a lock-on. Separate from `pick` because dropping a
	target and choosing a new one are different decisions: a target that walks
	behind a wall should be dropped, not swapped for whatever is now nearest,
	or the camera whips round on its own.
]]
function AutoTarget.stillValid(from: CFrame, candidate: Candidate, options: Options?): boolean
	return AutoTarget.score(from, candidate, options) ~= nil
end

function AutoTarget.describe(): { [string]: any }
	return {
		facingWeight = AutoTarget.facingWeight,
		stickiness = AutoTarget.stickiness,
		note = "facing dominates distance; the incumbent keeps a small bonus",
	}
end

return AutoTarget
