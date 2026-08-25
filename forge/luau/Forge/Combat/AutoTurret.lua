--!strict
--[[
	AutoTurret — pure targeting and fire-cycle model for defensive units.

	Towers pick targets by mode, hold fire while cooling down, and report
	every shot as data. The caller applies damage to real entities; this
	module owns the decision loop so arena sims and live servers obey the
	same rules.
]]

local AutoTurret = {}

export type TargetCandidate = {
	key: string,
	dist: number,
	hp: number,
}

export type Shot = {
	targetKey: string,
	damage: number,
}

type Self = {
	range: number,
	damage: number,
	attackSpeed: number,
	targetMode: ("nearest" | "strongest" | "weakest"),
	cooldown: number,
}

AutoTurret.__index = AutoTurret

function AutoTurret.new(config: { range: number, damage: number, attackSpeed: number?, targetMode: ("nearest" | "strongest" | "weakest")? }): Self
	assert(config.range > 0 and config.damage >= 0 and (config.attackSpeed or 1) > 0, "invalid turret stats")
	return setmetatable({
		range = config.range,
		damage = config.damage,
		attackSpeed = config.attackSpeed or 1,
		targetMode = config.targetMode or "nearest",
		cooldown = 0,
	}, AutoTurret)
end

function AutoTurret.selectTarget(self: Self, candidates: { TargetCandidate }): TargetCandidate?
	local best: TargetCandidate? = nil
	local bestScore = math.huge
	for _, candidate in candidates do
		if candidate.dist > self.range then
			continue
		end
		local score: number
		if self.targetMode == "strongest" then
			score = -candidate.hp
		elseif self.targetMode == "weakest" then
			score = candidate.hp
		else
			score = candidate.dist
		end
		if score < bestScore then
			bestScore = score
			best = candidate
		end
	end
	return best
end

-- Advances the turret; returns shots fired this tick.
function AutoTurret.tick(self: Self, dt: number, candidates: { TargetCandidate }): { Shot }
	self.cooldown -= dt
	if self.cooldown > 0 then
		return {}
	end
	local target = self:selectTarget(candidates)
	if not target then
		return {}
	end
	self.cooldown = 1 / self.attackSpeed
	return { { targetKey = target.key, damage = self.damage } }
end

return AutoTurret
