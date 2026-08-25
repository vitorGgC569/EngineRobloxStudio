--!strict
--[[
	DropperChain — throughput-capped dropper production model.

	A tycoon dies when a player leaves 5000 ore on the floor. The cap rule
	from production: droppers only produce while the live-item ledger is
	under `limit(level)`, where limit grows per purchased level plus an
	optional premium bonus. Removing items reopens production for free.
]]

local DropperChain = {}

type Self = {
	baseLimit: number,
	perLevelBonus: number,
	premiumBonus: number,
}

DropperChain.__index = DropperChain

function DropperChain.new(config: { baseLimit: number?, perLevelBonus: number?, premiumBonus: number? }): Self
	return setmetatable({
		baseLimit = config.baseLimit or 50,
		perLevelBonus = config.perLevelBonus or 25,
		premiumBonus = config.premiumBonus or 25,
	}, DropperChain)
end

function DropperChain.limit(self: Self, level: number, premium: boolean?): number
	assert(level >= 1, "level starts at 1")
	local limit = self.baseLimit + (level - 1) * self.perLevelBonus
	if premium then
		limit += self.premiumBonus
	end
	return limit
end

function DropperChain.canProduce(self: Self, liveCount: number, level: number, premium: boolean?): boolean
	assert(liveCount >= 0, "liveCount cannot be negative")
	return liveCount < self:limit(level, premium)
end

return DropperChain
