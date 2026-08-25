--!strict
--[[
	MonteCarlo — headless strategy simulation for balance gates.

	Balance claims need evidence before release: run N deterministic
	simulations of a strategy over the seeded rng, aggregate time-to-
	threshold and outcome distributions, and compare against budget
	assertions. Pure — runs in CI in milliseconds per thousand sims.
]]

local MonteCarlo = {}

export type SimResult = {
	steps: number,
	reachedThreshold: boolean,
	finalValue: number,
}

export type Aggregate = {
	runs: number,
	successRate: number,
	p50Steps: number,
	p95Steps: number,
	meanSteps: number,
}

type Self = {}

MonteCarlo.__index = {}

local function percentile(sorted: { number }, p: number): number
	if #sorted == 0 then
		return 0
	end
	local index = math.clamp(math.ceil(p / 100 * #sorted), 1, #sorted)
	return sorted[index]
end

-- step(state, rng) -> (newValue, done?) driven by the caller's model.
function MonteCarlo.run(
	config: {
		runs: number,
		maxSteps: number,
		seed: number,
		init: () -> number,
		step: (value: number, rng: () -> number) -> (number, boolean?),
		threshold: number?,
	}
): { results: { SimResult }, aggregate: Aggregate }
	local results: { SimResult } = {}
	for _ = 1, config.runs do
		local s = config.seed + #results
		local rng = function()
			s = bit32.bxor(s, bit32.lshift(s, 13))
			s = bit32.bxor(s, bit32.rshift(s, 17))
			s = bit32.bxor(s, bit32.lshift(s, 5))
			return s / 4294967296
		end
		local value = config.init()
		local steps = 0
		local reached = false
		while steps < config.maxSteps do
			steps += 1
			local done
			value, done = config.step(value, rng)
			if config.threshold and value >= config.threshold then
				reached = true
				break
			end
			if done then
				break
			end
		end
		table.insert(results, { steps = steps, reachedThreshold = reached, finalValue = value })
	end

	local successCount = 0
	local stepsList: { number } = {}
	local totalSteps = 0
	for _, result in results do
		if result.reachedThreshold then
			successCount += 1
		end
		table.insert(stepsList, result.steps)
		totalSteps += result.steps
	end
	table.sort(stepsList)

	return {
		results = results,
		aggregate = {
			runs = #results,
			successRate = if #results > 0 then successCount / #results else 0,
			p50Steps = percentile(stepsList, 50),
			p95Steps = percentile(stepsList, 95),
			meanSteps = if #results > 0 then totalSteps / #results else 0,
		},
	}
end

return MonteCarlo
