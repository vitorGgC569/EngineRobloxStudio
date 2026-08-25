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
		payload = table.clone(payload),
	}
	self.nextVersion += 1
	table.insert(self.history, snapshot)
	while #self.history > self.maxHistory do
		table.remove(self.history, 1)
	end
	return snapshot
end

function VersionRollback.list(self: Self): { Snapshot }
	return table.clone(self.history)
end

-- Restoring produces NEW data at a new version; nothing is deleted.
function VersionRollback.restore(self: Self, version: number): ({ [string]: any }?, string?)
	for _, snapshot in self.history do
		if snapshot.version == version then
			return self.record(snapshot.payload).payload, nil
		end
	end
	return nil, "unknown_version"
end

return VersionRollback
