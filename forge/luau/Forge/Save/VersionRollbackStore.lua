--!strict
--[[
	VersionRollbackStore — persists the version ring across servers.

	Combines the pure ring (Save.VersionRollback semantics) with two
	stores: a DataStore for payloads and an OrderedDataStore indexing
	timestamps, so support can list/restore from any server. Failures
	return ok=false; history is never truncated on error.

	The index used to be one global store whose every value was 0 and
	whose key was only the second. GetSortedAsync orders by value, so
	the page was not oldest-first, and two players writing in the same
	second shared a key. Each player now has their own index, the value
	is the timestamp, and the payload written is a copy.
]]

local VersionRollbackStore = {}

export type Snapshot = { version: number, at: number }

type Self = {
	payloadStore: any,
	indexStore: any,
	playerKey: string,
	indexName: string,
	maxHistory: number,
	seq: number,
}

VersionRollbackStore.__index = VersionRollbackStore

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

function VersionRollbackStore.indexName(playerKey: string): string
	return "RQE_RollbackIndex_" .. playerKey
end

function VersionRollbackStore.new(playerKey: string, maxHistory: number?, stores: { payload: any, index: any }?): any
	local self = setmetatable({
		playerKey = playerKey,
		indexName = VersionRollbackStore.indexName(playerKey),
		maxHistory = maxHistory or 5,
		seq = 0,
	}, VersionRollbackStore)
	if stores then
		self.payloadStore = stores.payload
		self.indexStore = stores.index
		return self
	end
	local okPayload, payload = pcall(function()
		return game:GetService("DataStoreService"):GetDataStore("RQE_RollbackPayloads")
	end)
	local okIndex, index = pcall(function()
		return game:GetService("DataStoreService"):GetOrderedDataStore(self.indexName)
	end)
	self.payloadStore = if okPayload then payload else nil
	self.indexStore = if okIndex then index else nil
	return self
end

-- Records one snapshot; returns the version number or nil+reason.
function VersionRollbackStore.record(self: any, payload: { [string]: any }): (number?, string?)
	if not self.payloadStore or not self.indexStore then
		return nil, "stores_unavailable"
	end

	local entries: { { key: string, value: number } } = {}
	local listed = pcall(function()
		local pages = self.indexStore:GetSortedAsync(true, self.maxHistory + 1)
		for _, entry in pages:GetCurrentPage() do
			table.insert(entries, { key = tostring(entry.key), value = tonumber(entry.value) or 0 })
		end
	end)
	if not listed then
		return nil, "index_unavailable"
	end

	self.seq += 1
	local now = os.time()
	-- Zero-padded so "…_0002" sorts before "…_0010". An unpadded key makes
	-- the tenth snapshot in a second look older than the second, and the
	-- trim deletes the newer one.
	local id = string.format("%d_%06d", now, self.seq)
	local payloadKey = self.playerKey .. ":" .. id
	local stored = deepCopy(payload, {})
	local writeOk = pcall(function()
		self.payloadStore:SetAsync(payloadKey, stored)
		self.indexStore:SetAsync(id, now)
	end)
	if not writeOk then
		return nil, "write_failed"
	end

	-- Oldest first. The suffix is the sequence, compared as a number: the
	-- text "1000000" sorts before "999999", which would drop the newer save.
	local function sequence(key: string): number
		local suffix = string.match(key, "_(%d+)$")
		return tonumber(suffix) or 0
	end
	table.sort(entries, function(a, b)
		if a.value == b.value then
			return sequence(a.key) < sequence(b.key)
		end
		return a.value < b.value
	end)
	while #entries >= self.maxHistory do
		local oldest = table.remove(entries, 1) :: { key: string, value: number }
		pcall(function()
			self.indexStore:RemoveAsync(oldest.key)
			self.payloadStore:RemoveAsync(self.playerKey .. ":" .. oldest.key)
		end)
	end

	return self.seq, nil
end

return VersionRollbackStore
