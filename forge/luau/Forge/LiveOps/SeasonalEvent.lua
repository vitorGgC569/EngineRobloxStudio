--!strict
--[[
	SeasonalEvent — temporary currency, spawn waves and milestone rewards.

	Seasonal content is the same shape every time: a throwaway currency,
	targets that spawn in waves scaled by how many players are hunting,
	collection with a reach check, and rewards at collection milestones.
	Pure bookkeeping; spawning/collecting happen at call sites.
]]

local SeasonalEvent = {}

type Self = {
	currencyName: string,
	milestones: { { at: number, rewardId: string } },
	baseWaveSize: number,
	maxWaveBonus: number,
	respawnSeconds: number,
}

SeasonalEvent.__index = SeasonalEvent

function SeasonalEvent.new(config: {
	currencyName: string,
	milestones: { { at: number, rewardId: string } }?,
	baseWaveSize: number?,
	maxWaveBonus: number?,
	respawnSeconds: number?,
}): Self
	local milestones = table.clone(config.milestones or {})
	table.sort(milestones, function(a, b)
		return a.at < b.at
	end)
	return setmetatable({
		currencyName = config.currencyName,
		milestones = milestones,
		baseWaveSize = config.baseWaveSize or 10,
		maxWaveBonus = config.maxWaveBonus or 20,
		respawnSeconds = config.respawnSeconds or 120,
	}, SeasonalEvent)
end

-- Wave density scales with hunters, capped so a full server doesn't flood.
function SeasonalEvent.waveSize(self: Self, playerCount: number): number
	assert(playerCount >= 0)
	return math.min(self.baseWaveSize + playerCount * 2, self.baseWaveSize + self.maxWaveBonus)
end

function SeasonalEvent.canCollect(self: Self, collectorPos: { x: number, z: number }, targetPos: { x: number, z: number }, maxDistance: number): boolean
	local dx, dz = targetPos.x - collectorPos.x, targetPos.z - collectorPos.z
	return math.sqrt(dx * dx + dz * dz) <= maxDistance
end

-- Returns unclaimed milestone rewards crossed by `collected` total.
function SeasonalEvent.milestonesReached(self: Self, collected: number, claimed: { [string]: boolean }): { string }
	local out: { string } = {}
	for _, milestone in self.milestones do
		if collected >= milestone.at and not claimed[milestone.rewardId] then
			table.insert(out, milestone.rewardId)
		end
	end
	return out
end

return SeasonalEvent
