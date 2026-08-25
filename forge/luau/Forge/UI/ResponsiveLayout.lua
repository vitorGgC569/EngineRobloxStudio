--!strict
--[[
	ResponsiveLayout — deterministic layout solver for phone/tablet/desktop.

	Layout math must be computed, not eyeballed: from viewport size,
	notch insets and a UI scale it derives the usable safe area and the
	puzzle-grid geometry. The same breakpoint name feeds visual quality
	so layout and effects can never disagree about what device this is.
]]

local ResponsiveLayout = {}

export type Viewport = { width: number, height: number }
export type Insets = { top: number?, bottom: number?, left: number?, right: number? }

export type Solved = {
	breakpoint: string,
	safeArea: { x: number, y: number, w: number, h: number },
	cols: number,
	rows: number,
	cell: number,
	originX: number,
	originY: number,
}

type Self = {
	uiScale: number,
	targetCells: number,
	minCell: number,
	maxCell: number,
}

ResponsiveLayout.__index = ResponsiveLayout

function ResponsiveLayout.new(config: { uiScale: number?, targetCells: number?, minCell: number?, maxCell: number? }): Self
	return setmetatable({
		uiScale = config.uiScale or 1,
		targetCells = config.targetCells or 8,
		minCell = config.minCell or 28,
		maxCell = config.maxCell or 96,
	}, ResponsiveLayout)
end

function ResponsiveLayout.breakpointFor(width: number, height: number): string
	local minSide = math.min(width, height)
	if minSide < 500 then
		return "phone"
	elseif minSide < 900 then
		return "tablet"
	end
	return "desktop"
end

function ResponsiveLayout.solve(self: Self, viewport: Viewport, insets: Insets?): Solved
	assert(viewport.width > 0 and viewport.height > 0, "invalid viewport")
	local ins = insets or {}
	local safeX = (ins.left or 0) * self.uiScale
	local safeY = (ins.top or 0) * self.uiScale
	local safeW = math.max(0, viewport.width - safeX - (ins.right or 0) * self.uiScale)
	local safeH = math.max(0, viewport.height - safeY - (ins.bottom or 0) * self.uiScale)

	local cell = math.clamp(math.min(safeW, safeH) / self.targetCells, self.minCell, self.maxCell)
	local cols = math.max(1, math.floor(safeW / cell))
	local rows = math.max(1, math.floor(safeH / cell))

	return {
		breakpoint = ResponsiveLayout.breakpointFor(viewport.width, viewport.height),
		safeArea = { x = safeX, y = safeY, w = safeW, h = safeH },
		cols = cols,
		rows = rows,
		cell = cell,
		originX = safeX + (safeW - cols * cell) / 2,
		originY = safeY + (safeH - rows * cell) / 2,
	}
end

return ResponsiveLayout
