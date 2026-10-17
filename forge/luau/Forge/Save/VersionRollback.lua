--!strict
--[[
	VersionRollback — save-file version history with rollback points.

	Every save bumps a local version; a bounded ring of recent payloads
	lives under an index key so support can restore a player to any
	recorded point. Rollback writes forward (new version with old data) —
	history is never rewritten.
]]

local VersionRollback = {}

export type Snapshot = {
	version: number,
	at: number,
	payload: { [string]: any },
}

type Self = {
	maxHistory: number,
	clock: () -> number,
	history: { Snapshot },
	nextVersion: number,
}

VersionRollback.__index = VersionRollback

-- A shallow copy shares nested tables with the live profile. Editing the
-- inventory after the save then rewrites the snapshot, and a restore hands
-- that edited bag back as the recorded one. `seen` keeps a cyclic payload
-- from looping, and the cycle points at the copy rather than the original.
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

function VersionRollback.new(config: { maxHistory: number?, clock: (() -> number)? }): Self
	return setmetatable({
		maxHistory = config.maxHistory or 5,
		clock = config.clock or os.time,
		history = {},
		nextVersion = 1,
	}, VersionRollback)
end

function VersionRollback.record(self: Self, payload: { [string]: any }): Snapshot
	local snapshot: Snapshot = {
		version = self.nextVersion,
		at = self.clock(),
		payload = deepCopy(payload, {}),
	}
	self.nextVersion += 1
	table.insert(self.history, snapshot)
	while #self.history > self.maxHistory do
		table.remove(self.history, 1)
	end
	-- The stored payload stays in the ring. The caller gets another copy,
	-- so writing into the return value cannot rewrite the recorded point.
	return {
		version = snapshot.version,
		at = snapshot.at,
		payload = deepCopy(snapshot.payload, {}),
	}
end

function VersionRollback.list(self: Self): { Snapshot }
	-- A shallow clone of the ring shares the snapshot tables. Editing a
	-- listed payload would rewrite history, which restore then treats as
	-- the recorded point.
	local out = table.create(#self.history)
	for index, snapshot in self.history do
		out[index] = {
			version = snapshot.version,
			at = snapshot.at,
			payload = deepCopy(snapshot.payload, {}),
		}
	end
	return out
end

-- Restoring produces NEW data at a new version; nothing is deleted.
function VersionRollback.restore(self: Self, version: number): ({ [string]: any }?, string?)
	for _, snapshot in self.history do
		if snapshot.version == version then
			-- Colon: record reads this ring's clock and version. A dot call
			-- passes the payload as self, and self.clock is then nil.
			return self:record(snapshot.payload).payload, nil
		end
	end
	return nil, "unknown_version"
end

return VersionRollback
