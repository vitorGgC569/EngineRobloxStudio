--!strict
-- Plot layout.
--
-- The allocator is the thing that decides whether a server holds 4 players or
-- 8, and whether their plots are cramped or generous. Making it data-driven is
-- what stops "add more plots" from being a rewrite -- and computing the bounds
-- here is what lets a validator prove the plots do not overlap without knowing
-- anything about this game.

local Grid = {}

export type Layout = {
	columns: number,
	rows: number,
	plotSize: number,
	gap: number,
	origin: Vector3,
	--- Leaves a corridor down the middle for the hub, so plots never sit on top
	--- of the shared area.
	centreAisle: number,
}

export type Slot = {
	index: number,
	name: string,
	centre: Vector3,
	size: Vector3,
	min: Vector3,
	max: Vector3,
	column: number,
	row: number,
	--- The side the plot faces, so gates and signage point at the hub.
	facing: number,
}

--- Choose a column count that keeps the grid close to square.
function Grid.columnsFor(count: number): number
	if count < 1 or count % 1 ~= 0 then
		error("count must be a positive integer", 2)
	end
	if count <= 2 then
		return count
	end
	return math.ceil(math.sqrt(count))
end

--- Build a layout for `count` plots.
---
--- `columns` is worth setting explicitly for a tycoon: two columns either side
--- of a central avenue reads far better than the near-square default, and it
--- keeps every plot one turn off the main street.
function Grid.layout(count: number, plotSize: number, gap: number, origin: Vector3?, centreAisle: number?, columns: number?): Layout
	if count < 1 or count % 1 ~= 0 then
		error("count must be a positive integer", 2)
	end
	if plotSize <= 0 then
		error("plotSize must be positive", 2)
	end
	if gap <= 0 then
		error("gap must be positive", 2)
	end
	if centreAisle ~= nil and centreAisle < 0 then
		error("centreAisle must be non-negative", 2)
	end
	local resolvedColumns = columns or Grid.columnsFor(count)
	if resolvedColumns < 1 or resolvedColumns % 1 ~= 0 then
		error("columns must be a positive integer", 2)
	end
	return {
		columns = resolvedColumns,
		rows = math.ceil(count / resolvedColumns),
		plotSize = plotSize,
		gap = gap,
		origin = origin or Vector3.new(0, 0, 0),
		centreAisle = centreAisle or 0,
	}
end

--- Resolve every slot's world position and bounds.
function Grid.slots(layout: Layout, count: number, names: { string }?): { Slot }
	local slots: { Slot } = {}
	local pitch = layout.plotSize + layout.gap
	local totalWidth = layout.columns * pitch - layout.gap
	local totalDepth = layout.rows * pitch - layout.gap

	for index = 1, count do
		local column = (index - 1) % layout.columns
		local row = math.floor((index - 1) / layout.columns)

		local x = layout.origin.X - totalWidth / 2 + layout.plotSize / 2 + column * pitch
		local z = layout.origin.Z - totalDepth / 2 + layout.plotSize / 2 + row * pitch

		-- Push the halves apart so the hub corridor runs between them.
		if layout.centreAisle > 0 then
			local half = layout.centreAisle / 2
			x += if x < layout.origin.X then -half else half
		end

		local centre = Vector3.new(x, layout.origin.Y, z)
		local half = Vector3.new(layout.plotSize / 2, 0, layout.plotSize / 2)

		table.insert(slots, {
			index = index,
			name = if names and names[index] then names[index] else string.format("Plot%d", index),
			centre = centre,
			size = Vector3.new(layout.plotSize, 0, layout.plotSize),
			min = centre - half,
			max = centre + half,
			column = column,
			row = row,
			facing = if x < layout.origin.X then 90 else -90,
		})
	end

	return slots
end

--- The footprint the whole grid occupies, for sizing the ground under it.
function Grid.extent(layout: Layout, count: number): (Vector3, Vector3)
	local slots = Grid.slots(layout, count)
	local min, max
	for _, slot in ipairs(slots) do
		min = if min then min:Min(slot.min) else slot.min
		max = if max then max:Max(slot.max) else slot.max
	end
	if min == nil or max == nil then
		return layout.origin, Vector3.new(0, 0, 0)
	end
	return (min + max) / 2, max - min
end

--- Sanity check the layout before anything is built from it.
--- Cheaper than discovering an overlap from a screenshot.
function Grid.validate(layout: Layout, count: number): { string }
	local problems = {}
	if layout.gap <= 0 then
		table.insert(problems, "gap must be positive or plots will touch")
	end
	if layout.plotSize <= 0 then
		table.insert(problems, "plotSize must be positive")
	end

	local slots = Grid.slots(layout, count)
	for i = 1, #slots do
		for j = i + 1, #slots do
			local a, b = slots[i], slots[j]
			local overlapX = math.min(a.max.X, b.max.X) - math.max(a.min.X, b.min.X)
			local overlapZ = math.min(a.max.Z, b.max.Z) - math.max(a.min.Z, b.min.Z)
			if overlapX > 0 and overlapZ > 0 then
				table.insert(problems, string.format("%s overlaps %s", a.name, b.name))
			end
		end
	end
	return problems
end

return Grid
