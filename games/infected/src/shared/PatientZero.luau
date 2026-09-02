--!strict
-- Pure Patient Zero selection: players who were PZ within the last N rounds are
-- deprioritized (weight 1 vs 10). rng is injected for testability.

local PatientZero = {}

export type Candidate = { userId: number, roundsSincePZ: number? } -- nil = never been PZ

function PatientZero.weightFor(roundsSincePZ: number?, recentWindow: number): number
	if roundsSincePZ ~= nil and roundsSincePZ <= recentWindow then
		return 1
	end
	return 10
end

function PatientZero.select(candidates: { Candidate }, recentWindow: number, rng: () -> number): number
	assert(#candidates > 0, "no candidates for Patient Zero")
	local total = 0
	local weights = table.create(#candidates)
	for i, c in candidates do
		local w = PatientZero.weightFor(c.roundsSincePZ, recentWindow)
		weights[i] = w
		total += w
	end
	local roll = rng() * total
	local acc = 0
	for i, c in candidates do
		acc += weights[i]
		if roll < acc then
			return c.userId
		end
	end
	return candidates[#candidates].userId -- float edge: roll == total
end

return PatientZero
