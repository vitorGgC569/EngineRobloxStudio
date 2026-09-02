--!strict
-- Pure spread/bloom model. The crosshair, the client tracer and the server raycast all
-- read this module, so the reticle you see is a projection of the cone the server actually
-- rolls in — they cannot drift apart.
--
-- Deliberately scalar-only (degrees, no Vector3/CFrame) so it runs under Lune in tests.
-- Callers turn a {yawDeg, pitchDeg} offset into a direction themselves.

local Ballistics = {}

export type Weapon = {
	baseSpreadDeg: number, -- cone at rest
	bloomPerShot: number, -- degrees added per shot fired
	maxSpreadDeg: number, -- hard ceiling
	recoverPerSec: number, -- degrees bled off per second while not firing
	adsMult: number, -- multiplier while aiming down sights (< 1)
	moveMult: number, -- multiplier while walking (> 1)
	sprintMult: number, -- multiplier while sprinting (> 1)
	airMult: number, -- multiplier while airborne (> 1)
}

export type State = {
	shotsInBurst: number?,
	ads: boolean?,
	moving: boolean?,
	sprinting: boolean?,
	airborne: boolean?,
}

-- Tuned against GameConfig.Combat.Guns. Fast weapons bloom harder so holding the trigger
-- costs accuracy; the shotgun's "spread" is its pellet cone and barely blooms.
local WEAPONS: { [string]: Weapon } = {
	AssaultRifle = {
		baseSpreadDeg = 0.9,
		bloomPerShot = 0.30,
		maxSpreadDeg = 6.0,
		recoverPerSec = 7.0,
		adsMult = 0.35,
		moveMult = 1.5,
		sprintMult = 2.4,
		airMult = 2.2,
	},
	SMG = {
		baseSpreadDeg = 1.4,
		bloomPerShot = 0.26,
		maxSpreadDeg = 7.5,
		recoverPerSec = 8.5,
		adsMult = 0.45,
		moveMult = 1.35,
		sprintMult = 2.1,
		airMult = 2.2,
	},
	Pistol = {
		baseSpreadDeg = 0.7,
		bloomPerShot = 0.45,
		maxSpreadDeg = 5.0,
		recoverPerSec = 9.0,
		adsMult = 0.3,
		moveMult = 1.4,
		sprintMult = 2.2,
		airMult = 2.2,
	},
	Shotgun = {
		baseSpreadDeg = 4.5,
		bloomPerShot = 0.5,
		maxSpreadDeg = 8.0,
		recoverPerSec = 6.0,
		adsMult = 0.7,
		moveMult = 1.15,
		sprintMult = 1.5,
		airMult = 1.6,
	},
	Minigun = {
		baseSpreadDeg = 2.2,
		bloomPerShot = 0.12,
		maxSpreadDeg = 9.0,
		recoverPerSec = 6.0,
		adsMult = 0.6,
		moveMult = 1.3,
		sprintMult = 1.9,
		airMult = 2.2,
	},
}

local DEFAULT: Weapon = WEAPONS.AssaultRifle

function Ballistics.weapon(weaponId: string): Weapon
	return WEAPONS[weaponId] or DEFAULT
end

-- Cone half-angle in degrees for the next shot.
function Ballistics.spread(weaponId: string, state: State?): number
	local w = Ballistics.weapon(weaponId)
	local s: State = state or {}

	local deg = w.baseSpreadDeg + w.bloomPerShot * math.max(0, s.shotsInBurst or 0)

	-- Stance multipliers. Sprint supersedes walk; ADS is applied last so aiming always helps.
	if s.airborne then
		deg *= w.airMult
	elseif s.sprinting then
		deg *= w.sprintMult
	elseif s.moving then
		deg *= w.moveMult
	end
	if s.ads then
		deg *= w.adsMult
	end

	return math.clamp(deg, 0, w.maxSpreadDeg)
end

-- Bleed accumulated bloom back down between shots. Bloom is tracked as a (fractional) shot
-- count rather than as degrees so that stance multipliers always apply to the *current*
-- stance — crouch-to-sprint mid-burst changes the cone immediately, not gradually.
function Ballistics.decayShots(shotsInBurst: number, weaponId: string, dt: number): number
	local w = Ballistics.weapon(weaponId)
	if w.bloomPerShot <= 0 then
		return 0
	end
	local shotsPerSec = w.recoverPerSec / w.bloomPerShot
	return math.max(0, shotsInBurst - shotsPerSec * math.max(0, dt))
end

-- Shot count at which a weapon is fully bloomed; useful for clamping accumulators.
function Ballistics.maxShots(weaponId: string): number
	local w = Ballistics.weapon(weaponId)
	if w.bloomPerShot <= 0 then
		return 0
	end
	return (w.maxSpreadDeg - w.baseSpreadDeg) / w.bloomPerShot
end

-- Two [0,1) randoms -> an angular offset uniformly distributed over the cone's disc.
-- sqrt on the radius keeps the distribution even by area instead of clustering at the centre.
function Ballistics.coneOffset(
	spreadDeg: number,
	r1: number,
	r2: number
): { yawDeg: number, pitchDeg: number }
	if spreadDeg <= 0 then
		return { yawDeg = 0, pitchDeg = 0 }
	end
	local radius = spreadDeg * math.sqrt(math.clamp(r1, 0, 1))
	local theta = 2 * math.pi * r2
	return {
		yawDeg = radius * math.cos(theta),
		pitchDeg = radius * math.sin(theta),
	}
end

-- Up vector to build an aim frame with. CFrame.lookAt is degenerate (NaN) when the look
-- direction is parallel to the up vector, which happens the moment a player aims straight
-- up or straight down — so callers must not hardcode Vector3.yAxis.
function Ballistics.safeUpAxis(directionY: number): "Y" | "Z"
	return math.abs(directionY) > 0.999 and "Z" or "Y"
end

-- Pixel gap between the crosshair's centre and each tick: the on-screen projection of the
-- cone at the current FOV, so the reticle is an honest readout rather than decoration.
function Ballistics.crosshairGap(spreadDeg: number, fovDeg: number, viewportHeightPx: number): number
	if spreadDeg <= 0 or viewportHeightPx <= 0 then
		return 0
	end
	local halfFovRad = math.rad(math.clamp(fovDeg, 1, 179) / 2)
	local pxPerRad = (viewportHeightPx / 2) / math.tan(halfFovRad)
	return pxPerRad * math.tan(math.rad(spreadDeg))
end

return Ballistics
