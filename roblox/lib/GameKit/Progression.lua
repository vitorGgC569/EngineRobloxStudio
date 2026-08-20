--!strict
-- L6: progression and pacing.
--
-- A progression ladder is easy to write and hard to price. The failure mode is
-- never "the code is wrong" -- it is that tier three takes eleven minutes and
-- tier four takes ninety, and nobody finds out until players stop appearing in
-- the retention chart.
--
-- So this module does two things. It runs the ladder at runtime, and it exposes
-- `pacing`, which computes time-to-tier from a declared income curve **without a
-- running game**. That function is the whole reason the module is written in
-- pure Luau with no engine dependency: it can be executed in a headless Open
-- Cloud task or a plain Luau runtime over the same catalogue the game ships,
-- across thousands of simulated player-hours, before anyone plays anything.

local Progression = {}

export type Tier = {
	id: string,
	index: number,
	displayName: string,
	--- Cumulative currency required to reach this tier from zero.
	cost: number,
	currency: string,
	--- Multiplier applied to income once this tier is held.
	incomeMultiplier: number?,
}

export type Unlock = {
	id: string,
	requiresTier: string,
	displayName: string?,
}

export type Ladder = {
	tiers: { Tier },
	unlocks: { [string]: Unlock },
	byId: { [string]: Tier },
	tierAt: (self: Ladder, index: number) -> Tier?,
	nextAfter: (self: Ladder, tierId: string?) -> Tier?,
	unlocked: (self: Ladder, tierId: string?) -> { string },
	multiplierAt: (self: Ladder, tierId: string?) -> number,
}

local function fail(message: string): never
	error("[GameKit.Progression] " .. message, 3)
end

--- Everything wrong with a ladder, before it prices anything.
function Progression.validate(tiers: { Tier }, unlocks: { Unlock }?): { string }
	local problems: { string } = {}
	if type(tiers) ~= "table" or #tiers == 0 then
		table.insert(problems, "a ladder needs at least one tier")
		return problems
	end

	local seen: { [string]: true } = {}
	local previousCost = -math.huge
	local previousIndex = 0

	for position, tier in ipairs(tiers) do
		local label = string.format("tiers[%d]", position)
		if type(tier.id) ~= "string" or tier.id == "" then
			table.insert(problems, label .. " needs an id")
			continue
		end
		if seen[tier.id] then
			table.insert(problems, string.format("tier id %q is declared twice", tier.id))
		end
		seen[tier.id] = true

		if type(tier.index) ~= "number" or tier.index % 1 ~= 0 then
			table.insert(problems, label .. " index must be an integer")
		elseif tier.index <= previousIndex then
			table.insert(problems, string.format(
				"tier %q has index %d, which does not follow %d; ladders must be ordered",
				tier.id, tier.index, previousIndex
			))
		else
			previousIndex = tier.index
		end

		if type(tier.cost) ~= "number" or tier.cost < 0 then
			table.insert(problems, label .. " cost must be a non-negative number")
		elseif tier.cost < previousCost then
			-- A cheaper later tier means the ladder can be climbed out of order,
			-- and every balance assumption downstream is void.
			table.insert(problems, string.format(
				"tier %q costs %.0f, less than the tier before it (%.0f)",
				tier.id, tier.cost, previousCost
			))
		else
			previousCost = tier.cost
		end

		if type(tier.currency) ~= "string" or tier.currency == "" then
			table.insert(problems, label .. " must name a currency")
		end
		if tier.incomeMultiplier ~= nil and (type(tier.incomeMultiplier) ~= "number" or tier.incomeMultiplier <= 0) then
			table.insert(problems, label .. " incomeMultiplier must be positive when present")
		end
	end

	local unlockIds: { [string]: true } = {}
	for position, unlock in ipairs(unlocks or {}) do
		local label = string.format("unlocks[%d]", position)
		if type(unlock.id) ~= "string" or unlock.id == "" then
			table.insert(problems, label .. " needs an id")
			continue
		end
		if unlockIds[unlock.id] then
			table.insert(problems, string.format("unlock id %q is declared twice", unlock.id))
		end
		unlockIds[unlock.id] = true
		if not seen[unlock.requiresTier] then
			table.insert(problems, string.format(
				"unlock %q requires unknown tier %q", unlock.id, tostring(unlock.requiresTier)
			))
		end
	end

	return problems
end

