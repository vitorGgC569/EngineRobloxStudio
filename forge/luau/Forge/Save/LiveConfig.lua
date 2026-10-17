--!strict
--[[
	LiveConfig — runtime tuning without republishing.

	Game feel numbers (round times, prices, drop weights) change after
	launch. Values live in one config record; the cache refreshes on a
	periodic poll and every read falls back to the compiled default when
	the store is unavailable — tuning can degrade, never break the game.
]]

local LiveConfig = {}

export type Store = {
	get: (self: Store, key: string) -> (boolean, any?),
}

type Self = {
	storeKey: string,
	defaults: { [string]: any },
	overrides: { [string]: any }?,
	lastFetch: number,
	refreshSeconds: number,
	store: Store?,
	clock: () -> number,
	fetchCount: number,
}

LiveConfig.__index = LiveConfig

-- The cache used to keep the caller's table. Changing a nested price after
-- `new`, or after the store handed the record over, rewrote the value every
-- later read returned.
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

function LiveConfig.new(config: {
	store: Store?,
	storeKey: string?,
	defaults: { [string]: any },
	refreshSeconds: number?,
	clock: (() -> number)?,
}): Self
	return setmetatable({
		store = config.store,
		storeKey = config.storeKey or "live_config",
		defaults = deepCopy(config.defaults, {}),
		overrides = nil,
		lastFetch = -math.huge,
		refreshSeconds = config.refreshSeconds or 60,
		clock = config.clock or os.clock,
		fetchCount = 0,
	}, LiveConfig)
end

function LiveConfig.refresh(self: Self): ()
	local store = self.store
	if not store then
		return
	end
	local now = self.clock()
	if now - self.lastFetch < self.refreshSeconds then
		return
	end
	self.lastFetch = now
	self.fetchCount += 1
	local ok, raw = store:get(self.storeKey)
	if ok and type(raw) == "table" then
		self.overrides = deepCopy(raw, {})
	end
end

function LiveConfig.get(self: Self, key: string): any
	local value: any = if self.overrides and self.overrides[key] ~= nil then self.overrides[key] else self.defaults[key]
	return deepCopy(value, {})
end

-- Reads always return a number; missing keys are a boot error at call site.
function LiveConfig.getNumber(self: Self, key: string): number?
	local value = self:get(key)
	return if type(value) == "number" then value else nil
end

return LiveConfig
