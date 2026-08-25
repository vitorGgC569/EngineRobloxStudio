--!strict
--[[
	TelemetrySync — cross-server counter merge with idempotent flush.

	Servers accumulate counters locally (plays, wins, revenue) and flush
	them periodically into a shared record via an injected update
	transform. Deltas clear ONLY after the store reports success, so a
	failed write retries later without double counting.
]]

local TelemetrySync = {}

export type Store = {
	update: (self: Store, key: string, transform: (any) -> any) -> (boolean),
}

type Self = {
	storeKey: string,
	store: Store,
	pending: { [string]: number },
	lastFlushAt: number,
	minFlushInterval: number,
	clock: () -> number,
	totalFlushed: number,
}

TelemetrySync.__index = TelemetrySync

function TelemetrySync.new(config: { store: Store, storeKey: string?, minFlushInterval: number?, clock: (() -> number)? }): Self
	return setmetatable({
		store = config.store,
		storeKey = config.storeKey or "telemetry/aggregate",
		pending = {},
		lastFlushAt = 0,
		minFlushInterval = config.minFlushInterval or 30,
		clock = config.clock or os.time,
		totalFlushed = 0,
	}, TelemetrySync)
end

-- Local increment; NaN/inf rejected (fail-closed against poison data).
function TelemetrySync.add(self: Self, name: string, delta: number): ()
	assert(delta == delta and delta ~= math.huge and delta > -math.huge, "delta must be finite")
	self.pending[name] = (self.pending[name] or 0) + delta
end

-- Flushes pending deltas into the shared record. Remote values merge by
-- ADDITION inside the transform; local deltas zero only on success.
function TelemetrySync.flush(self: Self): (boolean, { [string]: number }?)
	local now = self.clock()
	if now - self.lastFlushAt < self.minFlushInterval then
		return false, nil
	end
	if next(self.pending) == nil then
		return true, {}
	end

	local batch = table.clone(self.pending)
	local ok = self.store:update(self.storeKey, function(remote: any)
		local merged: { [string]: number } = {}
		if type(remote) == "table" then
			for name, value in remote :: { [string]: any } do
				if type(value) == "number" then
					merged[name] = value
				end
			end
		end
		for name, delta in batch do
			merged[name] = (merged[name] or 0) + delta
		end
		return merged
	end)

	if not ok then
		return false, nil -- keep pending; retry after interval
	end

	local flushed = batch
	for name in batch do
		self.pending[name] = nil
	end
	self.lastFlushAt = now
	for _, delta in flushed do
		self.totalFlushed += 1
	end
	return true, flushed
end

function TelemetrySync.pendingCount(self: Self): number
	local n = 0
	for _ in self.pending do
		n += 1
	end
	return n
end

return TelemetrySync
