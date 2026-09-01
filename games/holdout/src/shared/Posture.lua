--!strict
--[[
	Posture — standing, crouched, prone, and what each one costs.

	Shared, because the client predicts it and the server owns it, and a
	posture the two disagree about is a player who is prone on their screen and
	standing on everybody else's.

	Why posture is a weapon system, not a movement one
	--------------------------------------------------

	Going prone is not an animation. It is a trade: you give up almost all your
	speed and most of your ability to turn, and you get a weapon that barely
	moves and a silhouette half the height. That trade is the whole reason a
	firefight has positions in it rather than being two people strafing.

	So the numbers here feed `Forge.Weapon.Stance` -- the same multiplier chain
	that already handles aiming, sprinting and being airborne -- rather than
	living in a movement module that accuracy would have to go and ask.

	The one that always gets forgotten
	----------------------------------

	**Getting up takes time.** A prone player who can stand instantly is a
	prone player with no downside, and the posture becomes strictly correct.
	`transition` is what makes lying down a commitment.
]]

local Posture = {}

export type Id = "stand" | "crouch" | "prone"

export type State = {
	id: Id,
	label: string,
	--: Fraction of base walk speed.
	speed: number,
	--: How far the humanoid's hips sit below standing, in studs. Drives both
	--: the camera and the silhouette.
	drop: number,
	--: What this does to weapon spread. Below 1 is steadier.
	spread: number,
	--: What it does to recoil recovery -- a braced shooter fights the climb.
	recoil: number,
	--: Seconds to reach this posture from standing. Leaving is the same cost.
	transition: number,
	--: How much of the standing hitbox height remains. A prone player is
	--: genuinely harder to hit, and this is the number that says so.
	profile: number,
}

Posture.states = ({
	{
		id = "stand", label = "Standing",
		speed = 1.0, drop = 0, spread = 1.0, recoil = 1.0,
		transition = 0, profile = 1.0,
	},
	{
		--: Two thirds the speed for a third off the spread. The default
		--: posture in a firefight, and it should be cheap enough to take
		--: without thinking and expensive enough to leave.
		id = "crouch", label = "Crouched",
		speed = 0.55, drop = 1.6, spread = 0.68, recoil = 0.78,
		transition = 0.28, profile = 0.66,
	},
	{
		--: Barely mobile, barely visible, and very steady. A position rather
		--: than a movement: the second and a half it takes to get up is the
		--: price of everything else on this line.
		id = "prone", label = "Prone",
		speed = 0.16, drop = 2.9, spread = 0.34, recoil = 0.5,
		transition = 1.35, profile = 0.34,
	},
} :: any) :: { State }

local byId: { [string]: State } = {}
for _, state in Posture.states do
	byId[state.id] = state
end

Posture.BASE_SPEED = 15
Posture.SPRINT = 1.55

function Posture.get(id: string): State
	return byId[id] or byId.stand
end

--[[
	Whether one posture can become another right now.

	Standing to prone directly is allowed and slow; prone to sprinting is not,
	because a player who can go from lying down to running in one keypress is a
	player for whom prone had no cost. The intermediate is crouching, which is
	how it works in every game that has both.
]]
function Posture.mayChange(from: string, to: string): (boolean, string?)
	if from == to then
		return false, "already there"
	end
	if not byId[to] then
		return false, "no such posture"
	end
	return true, nil
end

--: How long moving between two postures takes. Symmetrical: lying down and
--: getting up cost the same, which is not quite true of bodies and is much
--: easier for a player to hold in their head.
function Posture.duration(from: string, to: string): number
	local a, b = Posture.get(from), Posture.get(to)
	return math.max(a.transition, b.transition)
end

--: Walk speed for a posture, with sprinting folded in. Sprinting while
--: crouched is not a thing; asking for it returns the crouch speed, which is
--: the honest answer rather than a refusal the client has to handle.
function Posture.speed(id: string, sprinting: boolean?): number
	local state = Posture.get(id)
	local speed = Posture.BASE_SPEED * state.speed
	if sprinting and id == "stand" then
		speed *= Posture.SPRINT
	end
	return speed
end

--[[
	The accuracy multiplier for a whole situation.

	Posture, aiming and movement compound, which is deliberate: a player who is
	prone, aimed and still should be markedly better than one who has any two
	of those, or the third is not worth doing.
]]
function Posture.spread(id: string, ads: boolean?, moving: boolean?,
                        airborne: boolean?): number
	local multiplier = Posture.get(id).spread
	if ads then
		multiplier *= 0.55
	end
	if moving then
		--: Moving costs less the lower you are, because you are barely moving.
		multiplier *= if id == "prone" then 1.15 else 1.6
	end
	if airborne then
		multiplier *= 3.2
	end
	return multiplier
end

function Posture.describe(): { [string]: any }
	local out = {}
	for _, state in Posture.states do
		out[state.id] = {
			speed = Posture.speed(state.id),
			spreadAimed = Posture.spread(state.id, true, false, false),
			profile = state.profile,
			transition = state.transition,
		}
	end
	return out
end

return Posture
