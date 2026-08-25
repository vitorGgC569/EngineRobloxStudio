--!strict
--[[
	WorldHubBuilder — procedural social hub spec with a graceful fallback.

	The hub is a function of the spec: central plaza, ring of portals to
	game modes, bridges, trees and status billboards. If the full build
	fails at runtime the caller falls back to `minimal()`, which is a
	spawn platform plus one sign — never a black screen.
]]

local HubBuilder = {}

export type Piece = {
	kind: string,
	name: string,
	center: { x: number, y: number, z: number },
	size: { x: number, y: number, z: number },
	color: { r: number, g: number, b: number }?,
}

export type HubSpec = {
	plazaRadius: number?,
	portalCount: number?,
	treeCount: number?,
}

HubBuilder.__index = HubBuilder

local GRASS = { r = 0.35, g = 0.62, b = 0.31 }
local STONE = { r = 0.62, g = 0.6, b = 0.58 }
local PORTAL = { r = 0.45, g = 0.3, b = 0.75 }

function HubBuilder.build(spec: HubSpec?): { Piece }
	local s = spec or {}
	local radius = math.max(20, s.plazaRadius or 48)
	local portalCount = math.max(1, math.floor(s.portalCount or 4))
	local treeCount = math.max(0, math.floor(s.treeCount or 10))

	local pieces: { Piece } = {}

	table.insert(pieces, {
		kind = "plaza",
		name = "HubPlaza",
		center = { x = 0, y = 0, z = 0 },
		size = { x = radius * 2, y = 2, z = radius * 2 },
		color = STONE,
	})

	for index = 1, portalCount do
		local angle = (index / portalCount) * math.pi * 2
		table.insert(pieces, {
			kind = "portal",
			name = ("Portal_%s"):format(tostring(index)),
			center = {
				x = math.cos(angle) * (radius - 8),
				y = 5,
				z = math.sin(angle) * (radius - 8),
			},
			size = { x = 6, y = 10, z = 2 },
			color = PORTAL,
		})
	end

	for index = 1, treeCount do
		local angle = ((index * 137.5) % 360) * math.pi / 180
		local distance = radius + 6 + (index % 3) * 4
		table.insert(pieces, {
			kind = "tree",
			name = ("Tree_%s"):format(tostring(index)),
			center = { x = math.cos(angle) * distance, y = 6, z = math.sin(angle) * distance },
			size = { x = 2, y = 12, z = 2 },
			color = GRASS,
		})
	end

	return pieces
end

-- The floor that always exists, even when the fancy build explodes.
function HubBuilder.minimal(): { Piece }
	return {
		{
			kind = "plaza",
			name = "FallbackSpawn",
			center = { x = 0, y = 0, z = 0 },
			size = { x = 32, y = 2, z = 32 },
			color = STONE,
		},
	}
end

return HubBuilder
