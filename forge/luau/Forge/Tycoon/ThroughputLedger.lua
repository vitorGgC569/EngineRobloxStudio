--!strict
--[[
	ThroughputLedger — idempotent count of live dropped items.

	Add/remove pairs must be safe to replay: removing an unknown id is a
	no-op, adding twice without removal counts once. The ledger answers
	the only question the droppers ask: are we over the cap yet?
]]

local ThroughputLedger = {}

type Self = {
	items: { [string]: boolean },
}

ThroughputLedger.__index = ThroughputLedger

function ThroughputLedger.new(): Self
	return setmetatable({ items = {} }, ThroughputLedger)
end

function ThroughputLedger.add(self: Self, itemId: string): ()
	self.items[itemId] = true
end

function ThroughputLedger.remove(self: Self, itemId: string): boolean
	if not self.items[itemId] then
		return false
	end
	self.items[itemId] = nil
	return true
end

function ThroughputLedger.count(self: Self): number
	local n = 0
	for _ in self.items do
		n += 1
	end
	return n
end

function ThroughputLedger.overLimit(self: Self, limit: number): boolean
	return self:count() >= limit
end

return ThroughputLedger
