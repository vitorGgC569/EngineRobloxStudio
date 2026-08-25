--!strict
--[[
	VisualLayouts — layout behavior as declarative plans.

	Layouts are data, not instance trees: each plan names the Roblox
	layout object to create and its exact configuration. The presentation
	binds plans; probes can assert on them without a single Instance.
]]

local VisualLayouts = {}

export type LayoutPlan = {
	kind: "UIListLayout" | "UIGridLayout",
	fillDirection: string,
	horizontalAlignment: string?,
	verticalAlignment: string?,
	padding: { udim: number, offset: number },
	sortOrder: string,
	cellSize: { x: number, y: number }?,
	cellPadding: { x: number, y: number }?,
}

local function padding(scale: number?, offset: number?): { udim: number, offset: number }
	return { udim = scale or 0, offset = offset or 0 }
end

function VisualLayouts.vertical(config: { paddingScale: number?, paddingOffset: number?, horizontalAlignment: string? }): LayoutPlan
	return {
		kind = "UIListLayout",
		fillDirection = "Vertical",
		horizontalAlignment = config.horizontalAlignment,
		padding = padding(config.paddingScale, config.paddingOffset),
		sortOrder = "LayoutOrder",
	}
end

function VisualLayouts.horizontal(config: { paddingScale: number?, paddingOffset: number?, verticalAlignment: string? }): LayoutPlan
	return {
		kind = "UIListLayout",
		fillDirection = "Horizontal",
		verticalAlignment = config.verticalAlignment,
		padding = padding(config.paddingScale, config.paddingOffset),
		sortOrder = "LayoutOrder",
	}
end

-- Grid for inventory/board cells; cell sizes in offset pixels so the
-- ResponsiveLayout solver remains the single source of geometry.
function VisualLayouts.grid(config: { cellX: number, cellY: number, gapX: number?, gapY: number?, fillDirection: string? }): LayoutPlan
	assert(config.cellX > 0 and config.cellY > 0, "cell must be positive")
	return {
		kind = "UIGridLayout",
		fillDirection = config.fillDirection or "LeftToRight",
		padding = padding(0, 0),
		cellSize = { x = config.cellX, y = config.cellY },
		cellPadding = { x = config.gapX or 4, y = config.gapY or 4 },
		sortOrder = "LayoutOrder",
	}
end

return VisualLayouts
