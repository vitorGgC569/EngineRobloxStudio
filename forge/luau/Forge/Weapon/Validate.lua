--!strict
--[[
	Validate — deciding whether to believe a client that says it fired.

	`Weapon.fire` takes an origin and a direction and uses them. On a server
	handling a client's request, both are claims. This is the layer that checks
	them, and it exists because the game that this is generalised from shipped
	without part of it and found the hole in an audit.

	Why the obvious check is not enough
	-----------------------------------

	The client must send its own muzzle position -- only it knows where its arms
	are, and only it knows what its camera was doing at the instant of the
	trigger. The obvious guard is a distance bound: the muzzle may be at most
	so far from the character. Twelve studs, say, to cover latency and reach.

	**Twelve studs of tolerance is twelve studs of freedom to put a muzzle on
	the far side of a wall** and shoot through it. The shipped version records
	this as a finding: the bound alone lets an exploiter project their barrel
	into cover and fire from the other side.

	So an origin must be both *near* and *reachable* -- there has to be a clear
	line from the head to the point being claimed. Two checks, and the second is
	the one that gets forgotten.

	Not every rejection is an accusation
	------------------------------------

	The distinction a first attempt misses. Several different things stop a
	shot, and treating them alike either buries real cheating in false positives
	or ignores it:

	  * **reloading** and **empty** are ordinary. The client fired because it
	    had not heard about the reload yet, or because the player is mashing a
	    dry trigger. Refuse it, say nothing, flag nobody.
	  * **firing faster than the weapon can** is not ordinary. Nothing
	    legitimate outruns the weapon's own rate.
	  * **an impossible origin** is not ordinary either.

	Hence a verdict plus a `hostile` flag rather than a boolean, and hence the
	rate check carries **slack**: two honest shots sent a full interval apart
	can arrive closer together, and a server that flags network jitter as
	cheating is a server that bans its own players.
]]

local Validate = {}

--: How far a claimed muzzle may sit from the character's root. Covers latency
--: and arm's reach; past it is not a network artefact.
Validate.originTolerance = 12

--: Fraction of the firing interval that must have elapsed. The 10% shortfall
--: is jitter budget, not generosity.
Validate.rateSlack = 0.9

export type Verdict = {
	ok: boolean,
	reason: string,
	--: True only when nothing legitimate produces this. Benign refusals leave
	--: it false, so a caller can flag on `hostile` without drowning in noise.
	hostile: boolean,
}

local function verdict(ok: boolean, reason: string, hostile: boolean?): Verdict
	return { ok = ok, reason = reason, hostile = hostile or false }
end

--[[
	Is the claimed muzzle plausible?

	Both halves: within tolerance of the character, and reachable from its head
	without passing through geometry. Skipping the raycast is the wall-shooting
	hole described above, which is why this does it rather than leaving it to
	the caller to remember.

	Returns a verdict; `reason` is "far" or "blocked" so a caller can tell a
	laggy player from an exploiting one.
]]
function Validate.origin(character: Model, origin: Vector3, tolerance: number?): Verdict
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = humanoid and humanoid.RootPart
	if not root then
		return verdict(false, "no-character")
	end

	if (origin - root.Position).Magnitude > (tolerance or Validate.originTolerance) then
		return verdict(false, "far", true)
	end

	local head = character:FindFirstChild("Head")
	local from = (head and head:IsA("BasePart") and head.Position) or root.Position
	local offset = origin - from
	--: A muzzle essentially at the head needs no line to itself, and casting a
	--: zero-length ray is undefined.
	if offset.Magnitude < 0.5 then
		return verdict(true, "ok")
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	if workspace:Raycast(from, offset, params) then
		return verdict(false, "blocked", true)
	end
	return verdict(true, "ok")
end

--[[
	Has enough time passed since this shooter's last shot?

	`interval` is the weapon's own firing interval in seconds -- `Weapon`
	computes it as `60 / rpm` and stores it on the definition.
]]
function Validate.rate(lastShot: number, now: number, interval: number,
                       slack: number?): Verdict
	local required = interval * (slack or Validate.rateSlack)
	if now - lastShot < required then
		return verdict(false, "too-fast", true)
	end
	return verdict(true, "ok")
end

--[[
	Turn one of `Weapon.fire`'s refusal reasons into a verdict.

	`Weapon` already reports "cooldown", "empty", "reloading" and "no-weapon".
	This says which of those deserve suspicion: only "cooldown", and only
	because a client that respects its own cooldown never produces it.
]]
function Validate.classify(reason: string?): Verdict
	if reason == nil then
		return verdict(true, "ok")
	end
	local hostile = reason == "cooldown"
	return verdict(false, reason, hostile)
end

--[[
	A running count of hostile verdicts per player, with decay.

	Kept here so games do not each write their own, and deliberately *only* a
	counter: this reports, it does not punish. What a score means -- kick, ban,
	shadow-flag, log and watch -- is a policy decision that depends on the game,
	its audience and its tolerance for false positives, and a library that made
	that call for you would be wrong in most of the games that used it.

	Decay matters. Without it every long-lived session eventually trips any
	threshold on accumulated jitter alone.
]]
export type Tracker = {
	scores: { [any]: { value: number, at: number } },
	halfLife: number,
}

function Validate.tracker(halfLife: number?): Tracker
	return { scores = {}, halfLife = halfLife or 60 }
end

function Validate.flag(tracker: Tracker, who: any, now: number, weight: number?): number
	local entry = tracker.scores[who]
	local decayed = 0
	if entry then
		decayed = entry.value * 0.5 ^ ((now - entry.at) / tracker.halfLife)
	end
	local value = decayed + (weight or 1)
	tracker.scores[who] = { value = value, at = now }
	return value
end

function Validate.score(tracker: Tracker, who: any, now: number): number
	local entry = tracker.scores[who]
	if not entry then
		return 0
	end
	return entry.value * 0.5 ^ ((now - entry.at) / tracker.halfLife)
end

function Validate.forget(tracker: Tracker, who: any)
	tracker.scores[who] = nil
end

function Validate.describe(): { [string]: any }
	return {
		originTolerance = Validate.originTolerance,
		rateSlack = Validate.rateSlack,
		hostileReasons = { "far", "blocked", "too-fast", "cooldown" },
	}
end

return Validate
