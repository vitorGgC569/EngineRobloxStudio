--!strict
--[[
	DataStoreAdapter — the concrete Store behind Save's pure modules.

	ServerProfile/LiveConfig/Gatekeeper consume an injected
	{ get, update } interface; this is its DataStoreService binding,
	with bounded retries and Studio-safe failure (returns ok=false so
	pure layers degrade instead of erroring).
]]

local DataStoreService = game:GetService("DataStoreService")

local DataStoreAdapter = {}

export type Store = {
	get: (self: any, key: string) -> (boolean, any?),
	update: (self: any, key: string, transform: (any) -> any) -> (boolean, any?),
}

local Adapter = {}
Adapter.__index = Adapter

function DataStoreAdapter.new(storeName: string, retries: number?): any
	return setmetatable({
		_storeName = storeName,
		_retries = retries or 2,
	}, Adapter)
end

function Adapter._datastore(self: any): any
	if not self._cache then
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore(self._storeName)
		end)
		if not ok then
			return nil
		end
		self._cache = store
	end
	return self._cache
end

function Adapter.get(self: any, key: string): (boolean, any?)
	local store = self:_datastore()
	if not store then
		return false, nil
	end
	for attempt = 0, self._retries do
		local ok, data = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			return true, data
		end
		task.wait(2 ^ attempt)
	end
	return false, nil
end

-- Transform runs on the fetched value; its result is written back.
function Adapter.update(self: any, key: string, transform: (any) -> any): (boolean, any?)
	local store = self:_datastore()
	if not store then
		return false, nil
	end
	for attempt = 0, self._retries do
		local ok, written = pcall(function()
			return store:UpdateAsync(key, transform)
		end)
		if ok then
			return true, written
		end
		task.wait(2 ^ attempt)
	end
	return false, nil
end

return DataStoreAdapter
