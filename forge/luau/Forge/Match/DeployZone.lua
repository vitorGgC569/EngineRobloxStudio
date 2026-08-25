--!strict
--[[
	DeployZone — server-authoritative AABB deploy regions per team.

	Before any resource is spent the server must be able to answer "may
	this player place this unit here?". Zones are axis-aligned rectangles
	on the XZ plane; each team may own several. Nothing here touches the
	world — the caller supplies positions already in zone space.
]]

local DeployZone = {}

export type Rect = {
	min: { x: number, z: number },
	max: { x: number, z: number },
}

export type Position = { x: number, z: number }

type Self = {
	zones: { [string]: { Rect } },
}

DeployZone.__index = DeployZone

function DeployZone.new(zones: { [string]: { Rect } }): Self
	assert(next(zones), "DeployZone needs at least one team zone")
	for team, rects in zones do
		assert(#rects > 0, ("team %q has no rects"):format(tostring(team)))
		for _, rect in rects do
			assert(rect.min.x <= rect.max.x and rect.min.z <= rect.max.z, "invalid rect bounds")
		end
	end
	return setmetatable({ zones = zones }, DeployZone)
end

local function inside(rect: Rect, pos: Position): boolean
	return pos.x >= rect.min.x and pos.x <= rect.max.x and pos.z >= rect.min.z and pos.z <= rect.max.z
end

-- Returns ok/reason for the authoritative check. Reason strings are stable
-- so probes can assert on them.
function DeployZone.check(self: Self, team: string, pos: Position): (boolean, string?)
	local rects = self.zones[team]
	if not rects then
		return false, "unknown_team"
	end
	for _, rect in rects do
		if inside(rect, pos) then
			return true, nil
		end
	end
	return false, "outside_zone"
end

function DeployZone.ownerOf(self: Self, pos: Position): string?
	for team, rects in self.zones do
		for _, rect in rects do
			if inside(rect, pos) then
				return team
			end
		end
	end
	return nil
end

return DeployZone
