--!strict
--[[
	QuestRotation — deterministic daily/periodic quest assignment.

	"Daily quests" must be identical for every server a player joins and
	unpredictable enough to feel fresh: the pick is a pure function of
	(periodId, userId) over a seeded shuffle — no storage, no drift.
]]

local QuestRotation = {}

type Self = {
	poolSize: number,
	perPeriod: number,
	periodSeconds: number,
}

QuestRotation.__index = QuestRotation

function QuestRotation.new(config: { poolSize: number, perPeriod: number?, periodSeconds: number? }): Self
	assert(config.poolSize > 0)
	return setmetatable({
		poolSize = config.poolSize,
		perPeriod = math.min(config.perPeriod or 3, config.poolSize),
		periodSeconds = config.periodSeconds or 86400,
	}, QuestRotation)
end

function QuestRotation.periodFor(self: Self, timestamp: number): number
	return math.floor(timestamp / self.periodSeconds)
end

-- Stable picks for this period+user; same inputs always yield same set.
function QuestRotation.pick(self: Self, periodId: number, userId: number): { number }
	local seed = (periodId * 1000003 + userId * 2654435761) % 2147483647
	local s = if seed == 0 then 1 else seed
	local order = {}
	for i = 1, self.poolSize do
		order[i] = i
	end
	for i = #order, 2, -1 do
		s = bit32.bxor(s, bit32.lshift(s, 13))
		s = bit32.bxor(s, bit32.rshift(s, 17))
		s = bit32.bxor(s, bit32.lshift(s, 5))
		local j = (s % i) + 1
		order[i], order[j] = order[j], order[i]
	end
	local out = {}
	for i = 1, self.perPeriod do
		out[i] = order[i]
	end
	table.sort(out)
	return out
end

return QuestRotation
