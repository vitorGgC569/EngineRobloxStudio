--!strict
--[[
	IncomeEngine — cached aggregation of passive income sources.

	Contributors layer three ways and reduce to one number — the shape every
	idle game reinvents: (base + Σadd) · Πmul, all raised to Πpow. The total is
	cached and only rebuilt when a contributor or external multiplier changes.

		local engine = IncomeEngine.new({ base = 10 })
		engine:addContributor("prestige", { kind = "mul", value = 3 })
		engine:setMultiplier("mul", 2)
		engine:total()      --> 60
		engine:tick(0.5)    --> 30 earned over half a second
]]

local IncomeEngine = {}

export type ContributorKind = "add" | "mul" | "pow"

export type Contributor = {
	kind: ContributorKind,
	value: number,
}

-- ============================== construction ================================

IncomeEngine.__index = IncomeEngine

export type IncomeEngine = typeof(setmetatable({} :: {
	base: number,
	contributors: { [string]: Contributor },
	multipliers: { [ContributorKind]: number },
	dirty: boolean,
	cachedTotal: number,
}, IncomeEngine))

function IncomeEngine.new(config: { base: number }?): IncomeEngine
	return setmetatable({
		base = if config ~= nil and config.base ~= nil then config.base else 1,
		contributors = {},
		multipliers = {},
		dirty = true,
		cachedTotal = 0,
	}, IncomeEngine)
end

-- ============================= contributors ==================================

function IncomeEngine.addContributor(self: IncomeEngine, id: string, contributor: Contributor)
	local kind = contributor.kind
	assert(kind == "add" or kind == "mul" or kind == "pow", "IncomeEngine.addContributor expects kind 'add', 'mul' or 'pow'")
	self.contributors[id] = { kind = kind, value = contributor.value }
	self.dirty = true
end

function IncomeEngine.removeContributor(self: IncomeEngine, id: string)
	if self.contributors[id] ~= nil then
		self.contributors[id] = nil
		self.dirty = true
	end
end

-- ========================== external multipliers =============================

function IncomeEngine.setMultiplier(self: IncomeEngine, kind: ContributorKind, value: number)
	self.multipliers[kind] = value
	self.dirty = true
end

function IncomeEngine.clearMultiplier(self: IncomeEngine, kind: ContributorKind)
	if self.multipliers[kind] ~= nil then
		self.multipliers[kind] = nil
		self.dirty = true
	end
end

-- =============================== evaluation ==================================

function IncomeEngine.total(self: IncomeEngine): number
	if self.dirty then
		local addTotal = 0
		local mulTotal = 1
		local powTotal = 1
		for _, contributor in self.contributors do
			if contributor.kind == "add" then
				addTotal += contributor.value
			elseif contributor.kind == "mul" then
				mulTotal *= contributor.value
			elseif contributor.kind == "pow" then
				powTotal *= contributor.value
			end
		end
		addTotal += self.multipliers["add"] or 0
		mulTotal *= self.multipliers["mul"] or 1
		powTotal *= self.multipliers["pow"] or 1
		local total = (self.base + addTotal) * mulTotal
		if powTotal ~= 1 then
			total = total ^ powTotal
		end
		self.cachedTotal = total
		self.dirty = false
	end
	return self.cachedTotal
end

function IncomeEngine.tick(self: IncomeEngine, dt: number): number
	return self:total() * dt
end

return IncomeEngine
