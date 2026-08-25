--!strict
--[[
	TweenWalker — step-by-step walking as discrete tween plans.

	Movement on a 2D map is a sequence of steps, each one a tween of the
	world image by the walk vector with a per-step duration derived from
	walk speed. The walker emits plans; the presentation layer runs them.
	Diagonals are normalized so speed is direction-independent.
]]

local TweenWalker = {}

export type Vec2 = { x: number, y: number }

type StepPlan = {
	dx: number,
	dy: number,
	durationSeconds: number,
}

type Self = {
	pixelsPerSecondX: number,
	pixelsPerSecondY: number,
	minStepPixels: number,
}

TweenWalker.__index = TweenWalker

function TweenWalker.new(config: { pixelsPerSecondX: number?, pixelsPerSecondY: number?, minStepPixels: number? }): Self
	return setmetatable({
		pixelsPerSecondX = config.pixelsPerSecondX or 120,
		pixelsPerSecondY = config.pixelsPerSecondY or 90,
		minStepPixels = config.minStepPixels or 24,
	}, TweenWalker)
end

-- Builds the plan for one step toward `direction` (normalized internally).
function TweenWalker.planStep(self: Self, dirX: number, dirY: number): StepPlan?
	local len = math.sqrt(dirX * dirX + dirY * dirY)
	if len < 1e-6 then
		return nil
	end
	local dx = dirX / len * self.minStepPixels
	local dy = dirY / len * self.minStepPixels
	local duration = math.max(dx / self.pixelsPerSecondX, dy / self.pixelsPerSecondY)
	return { dx = dx, dy = dy, durationSeconds = duration }
end

return TweenWalker
