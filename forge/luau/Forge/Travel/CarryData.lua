--!strict
--[[
	CarryData: player payload that crosses a place teleport.

	The vesteria contract: before TeleportService moves a player, the
	origin server stores their payload under a one-shot token; the
	destination server consumes it on arrival. Tokens are single-use,
	expire, and only open for their owner, so a leaked token is dead
	weight, not a dupe. Store is injected (Save.DataStoreAdapter fits).
]]

local CarryData = {}

export type Store = {
	get: (self: any, key: string) -> (boolean, any?),
	update: (self: any, key: string, transform: (any) -> any) -> (boolean, any?),
}

type Record = {
	ownerUserId: number,
	payload: { [string]: any },
	expiresAt: number,
}

type Self = {
	store: Store,
	ttlSeconds: number,
	keyPrefix: string,
	now: () -> number,
}

CarryData.__index = CarryData

function CarryData.new(config: { store: Store, ttlSeconds: number?, now: (() -> number)? }): Self
	return setmetatable({
		store = config.store,
		ttlSeconds = config.ttlSeconds or 300,
		keyPrefix = "carry/",
		now = config.now or os.time,
	}, CarryData)
end

-- Origin side: store payload, return the token to hand through teleport options.
function CarryData.prepare(self: Self, userId: number, payload: { [string]: any }): (string?, string?)
	if next(payload) == nil then
		return nil, "empty_payload"
	end
	local token = tostring(userId) .. "-" .. tostring(self.now()) .. "-" .. tostring(math.random(1e6))
	local record: Record = {
		ownerUserId = userId,
		payload = payload,
		expiresAt = self.now() + self.ttlSeconds,
	}
	local ok = self.store:update(self.keyPrefix .. token, function(_old)
		return record
	end)
	if not ok then
		return nil, "store_unavailable"
	end
	return token, nil
end

-- Destination side: one-shot consume. Wrong owner/expired tokens refuse.
function CarryData.consume(self: Self, token: string, userId: number): ({ [string]: any }?, string?)
	local key = self.keyPrefix .. token
	local found: Record? = nil
	local ok = self.store:update(key, function(old)
		found = nil
		if type(old) ~= "table" then
			return nil -- gone: one-shot semantics
		end
		local record = old :: any
		if self.now() > (record.expiresAt or 0) then
			return nil -- expired: drop it
		end
		if record.ownerUserId ~= userId then
			return old -- wrong owner: leave intact for its owner
		end
		found = record :: Record
		return nil -- consume
	end)
	if not ok then
		return nil, "store_unavailable"
	end
	if not found then
		return nil, "token_invalid_or_expired"
	end
	return (found :: Record).payload, nil
end

return CarryData
