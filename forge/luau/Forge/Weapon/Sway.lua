--!strict
--[[
	Sway — the small motions that make a held weapon feel held.

	A weapon welded rigidly to a camera reads as a decal. The difference between
	that and a gun somebody is carrying is four cheap oscillations, and this is
	all four.

	Ported from a faithful Quake `view.c` implementation
	----------------------------------------------------

	Not invented here, and deliberately so: this maths is thirty years old,
	shipped in the games that defined how a first-person weapon should feel, and
	every constant in it was tuned by people watching players. What follows are
	the parts that matter and the reasons they are shaped that way.

	**Units are converted, relationships are not.** The original is in Quake
	units -- roughly ten to a stud -- with a player running at 320 and a bob
	clamped to 7. Copying those numbers into Roblox would swing a weapon seven
	studs. The scales below are re-expressed for studs and a 16 stud/s walk; the
	*shape* of every curve is untouched.

	  * **Bob is proportional to speed**, so walking pumps gently and sprinting
	    pumps hard, with no separate states to configure.

	  * **The stroke is asymmetric.** `upFraction` splits the cycle unevenly,
	    so the rise and the fall take different lengths of time. A pure sine
	    reads as a machine; a footstep does not.

	  * **There is a constant term.** `bob * 0.3 + bob * 0.7 * sin(...)` never
	    returns to zero while moving, so the weapon rides slightly high rather
	    than passing through its rest position twice a step.

	  * **The clamp is lopsided** -- it can drop further than it rises, because
	    a weapon that flies up past the crosshair obscures the thing you are
	    aiming at, and one that dips does not.

	  * **Airborne freezes the cycle.** The clock stops and the last value is
	    held. This is the detail a first attempt always misses: a weapon that
	    keeps pumping while its owner is in mid-air is walking on nothing.

	  * **Idle sway runs three waves at different rates** -- pitch, yaw and roll
	    at 1, 2 and 0.5 -- so the composite never visibly repeats. One shared
	    frequency is a wobble; three unequal ones read as breathing.

	Everything here is scalar and stateless apart from the bob clock, so it runs
	in a test with no camera, and drives a viewmodel, a third-person weld or a
	held tool equally well.
]]

local Sway = {}

export type Tuning = {
	--: Seconds for one full step cycle. Two footfalls.
	cycle: number?,
	--: Fraction of the cycle spent rising. 0.5 is even; the original's default.
	upFraction: number?,
	--: Studs of bob per stud/second of speed.
	scale: number?,
	--: Lopsided on purpose: further down than up.
	minBob: number?,
	maxBob: number?,
	--: Degrees of roll at `rollSpeed` of sideways motion.
	maxRoll: number?,
	rollSpeed: number?,
}

export type BobState = {
	clock: number,
	value: number,
}

local DEFAULTS = {
	cycle = 0.6,
	upFraction = 0.5,
	scale = 0.025,
	minBob = -0.7,
	maxBob = 0.4,
	maxRoll = 2,
	rollSpeed = 20,
}

--: Idle sway rates and depths. The rates are deliberately unequal so the three
--: axes drift in and out of phase instead of tracing one closed figure.
local IDLE = {
	pitchRate = 1.0, pitchDepth = 0.3,
	yawRate = 2.0, yawDepth = 0.3,
	rollRate = 0.5, rollDepth = 0.1,
}

local function setting(tuning: Tuning?, key: string): number
	local value = tuning and (tuning :: any)[key]
	if value ~= nil then
		return value
	end
	return (DEFAULTS :: any)[key]
end

function Sway.newBob(): BobState
	return { clock = 0, value = 0 }
end

--[[
	Advance the walk bob and return its offset in studs.

	`grounded` false holds the previous value and stops the clock, so a weapon
	freezes mid-stroke for the length of a jump and resumes from where it was.
	Resetting it to zero instead would snap the weapon on every hop.
]]
function Sway.bob(state: BobState, dt: number, speed: number,
                  grounded: boolean, tuning: Tuning?): number
	if not grounded then
		return state.value
	end

	local period = setting(tuning, "cycle")
	local up = setting(tuning, "upFraction")
	state.clock += dt

	--: Position within the stroke, 0..1, then warped so the rise and the fall
	--: occupy different fractions of it.
	local phase = (state.clock % period) / period
	local angle
	if phase < up then
		angle = math.pi * phase / up
	else
		angle = math.pi + math.pi * (phase - up) / (1 - up)
	end

	local amount = speed * setting(tuning, "scale")
	--: Thirty percent constant, seventy percent oscillating: the weapon rides
	--: high while moving rather than crossing its rest point every stride.
	local offset = amount * 0.3 + amount * 0.7 * math.sin(angle)
	state.value = math.clamp(offset, setting(tuning, "minBob"), setting(tuning, "maxBob"))
	return state.value
end

--[[
	Degrees of roll for a given sideways speed. Strafing leans.

	Linear up to `rollSpeed`, flat after, signed by direction. It is a small
	angle -- two degrees -- and it does more for the feel of movement than any
	other single number in this file.

	`lateral` is the component of velocity along the camera's right vector;
	the caller has the camera and this does not.
]]
function Sway.roll(lateral: number, tuning: Tuning?): number
	local limit = setting(tuning, "rollSpeed")
	local peak = setting(tuning, "maxRoll")
	if limit <= 0 then
		return 0
	end
	local magnitude = math.min(math.abs(lateral) / limit, 1) * peak
	return if lateral < 0 then -magnitude else magnitude
end

--[[
	Breathing: pitch, yaw and roll additions in degrees.

	`scale` is the whole effect's depth -- zero disables it, and the original
	shipped with it off by default for exactly the reason a modern game should
	turn it on quietly: at any strength a player consciously notices, it is
	motion sickness rather than life. Small values only.
]]
function Sway.idle(clock: number, scale: number?): (number, number, number)
	local depth = scale or 0
	if depth == 0 then
		return 0, 0, 0
	end
	return depth * math.sin(clock * IDLE.pitchRate) * IDLE.pitchDepth,
	       depth * math.sin(clock * IDLE.yawRate) * IDLE.yawDepth,
	       depth * math.sin(clock * IDLE.rollRate) * IDLE.rollDepth
end

--[[
	Recoil that decays: add on fire, call each frame, use what comes back.

	Exponential rather than linear, so the kick is sharp and the settle is soft.
	`halfLife` is how long it takes to fall to half -- around a tenth of a
	second for a rifle, longer for something heavy.

	Returns the remaining kick, so a caller keeps one number per axis:

		state.pitch = Sway.decay(state.pitch + shotKick, dt, 0.1)
]]
function Sway.decay(value: number, dt: number, halfLife: number?): number
	local life = halfLife or 0.1
	if life <= 0 then
		return 0
	end
	local remaining = value * 0.5 ^ (dt / life)
	--: Anything under a thousandth of a degree is invisible; snapping it to
	--: zero stops the value from drifting for ever and keeps comparisons clean.
	return if math.abs(remaining) < 1e-3 then 0 else remaining
end

function Sway.describe(): { [string]: any }
	return { defaults = DEFAULTS, idle = IDLE }
end

return Sway
