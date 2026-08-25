--!strict
--[[
	UnitRunner — deterministic table-based combat simulation.

	Troops are plain tables, not Instances: the runner moves them toward
	targets, applies attacks on cooldown, and resolves specials (splash,
	lifesteal, buff aura) entirely in data. A whole match simulates in
	microseconds headless — which is what makes balance gates and replay
	evidence possible.
]]

local EntityCatalog = require(script.Parent.EntityCatalog)

local UnitRunner = {}

export type Vec2 = { x: number, z: number }

export type Unit = {
	key: string,
	team: string,
	unitId: string,
	pos: Vec2,
	hp: number,
	attackCooldown: number,
	buffMultiplier: number,
}

export type SimState = {
	units: { Unit },
	time: number,
	over: boolean,
	winner: string?,
	events: { { kind: string } },
}

type Self = {
	catalog: any,
	rng: () -> number,
}

UnitRunner.__index = UnitRunner

local function findTarget(self: Self, unit: Unit, state: SimState): Unit?
	local def = self.catalog:get(unit.unitId)
	if not def then
		return nil
	end
	local mode = def.targetMode or "nearest"
	local best: Unit? = nil
	local bestScore = math.huge
	for _, other in state.units do
		if other.team ~= unit.team and other.hp > 0 then
			local dx, dz = other.pos.x - unit.pos.x, other.pos.z - unit.pos.z
			local dist = math.sqrt(dx * dx + dz * dz)
			if dist <= def.range then
				local score: number
				if mode == "strongest" then
					score = -other.hp
				elseif mode == "weakest" then
					score = other.hp
				else
					score = dist
				end
				if score < bestScore then
					bestScore = score
					best = other
				end
			end
		end
	end
	return best
end

local function applyDamage(self: Self, state: SimState, attacker: Unit, target: Unit, amount: number): ()
	local def = self.catalog:get(attacker.unitId)
	table.insert(state.events, { kind = "damage", from = attacker.key, to = target.key, amount = amount })
	target.hp -= amount
	if def then
		local special = def.special
		if special and special.kind == "lifesteal" and special.fraction then
			attacker.hp = math.min(attacker.hp + amount * special.fraction, (self.catalog:get(attacker.unitId) :: EntityCatalog.UnitDef).hp)
			table.insert(state.events, { kind = "lifesteal", who = attacker.key })
		end
	end
end

function UnitRunner.new(config: { catalog: any, rng: (() -> number)? }): Self
	return setmetatable({ catalog = config.catalog, rng = config.rng or math.random }, UnitRunner)
end

function UnitRunner.initial(catalog: any, deployments: { { key: string, team: string, unitId: string, pos: Vec2 } }): SimState
	local units: { Unit } = {}
	for _, d in deployments do
		local def = catalog:get(d.unitId)
		assert(def, ("unknown unit %q"):format(d.unitId))
		table.insert(units, {
			key = d.key,
			team = d.team,
			unitId = d.unitId,
			pos = d.pos,
			hp = def.hp,
			attackCooldown = 0,
			buffMultiplier = 1,
		})
	end
	return { units = units, time = 0, over = false, winner = nil, events = {} }
end

-- One simulation step. Buff auras recompute, units close distance and
-- attack on cooldown; specials resolve inline.
function UnitRunner.step(self: Self, state: SimState, dt: number): SimState
	if state.over then
		return state
	end
	state.time += dt

	for _, unit in state.units do
		if unit.hp <= 0 then
			continue
		end
		local def = self.catalog:get(unit.unitId) :: EntityCatalog.UnitDef

		-- Buff aura refresh.
		unit.buffMultiplier = 1
		if def.special and def.special.kind == "buff" and def.special.radius then
			for _, ally in state.units do
				if ally.team == unit.team and ally.key ~= unit.key and ally.hp > 0 then
					local dx, dz = ally.pos.x - unit.pos.x, ally.pos.z - unit.pos.z
					if dx * dx + dz * dz <= (def.special.radius :: number) ^ 2 then
						unit.buffMultiplier *= (def.special.damageMultiplier or 1.2)
					end
				end
			end
		end

		local target = findTarget(self, unit, state)
		unit.attackCooldown -= dt
		if not target then
			continue
		end
		local dx, dz = target.pos.x - unit.pos.x, target.pos.z - unit.pos.z
		local dist = math.sqrt(dx * dx + dz * dz)

		if dist <= def.range then
			if unit.attackCooldown <= 0 then
				unit.attackCooldown = 1 / def.attackSpeed
				local amount = def.damage * unit.buffMultiplier
				applyDamage(self, state, unit, target, amount)

				local special = def.special
				if special and special.kind == "splash" and special.radius then
					for _, victim in state.units do
						if victim.team ~= unit.team and victim.hp > 0 and victim.key ~= target.key then
							local vx, vz = victim.pos.x - target.pos.x, victim.pos.z - target.pos.z
							if vx * vx + vz * vz <= (special.radius :: number) ^ 2 then
								applyDamage(self, state, unit, victim, amount * (special.fraction or 0.5))
							end
						end
					end
				end
			end
		else
			local stepLen = def.speed * dt
			unit.pos.x += dx / dist * stepLen
			unit.pos.z += dz / dist * stepLen
		end
	end

	local aliveA, aliveB = false, false
	for _, unit in state.units do
		if unit.hp > 0 then
			if unit.team == "a" then
				aliveA = true
			elseif unit.team == "b" then
				aliveB = true
			end
		end
	end
	if not aliveA or not aliveB then
		state.over = true
		state.winner = if aliveA then "a" elseif aliveB then "b" else nil
	end
	return state
end

return UnitRunner
