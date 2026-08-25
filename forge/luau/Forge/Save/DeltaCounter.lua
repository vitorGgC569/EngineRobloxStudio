--!strict
--[[
	DeltaCounter — add-only counters that merge instead of overwrite.

	Sessions accumulate DELTAS locally; a commit pushes their SUM through the
	adapter's update transform, so concurrent servers never need session locks
	and a save from one server cannot erase another's progress.

	Why retries do not double-count: the local batch is cleared ONLY after the
	adapter reports success. A failed commit leaves both halves untouched —
	the store discards the transform's result, and the deltas stay pending —
	so the retry re-applies the exact same sum once. The one contested write is
	applied exactly as many times as it SUCCEEDED: zero, then one.

		local counters = DeltaCounter.new()
		counters:add("kills", 1)
		local ok = counters:commit(adapter, "player_1/stats")

	Pure: every DataStore touch goes through the injected adapter
	`{ get(key) -> ok, data ; update(key, transform) -> ok, data }`.
]]

export type Adapter = {
	get: (self: Adapter, key: string) -> (boolean, any),
	update: (self: Adapter, key: string, transform: (any) -> any) -> (boolean, any),
}

local DeltaCounter = {}
DeltaCounter.__index = DeltaCounter

function DeltaCounter.new()
	local self = setmetatable({}, DeltaCounter)
	self._deltas = {} :: { [string]: number }
	self._remote = {} :: { [string]: number }
	return self
end

-- Accumulate one delta locally. NaN is rejected; anything else numeric is
-- accepted so callers decide whether a counter may go down.
function DeltaCounter:add(name: string, amount: number)
	local value = tonumber(amount)
	if value == nil or value ~= value or name == "" then
		return
	end
	local deltas: { [string]: number } = (self :: any)._deltas
	deltas[name] = (deltas[name] or 0) + (value :: number)
end

-- Snapshot of uncommitted deltas (a copy — mutating it changes nothing).
function DeltaCounter:pending(): { [string]: number }
	return table.clone(self._deltas)
end

-- Adopt remote truth after a load. Pending deltas are deliberately kept:
-- they were earned before this point and will merge on top at next commit.
function DeltaCounter:applyRemote(remoteState: any)
	local mirror = {} :: { [string]: number }
	if typeof(remoteState) == "table" then
		for name, value in remoteState :: { [any]: any } do
			local n = tonumber(value)
			if type(name) == "string" and n ~= nil and n == n then
				mirror[name] = n
			end
		end
	end
	self._remote = mirror
end

-- Current view of one counter: remote truth plus uncommitted local deltas.
function DeltaCounter:total(name: string): number
	local selfAny = self :: any
	return (tonumber(selfAny._remote[name]) or 0) + (tonumber(selfAny._deltas[name]) or 0)
end

-- Merge the accumulated sum into `key` via the adapter's update transform.
--
-- The transform only ever ADDS the captured batch to whatever the store
-- currently holds, which keeps it correct when the store invokes it more than
-- once under a write race. On success the batch is dropped; on failure it is
-- kept intact for the retry (see the header for why that cannot double-count).
-- With nothing pending this is a no-op that still reports success.
function DeltaCounter:commit(adapter: Adapter, key: string): (boolean, any)
	if next(self._deltas) == nil then
		return true, self._remote
	end

	local deltas = (self :: any)._deltas
	local ok, state = adapter:update(key, function(remote)
		local merged: { [string]: any } = if typeof(remote) == "table" then table.clone(remote :: { [string]: any }) else {}
		for name, delta in deltas :: { [string]: number } do
			merged[name] = (tonumber(merged[name]) or 0) + delta
		end
		return merged
	end)

	if ok then
		table.clear(deltas)
		if typeof(state) == "table" then
			(self :: any)._remote = state :: { [string]: number }
		end
	end

	return ok, state
end

return DeltaCounter