function Progression.define(tiers: { Tier }, unlocks: { Unlock }?): Ladder
	local problems = Progression.validate(tiers, unlocks)
	if #problems > 0 then
		fail("ladder is invalid:\n- " .. table.concat(problems, "\n- "))
	end

	local byId: { [string]: Tier } = {}
	for _, tier in ipairs(tiers) do
		byId[tier.id] = tier
	end
	local unlockMap: { [string]: Unlock } = {}
	for _, unlock in ipairs(unlocks or {}) do
		unlockMap[unlock.id] = unlock
	end

	local ladder = {} :: any
	ladder.tiers = tiers
	ladder.byId = byId
	ladder.unlocks = unlockMap

	function ladder:tierAt(index: number): Tier?
		for _, tier in ipairs(tiers) do
			if tier.index == index then
				return tier
			end
		end
		return nil
	end

	function ladder:nextAfter(tierId: string?): Tier?
		if tierId == nil then
			return tiers[1]
		end
		local current = byId[tierId]
		if current == nil then
			fail(string.format("unknown tier %q", tostring(tierId)))
		end
		for _, tier in ipairs(tiers) do
			if tier.index > current.index then
				return tier
			end
		end
		return nil
	end

	function ladder:unlocked(tierId: string?): { string }
		local reachedIndex = if tierId ~= nil and byId[tierId] ~= nil then byId[tierId].index else -math.huge
		local available: { string } = {}
		for id, unlock in pairs(unlockMap) do
			local required = byId[unlock.requiresTier]
			if required ~= nil and required.index <= reachedIndex then
				table.insert(available, id)
			end
		end
		table.sort(available)
		return available
	end

	function ladder:multiplierAt(tierId: string?): number
		if tierId == nil then
			return 1
		end
		local current = byId[tierId]
		if current == nil then
			fail(string.format("unknown tier %q", tostring(tierId)))
		end
		-- Multipliers compound: holding tier three means having passed one and
		-- two. Reading only the current tier's multiplier is the classic way a
		-- late-game economy silently under-pays.
		local product = 1
		for _, tier in ipairs(tiers) do
			if tier.index <= current.index then
				product *= tier.incomeMultiplier or 1
			end
		end
		return product
	end

	return ladder :: Ladder
end

export type PacingStep = {
	tierId: string,
	index: number,
	cost: number,
	--- Currency per second available while climbing towards this tier.
	incomeRate: number,
	secondsFromPrevious: number,
	secondsFromStart: number,
}

export type PacingReport = {
	steps: { PacingStep },
	totalSeconds: number,
	--- Largest jump in time-to-next-tier, and where it happens. This is the
	--- number that answers "does progression stall".
	worstRatio: number,
	worstAtTier: string?,
}

--- Compute time-to-tier from a base income rate, without running the game.
---
--- `baseIncomePerSecond` is income at tier zero; each tier's compounding
--- multiplier is applied as it is reached. The report exposes the ratio between
--- consecutive climbs, because an even ladder feels like progress and a ladder
--- whose fourth step takes eight times the third feels like a wall -- and the
--- ratio is visible here long before anyone plays.
function Progression.pacing(ladder: Ladder, baseIncomePerSecond: number): PacingReport
	if type(baseIncomePerSecond) ~= "number" or baseIncomePerSecond <= 0 then
		fail("baseIncomePerSecond must be positive")
	end

	local steps: { PacingStep } = {}
	local elapsed = 0
	local spent = 0
	local previousDuration: number? = nil
	local worstRatio = 1
	local worstAtTier: string? = nil
	local previousTierId: string? = nil

	for _, tier in ipairs(ladder.tiers) do
		local rate = baseIncomePerSecond * ladder:multiplierAt(previousTierId)
		local remaining = math.max(tier.cost - spent, 0)
		local duration = remaining / rate
		elapsed += duration
		spent = tier.cost

		if previousDuration ~= nil and previousDuration > 0 then
			local ratio = duration / previousDuration
			if ratio > worstRatio then
				worstRatio = ratio
				worstAtTier = tier.id
			end
		end
		previousDuration = duration
		previousTierId = tier.id

		table.insert(steps, {
			tierId = tier.id,
			index = tier.index,
			cost = tier.cost,
			incomeRate = rate,
			secondsFromPrevious = duration,
			secondsFromStart = elapsed,
		})
	end

	return {
		steps = steps,
		totalSeconds = elapsed,
		worstRatio = worstRatio,
		worstAtTier = worstAtTier,
	}
end

--- Pacing complaints, expressed as a policy rather than a chart.
---
--- Defaults chosen to catch the two shapes that actually drive players away: a
--- first tier so slow that nobody reaches it, and a single step that takes
--- several times longer than the one before it.
function Progression.pacingProblems(report: PacingReport, policy: { [string]: any }?): { string }
	local rules = policy or {}
	local maximumFirstTierSeconds = rules.maximumFirstTierSeconds or 90
	local maximumStepRatio = rules.maximumStepRatio or 3.0
	local maximumTotalSeconds = rules.maximumTotalSeconds

	local problems: { string } = {}
	local first = report.steps[1]
	if first ~= nil and first.secondsFromPrevious > maximumFirstTierSeconds then
		table.insert(problems, string.format(
			"first tier %q takes %.0fs, above the %.0fs onboarding budget; most players never see the loop pay out",
			first.tierId, first.secondsFromPrevious, maximumFirstTierSeconds
		))
	end
	if report.worstRatio > maximumStepRatio and report.worstAtTier ~= nil then
		table.insert(problems, string.format(
			"tier %q takes %.1fx as long as the step before it, above the %.1fx limit; progression stalls here",
			report.worstAtTier, report.worstRatio, maximumStepRatio
		))
	end
	if maximumTotalSeconds ~= nil and report.totalSeconds > maximumTotalSeconds then
		table.insert(problems, string.format(
			"the full ladder takes %.0fs, above the %.0fs budget",
			report.totalSeconds, maximumTotalSeconds
		))
	end
	return problems
end

return Progression
