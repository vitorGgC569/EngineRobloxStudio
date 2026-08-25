--!strict
--[[
	PickupCrate — physical collectible crate model with anti-distance
	check and consumption animation plan.

	Touched events lie; the server re-checks the collector actually is
	near. Rewards are weighted (bonus for VIP), consumption returns a
	presentation plan (sparkles/fade) instead of touching instances.
]]

local CrateRoll = require(script.Parent.Parent.Progression.CrateRoll)

local PickupCrate = {}

export type CollectResult = {
	ok: boolean,
	reason: string?,
	playerPoints: number,
	dropId: string?,
	animation: { kind: string, duration: number }?,
}

type Self = {
	crateId: string,
	ownerUserId: number?,
	pointsRange: { number },
	vipBonusChance: number,
	drops: any,
	maxCollectDistance: number,
	collected: boolean,
}

PickupCrate.__index = PickupCrate

function PickupCrate.new(config: {
	crateId: string,
	ownerUserId: number?,
	pointsRange: { number },
	drops: any,
	maxCollectDistance: number?,
}): Self
	assert(#config.pointsRange == 2 and config.pointsRange[1] <= config.pointsRange[2], "pointsRange = {min, max}")
	return setmetatable({
		crateId = config.crateId,
		ownerUserId = config.ownerUserId,
		pointsRange = config.pointsRange,
		vipBonusChance = 0.25,
		drops = config.drops,
		maxCollectDistance = config.maxCollectDistance or 30,
		collected = false,
	}, PickupCrate)
end

-- Server-side collection gate: distance + ownership + single use.
function PickupCrate.collect(
	self: Self,
	collectorUserId: number,
	collectorPos: { x: number, z: number },
	cratePos: { x: number, z: number },
	rng: () -> number,
	isVip: boolean?
): CollectResult
	if self.collected then
		return { ok = false, reason = "already_collected", playerPoints = 0 }
	end
	local dx, dz = cratePos.x - collectorPos.x, cratePos.z - collectorPos.z
	if dx * dx + dz * dz > self.maxCollectDistance ^ 2 then
		return { ok = false, reason = "too_far", playerPoints = 0 }
	end
	if self.ownerUserId and self.ownerUserId ~= collectorUserId then
		return { ok = false, reason = "owned_by_other", playerPoints = 0 }
	end
	self.collected = true

	local minP, maxP = self.pointsRange[1], self.pointsRange[2]
	local bonusRoll = rng()
	local points = math.floor(minP + (maxP - minP) * rng() * ((isVip and bonusRoll < self.vipBonusChance) and 1.5 or 1))
	local drop = self.drops:roll(rng)

	return {
		ok = true,
		playerPoints = points,
		dropId = drop.id,
		animation = { kind = "fade_sparkle", duration = 0.6 },
	}
end

return PickupCrate
