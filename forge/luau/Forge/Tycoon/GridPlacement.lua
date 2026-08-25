--!strict
--[[
	GridPlacement — pure placement math for tycoon building.

	The miner's-haven school of placement: raycast to the ground plane,
	snap to a grid of cell centres, respect the footprint rotated in 90°
	steps, refuse anything that pokes outside the plot or overlaps an
	obstacle/occupied cell, and hand the server real cell keys so it can
	validate every placement itself.

	Everything here is planar XZ math. The client renders ghosts from the
	plan; the server runs the same planner and only trusts `fits`.
]]

local GridPlacement = {}

export type Vec2 = { x: number, z: number }
export type Rect = { minX: number, minZ: number, maxX: number, maxZ: number }

export type ItemSpec = {
	id: string,
	footprintX: number,
	footprintZ: number,
}

type Self = {
	cellSize: number,
	bounds: Rect,
	obstacles: { Rect },
	items: { [string]: ItemSpec },
	occupied: { [string]: string },
}

GridPlacement.__index = GridPlacement

local function rectOverlaps(a: Rect, b: Rect): boolean
	return a.minX < b.maxX and a.maxX > b.minX and a.minZ < b.maxZ and a.maxZ > b.minZ
end

function GridPlacement.new(config: {
	cellSize: number?,
	bounds: Rect,
	obstacles: { Rect }?,
	items: { ItemSpec }?,
}): Self
	local cellSize = config.cellSize or 3
	assert(cellSize > 0, "cellSize must be positive")
	assert(config.bounds.minX < config.bounds.maxX and config.bounds.minZ < config.bounds.maxZ, "invalid bounds")
	local items: { [string]: ItemSpec } = {}
	for _, item in config.items or {} do
		assert(not items[item.id], ("duplicate item id %q"):format(item.id))
		assert(item.footprintX > 0 and item.footprintZ > 0, ("item %q needs positive footprints"):format(item.id))
		items[item.id] = item
	end
	return setmetatable({
		cellSize = cellSize,
		bounds = config.bounds,
		obstacles = table.clone(config.obstacles or {}),
		items = items,
		occupied = {},
	}, GridPlacement)
end

function GridPlacement.item(self: Self, id: string): ItemSpec?
	return self.items[id]
end

-- Rotation in quarter turns clockwise; odd turns swap the footprint axes.
function GridPlacement.rotatedFootprint(self: Self, item: ItemSpec, rotation: number): (number, number)
	local r = ((rotation % 4) + 4) % 4
	if r % 2 == 1 then
		return item.footprintZ, item.footprintX
	end
	return item.footprintX, item.footprintZ
end

function GridPlacement.snap(self: Self, pos: Vec2): Vec2
	local c = self.cellSize
	local function snapAxis(v: number, origin: number): number
		return math.floor((v - origin) / c + 0.5) * c + origin
	end
	return { x = snapAxis(pos.x, self.bounds.minX), z = snapAxis(pos.z, self.bounds.minZ) }
end

local function footprintRect(self: Self, item: ItemSpec, rotation: number, pos: Vec2): Rect
	local fx, fz = self:rotatedFootprint(item, rotation)
	local hx, hz = fx * self.cellSize / 2, fz * self.cellSize / 2
	return { minX = pos.x - hx, minZ = pos.z - hz, maxX = pos.x + hx, maxZ = pos.z + hz }
end

local function cellsOf(rect: Rect, cellSize: number, originX: number, originZ: number): { string }
	local keys: { string } = {}
	local i0 = math.floor((rect.minX - originX) / cellSize)
	local i1 = math.floor((rect.maxX - originX - 1e-6) / cellSize)
	local j0 = math.floor((rect.minZ - originZ) / cellSize)
	local j1 = math.floor((rect.maxZ - originZ - 1e-6) / cellSize)
	for i = i0, i1 do
		for j = j0, j1 do
			table.insert(keys, i .. "," .. j)
		end
	end
	return keys
end

-- Authoritative check: inside plot, clear of static obstacles and free cells.
-- Returns ok plus the first reason/collision found (stable for probes).
function GridPlacement.fits(self: Self, itemId: string, rotation: number, pos: Vec2): (boolean, string?)
	local item = self.items[itemId]
	if not item then
		return false, "unknown_item"
	end
	local rect = footprintRect(self, item, rotation, pos)
	if rect.minX < self.bounds.minX or rect.maxX > self.bounds.maxX or rect.minZ < self.bounds.minZ or rect.maxZ > self.bounds.maxZ then
		return false, "outside_plot"
	end
	for _, obstacle in self.obstacles do
		if rectOverlaps(rect, obstacle) then
			return false, "obstacle"
		end
	end
	local originX, originZ = self.bounds.minX, self.bounds.minZ
	for _, key in cellsOf(rect, self.cellSize, originX, originZ) do
		if self.occupied[key] then
			return false, "occupied"
		end
	end
	return true, nil
end

function GridPlacement.place(self: Self, placementId: string, itemId: string, rotation: number, pos: Vec2): boolean
	local ok = self:fits(itemId, rotation, pos)
	if not ok then
		return false
	end
	local item = self.items[itemId] :: ItemSpec
	local rect = footprintRect(self, item, rotation, pos)
	for _, key in cellsOf(rect, self.cellSize, self.bounds.minX, self.bounds.minZ) do
		self.occupied[key] = placementId
	end
	return true
end

function GridPlacement.release(self: Self, placementId: string): number
	local removed = 0
	for key, holder in self.occupied do
		if holder == placementId then
			self.occupied[key] = nil
			removed += 1
		end
	end
	return removed
end

function GridPlacement.isOccupied(self: Self, pos: Vec2): boolean
	local key = table.concat(
		{
			math.floor((pos.x - self.bounds.minX) / self.cellSize),
			math.floor((pos.z - self.bounds.minZ) / self.cellSize),
		},
		","
	)
	return self.occupied[key] ~= nil
end

-- Offsets (in world units) for placing `count` copies packed around the
-- first, used by bulk-buy flows.
function GridPlacement.multiOffsets(self: Self, itemId: string, count: number, rotation: number): { Vec2 }
	local item = self.items[itemId]
	assert(item, "unknown_item")
	local fx, fz = self:rotatedFootprint(item, rotation)
	local stepX, stepZ = fx * self.cellSize, fz * self.cellSize
	local cols = math.ceil(math.sqrt(count))
	local offsets: { Vec2 } = {}
	for index = 0, count - 1 do
		local row = math.floor(index / cols)
		local col = index % cols
		table.insert(offsets, {
			x = col * stepX,
			z = row * stepZ,
		})
	end
	return offsets
end

-- Magnetic axis lock: dominant direction wins, the other axis is zeroed.
function GridPlacement.axisLock(self: Self, dir: Vec2): Vec2
	if math.abs(dir.x) >= math.abs(dir.z) then
		return { x = if dir.x ~= 0 then math.sign(dir.x) else 0, z = 0 }
	end
	return { x = 0, z = math.sign(dir.z) }
end

return GridPlacement
