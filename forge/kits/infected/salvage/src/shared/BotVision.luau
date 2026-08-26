--!strict
-- Bot perception maths. Pure and scalar-only so Lune can test it.
--
-- Previously a bot's only sense was "distance plus one raycast", applied over a full 360°:
-- they could never be flanked, never be surprised, and forgot a target the instant line of
-- sight broke. Infected bots skipped the raycast entirely, giving them perfect wallhacks.

local BotVision = {}

-- Smallest absolute difference between two headings, in degrees (handles wraparound).
function BotVision.yawDelta(fromDeg: number, toDeg: number): number
	local d = (toDeg - fromDeg) % 360
	if d > 180 then
		d = 360 - d
	end
	return math.abs(d)
end

-- Is a target inside the vision cone? `coneDeg` is the FULL cone width, so a 110° cone
-- means 55° either side of straight ahead.
function BotVision.inCone(facingDeg: number, targetDeg: number, coneDeg: number): boolean
	return BotVision.yawDelta(facingDeg, targetDeg) <= coneDeg / 2
end

-- A target is seen when it is in range, inside the cone, and not behind geometry.
-- Very close targets bypass the cone: you notice someone breathing on your neck.
function BotVision.canSee(
	dist: number,
	facingDeg: number,
	targetDeg: number,
	losClear: boolean,
	sightRange: number,
	coneDeg: number,
	peripheralRange: number?
): boolean
	if dist > sightRange or not losClear then
		return false
	end
	if dist <= (peripheralRange or 8) then
		return true
	end
	return BotVision.inCone(facingDeg, targetDeg, coneDeg)
end

-- Memory of a lost target decays; past this the bot gives up and returns to patrol.
function BotVision.memoryExpired(timeSinceContact: number, memorySeconds: number): boolean
	return timeSinceContact >= memorySeconds
end

-- Gunfire is heard within a radius, quieter the further away. Returns 0 when out of range.
-- Bots register the *location* of a shot, never the identity of the shooter — attributing a
-- shot to a player would let bots react to the hidden Patient Zero and leak the whole game.
function BotVision.hearing(dist: number, hearingRange: number): number
	if dist >= hearingRange or dist < 0 then
		return 0
	end
	return 1 - (dist / hearingRange)
end

-- How far off a remembered position a bot should look, growing as the memory gets staler
-- so searches fan out instead of pinning to a spot the target has long since left.
function BotVision.searchRadius(timeSinceContact: number, baseRadius: number, growthPerSec: number): number
	return baseRadius + math.max(0, timeSinceContact) * growthPerSec
end

return BotVision
