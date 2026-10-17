--!strict
--[[
	TeamSpawns — team-tagged spawn selection.

	Spawns are tagged (CollectionService names on the server); this picks
	a random spawn of the requested team with a lift offset so characters
	do not intersect the anchor. Deterministic under injected rng.
]]

local TeamSpawns = {}

export type SpawnPoint = { x: number, y: number, z: number }

type Self = {
	spawns: { [string]: { SpawnPoint } },
	rng: () -> number,
	liftY: number,
}

TeamSpawns.__index = TeamSpawns

-- table.clone keeps each point. Moving x after register then changes the
-- next pick. pick() already returns a fresh table of numbers.
local function deepCopy(value: any, seen: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in value :: { [any]: any } do
		copy[key] = deepCopy(item, seen)
	end
	return copy
end

function TeamSpawns.new(rng: (() -> number)?): Self
	return setmetatable({ spawns = {}, rng = rng or math.random, liftY = 3 }, TeamSpawns)
end

function TeamSpawns.register(self: Self, team: string, points: { SpawnPoint }): ()
	assert(#points > 0, ("team %q needs at least one spawn"):format(team))
	self.spawns[team] = deepCopy(points, {}) :: { SpawnPoint }
end

function TeamSpawns.pick(self: Self, team: string): (SpawnPoint?, string?)
	local points = self.spawns[team]
	if not points or #points == 0 then
		return nil, "no_spawns_for_team"
	end
	local point = points[(self.rng() * #points) // 1 + 1]
	return { x = point.x, y = point.y + self.liftY, z = point.z }, nil
end

function TeamSpawns.count(self: Self, team: string): number
	local points = self.spawns[team]
	return if points then #points else 0
end

return TeamSpawns
