--!strict
--[[
	ReceiptLedger — append-only, idempotent grant history.

	Purchases and redemptions must survive retries. A receipt id granted once
	is recorded forever; granting the same id again is a no-op that returns the
	state unchanged. That makes the whole ledger safe to replay: a retried
	write cannot double-grant, and a save built from an incomplete in-memory
	copy can never drop or overwrite an entry the store already holds.

		local ledger = ReceiptLedger.new()
		local state, isNew = ledger:grant(profile.receipts, receiptId, payload)
		if isNew then profile.receipts = state end

	State is a plain `{ [receiptId]: payload }` table — DataStore-serializable.
	Nil payloads are recorded as `true`, because stores drop nil values and the
	entry's presence is the point.
]]

export type LedgerState = { [string]: any }

local Ledger = {}
Ledger.__index = Ledger

-- A shallow clone shares the payload table with the caller. Editing the
-- sword after the grant then rewrites the receipt the store already holds.
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

function Ledger.new(initial: LedgerState?)
	local self: { state: LedgerState } = { state = {} }
	if typeof(initial) == "table" then
		for receiptId, payload in initial :: { [string]: any } do
			if type(receiptId) == "string" and payload ~= nil then
				self.state[receiptId] = deepCopy(payload, {})
			end
		end
	end
	return setmetatable(self :: any, Ledger)
end

-- Grant one receipt into `state` (nil means "the ledger's own state").
--
-- Union-reconcile semantics: an id already present keeps its ORIGINAL payload
-- untouched — the existing record may be richer than what this call carries,
-- so overwriting would trade a complete entry for an incomplete copy.
-- Absence produces a NEW cloned state (callers decide when to adopt it).
function Ledger:grant(state: LedgerState?, receiptId: string, payload: any): (LedgerState, boolean)
	local current: LedgerState = if state ~= nil then state :: LedgerState else (self :: any).state

	if current[receiptId] ~= nil then
		return current, false
	end

	local updated: LedgerState = {}
	for key, value in current do
		updated[key] = deepCopy(value, {})
	end
	updated[receiptId] = if payload ~= nil then deepCopy(payload, {}) else true
	if state == nil then
		(self :: any).state = updated
	end
	return updated, true
end

function Ledger:has(state: LedgerState?, receiptId: string): boolean
	local current: LedgerState = if state ~= nil then state :: LedgerState else (self :: any).state
	return current[receiptId] ~= nil
end

return Ledger
