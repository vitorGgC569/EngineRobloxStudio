--!strict
--[[
	QualityTierSelector — post-processing tier by screen capability.

	Full effects (bloom, sun rays, DoF, particle budgets) vs reduced:
	chosen from screen size and frame budget, deliberately separate from
	the user's Reduced Motion preference — performance is measured,
	accessibility is respected.
]]

local QualityTierSelector = {}

export type Tier = "full" | "reduced"

type Self = {
	minFullWidth: number,
	minFullHeight: number,
	frameBudgetMs: number,
	recentFrameTimes: { number },
	windowSize: number,
}

QualityTierSelector.__index = QualityTierSelector

function QualityTierSelector.new(config: {
	minFullWidth: number?,
	minFullHeight: number?,
	frameBudgetMs: number?,
	windowSize: number?,
}): Self
	return setmetatable({
		minFullWidth = config.minFullWidth or 900,
		minFullHeight = config.minFullHeight or 600,
		frameBudgetMs = config.frameBudgetMs or 16.9,
		recentFrameTimes = {},
		windowSize = config.windowSize or 60,
	}, QualityTierSelector)
end

-- Screen-size gate; small viewports never get full effects.
function QualityTierSelector.byScreen(width: number, height: number, minWidth: number?, minHeight: number?): Tier
	local minW = minWidth or 900
	local minH = minHeight or 600
	return if width >= minW and height >= minH then "full" else "reduced"
end

-- Rolling frame-time average feeds the performance gate.
function QualityTierSelector.recordFrame(self: Self, frameMs: number): ()
	table.insert(self.recentFrameTimes, frameMs)
	while #self.recentFrameTimes > self.windowSize do
		table.remove(self.recentFrameTimes, 1)
	end
end

function QualityTierSelector.averageFrameMs(self: Self): number
	local total = 0
	for _, t in self.recentFrameTimes do
		total += t
	end
	return if #self.recentFrameTimes > 0 then total / #self.recentFrameTimes else 0
end

-- Combined decision: screen gate first, then sustained frame overruns.
function QualityTierSelector.select(self: Self, width: number, height: number): (Tier, string)
	local byScreen = QualityTierSelector.byScreen(width, height, self.minFullWidth, self.minFullHeight)
	if byScreen == "reduced" then
		return "reduced", "screen_below_minimum"
	end
	if #self.recentFrameTimes >= self.windowSize then
		local avg = self:averageFrameMs()
		if avg > self.frameBudgetMs * 1.15 then
			return "reduced", "frame_budget_exceeded"
		end
	end
	return "full", "eligible"
end

return QualityTierSelector
