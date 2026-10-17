--!strict
--[[
	FairnessBudget — assisted hands with an evidence-gated debit.

	When the puzzle hands a player nothing playable, fairness grants
	assistance — but only after verifying no legal move existed, and each
	grant debits a bounded budget that refills slowly. Assistance without
	evidence would be a cheat channel; without budget it would be infinite.
]]

local FairnessBudget = {}

type Self = {
	maxAssists: number, -- per window
	windowSeconds: number,
	refillPerWindow: number,
	used: { number }, -- timestamps of grants
	clock: () -> number,
}

FairnessBudget.__index = FairnessBudget

function FairnessBudget.new(config: { maxAssists: number?, windowSeconds: number?, refillPerWindow: number?, clock: (() -> number)? }): Self
	-- nil is the default. 0 is a real window. A negative window puts the
	-- cutoff in the future, so a grant stored at now is dropped at once.
	local windowSeconds = config.windowSeconds
	if windowSeconds == nil then
		windowSeconds = 600
	end
	assert(type(windowSeconds) == "number" and windowSeconds >= 0, "windowSeconds must be >= 0")
	-- `or` keeps -1: Luau treats it as truthy, and the first real request
	-- then sees the budget already exhausted. 0 stays and means no assists.
	local maxAssists = config.maxAssists or 5
	assert(type(maxAssists) == "number" and maxAssists >= 0, "maxAssists must be >= 0")
	return setmetatable({
		maxAssists = maxAssists,
		windowSeconds = windowSeconds,
		refillPerWindow = config.refillPerWindow or 1,
		used = {},
		clock = config.clock or os.time,
	}, FairnessBudget)
end

local function prune(self: Self): ()
	local cutoff = self.clock() - self.windowSeconds
	local kept: { number } = {}
	for _, at in self.used do
		if at >= cutoff then
			table.insert(kept, at)
		end
	end
	self.used = kept
end

-- Only an explicit false is evidence that no legal move existed. nil and
-- true are not that evidence, so they must not debit the budget.
function FairnessBudget.requestAssist(self: Self, hasLegalMove: boolean): (boolean, string?)
	if hasLegalMove ~= false then
		return false, "legal_move_exists"
	end
	prune(self)
	if #self.used >= self.maxAssists then
		return false, "budget_exhausted"
	end
	table.insert(self.used, self.clock())
	return true, nil
end

function FairnessBudget.remaining(self: Self): number
	prune(self)
	return math.max(0, self.maxAssists - #self.used)
end

return FairnessBudget
