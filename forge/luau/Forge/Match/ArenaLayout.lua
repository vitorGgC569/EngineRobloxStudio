--!strict
--[[
	ArenaLayout — declarative symmetric arena geometry.

	Building the same mirrored map by hand twice is how teams end up with
	two different maps. This lays out a standard two-half arena (floors,
	river, bridges, perimeter walls, spawns) as a pure piece list; the
	caller materializes it through WorldKit or any builder. Rebuilds are
	idempotent because the output is a function of the spec alone.
]]

local ArenaLayout = {}

export type Vec3 = { x: number, y: number, z: number }

export type Piece = {
	kind: string,
	center: Vec3,
	size: Vec3,
	team: string?,
}

export type Spec = {
	halfLength: number?,
	halfWidth: number?,
	riverWidth: number?,
	bridgeCount: number?,
	wallHeight: number?,
	floorY: number?,
	spawnOffsetZ: number?,
}

ArenaLayout.__index = ArenaLayout

function ArenaLayout.symmetric(spec: Spec?): { Piece }
	local s = spec or {}
	local halfLength = s.halfLength or 40
	local halfWidth = s.halfWidth or 24
	local riverWidth = s.riverWidth or 6
	local bridgeCount = math.max(1, math.floor(s.bridgeCount or 2))
	local wallHeight = s.wallHeight or 4
	local floorY = s.floorY or 0
	local spawnOffsetZ = s.spawnOffsetZ or (halfLength - 8)

	assert(halfLength > 0 and halfWidth > 0 and riverWidth >= 0)
	local pieces: { Piece } = {}

	for _, team in { "a", "b" } do
		local sign = if team == "a" then 1 else -1
		table.insert(pieces, {
			kind = "floor",
			center = { x = 0, y = floorY - 1, z = sign * (riverWidth / 2 + halfLength / 2) },
			size = { x = halfWidth * 2, y = 2, z = halfLength },
			team = team,
		})
		table.insert(pieces, {
			kind = "spawn",
			center = { x = 0, y = floorY, z = sign * spawnOffsetZ },
			size = { x = 8, y = 1, z = 8 },
			team = team,
		})
	end

	if riverWidth > 0 then
		table.insert(pieces, {
			kind = "river",
			center = { x = 0, y = floorY - 2.5, z = 0 },
			size = { x = halfWidth * 2, y = 3, z = riverWidth },
		})
	end

	local bridgeSpacing = (halfWidth * 2) / (bridgeCount + 1)
	for i = 1, bridgeCount do
		table.insert(pieces, {
			kind = "bridge",
			center = { x = -halfWidth + bridgeSpacing * i, y = floorY, z = 0 },
			size = { x = 4, y = 1, z = riverWidth + 4 },
		})
	end

	for _, sideX in { -1, 1 } do
		table.insert(pieces, {
			kind = "wall",
			center = { x = sideX * (halfWidth + 1), y = floorY + wallHeight / 2, z = 0 },
			size = { x = 2, y = wallHeight, z = riverWidth + halfLength * 2 + 2 },
		})
	end
	for _, sideZ in { -1, 1 } do
		table.insert(pieces, {
			kind = "wall",
			center = { x = 0, y = floorY + wallHeight / 2, z = sideZ * (halfLength + riverWidth / 2 + 1) },
			size = { x = halfWidth * 2 + 4, y = wallHeight, z = 2 },
		})
	end

	return pieces
end

return ArenaLayout
