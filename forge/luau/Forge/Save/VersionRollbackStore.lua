--!strict
--[[
	VersionRollbackStore — persists the version ring across servers.

	Combines the pure ring (Save.VersionRollback semantics) with two
	stores: a DataStore for payloads and an OrderedDataStore indexing
	timestamps, so support can list/restore from any server. Failures
	return ok=false; history is never truncated on error.
]]

local DataStoreService = game:GetService("DataStoreService")

local VersionRollbackStore = {}

export type Snapshot = { version: number, at: number }

type Self = {
	payloadStore: any,
	indexStore: any,
	playerKey: string,
	maxHistory: number,
}

VersionRollbackStore.__index = VersionRollbackStore

function VersionRollbackStore.new(playerKey: string, maxHistory: number?): any
	local self = setmetatable({
		playerKey = playerKey,
		maxHistory = maxHistory or 5,
	}, VersionRollbackStore)
	local okPayload, payload = pcall(function()
		return DataStoreService:GetDataStore("RQE_RollbackPayloads")
	end)
	local okIndex, index = pcall(function()
		return DataStoreService:GetOrderedDataStore("RQE_RollbackIndex")
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

	local versions: { number } = {}
	local listed = pcall(function()
		local pages = self.indexStore:GetSortedAsync(false, self.maxHistory + 1)
		for _, entry in pages:GetCurrentPage() do
			table.insert(versions, tonumber(entry.key) :: number)
		end
	end)
	if not listed then
		return nil, "index_unavailable"
	end

	local now = os.time()
	local versionKey = self.playerKey .. ":" .. tostring(now)
	local writeOk = pcall(function()
		self.payloadStore:SetAsync(versionKey, payload)
		self.indexStore:SetAsync(tostring(now), 0)
	end)
	if not writeOk then
		return nil, "write_failed"
	end

	-- Trim beyond the ring bound (oldest first), never on failure.
	table.sort(versions)
	while #versions >= self.maxHistory do
		local oldest = table.remove(versions, 1) :: number
		pcall(function()
			self.indexStore:RemoveAsync(tostring(oldest))
			self.payloadStore:RemoveAsync(self.playerKey .. ":" .. tostring(oldest))
		end)
	end

	return now, nil
end

return VersionRollbackStore
