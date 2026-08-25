--!strict
--[[
	EntityCatalog — combat units as validated data with special hooks.

	Unit definitions are content: hp/damage/attackSpeed/range/cost plus an
	optional special (splash, lifesteal, buff aura, spawn-on-deploy). The
	catalog validates every definition at registration — a typo in a
	special's params is a boot error, not a runtime surprise.
]]

local EntityCatalog = {}

export type SpecialKind = "splash" | "lifesteal" | "buff" | "spawn"

export type Special = {
	kind: SpecialKind,
	radius: number?, -- splash/buff
	fraction: number?, -- lifesteal / buff multiplier
	count: number?, -- spawn
	unitId: string?, -- spawn target
	damageMultiplier: number?, -- buff
}

export type UnitDef = {
	id: string,
	hp: number,
	damage: number,
	attackSpeed: number, -- attacks per second
	range: number,
	speed: number,
	cost: number,
	size: number,
	targetMode: ("nearest" | "strongest" | "weakest")?,
	special: Special?,
}

type Self = {
	units: { [string]: UnitDef },
}

EntityCatalog.__index = EntityCatalog

local function validateSpecial(special: Special?): ()
	if not special then
		return
	end
	local kind = special.kind
	if kind == "splash" or kind == "buff" then
		assert(special.radius and special.radius > 0, ("%s needs radius > 0"):format(kind))
	elseif kind == "lifesteal" then
		assert(special.fraction and special.fraction > 0 and special.fraction <= 1, "lifesteal fraction in (0,1]")
	elseif kind == "spawn" then
		assert(special.unitId, "spawn needs unitId")
		assert(special.count and special.count >= 1, "spawn needs count >= 1")
	else
		error(("unknown special kind %s"):format(tostring(kind)))
	end
end

function EntityCatalog.new(): Self
	return setmetatable({ units = {} }, EntityCatalog)
end

function EntityCatalog.define(self: Self, def: UnitDef): ()
	assert(not self.units[def.id], ("duplicate unit %q"):format(def.id))
	assert(def.hp > 0 and def.damage >= 0, ("%s needs positive hp"):format(def.id))
	assert(def.attackSpeed > 0 and def.range >= 0 and def.speed >= 0, ("%s has invalid stats"):format(def.id))
	assert(def.cost >= 0 and def.size > 0, ("%s has invalid cost/size"):format(def.id))
	if def.targetMode then
		assert(
			def.targetMode == "nearest" or def.targetMode == "strongest" or def.targetMode == "weakest",
			("%s invalid targetMode"):format(def.id)
		)
	end
	validateSpecial(def.special)
	self.units[def.id] = table.clone(def)
end

function EntityCatalog.get(self: Self, id: string): UnitDef?
	return self.units[id]
end

-- Deploy-time expansion: spawn specials materialize extra units.
function EntityCatalog.expandDeploy(self: Self, id: string): { string }
	local def = self.units[id]
	assert(def, "unknown unit")
	local out = { id }
	local special = def.special
	if special and special.kind == "spawn" and special.unitId then
		for _ = 1, special.count :: number do
			table.insert(out, special.unitId :: string)
		end
	end
	return out
end

function EntityCatalog.list(self: Self): { UnitDef }
	local out: { UnitDef } = {}
	for _, def in self.units do
		table.insert(out, def)
	end
	table.sort(out, function(a, b)
		return a.cost < b.cost
	end)
	return out
end

return EntityCatalog
