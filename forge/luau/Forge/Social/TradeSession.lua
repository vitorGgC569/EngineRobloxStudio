--!strict
--[[
	TradeSession — two-party trade as an explicit state machine.

	Trades go wrong when "who agreed to what" is fuzzy. This session
	tracks offers per side, a lock step (both sides freeze their offer),
	then confirmation; double confirmation produces the exact transfer
	list. Any cancellation is terminal. A failed-save flag (injected)
	blocks locking new value.
]]

local TradeSession = {}

export type Offer = {
	items: { { id: string, count: number } },
	currency: number,
}

type SideState = {
	offer: Offer?,
	locked: boolean,
	confirmed: boolean,
}

export type Status = "open" | "locked" | "confirmed" | "cancelled"

type Self = {
	a: string,
	b: string,
	sides: { [string]: SideState },
	state: Status,
	cancelReason: string?,
	dataSaveFailed: boolean,
	clock: () -> number,
	cooldownSeconds: number,
	lastOfferAt: { [string]: number },
}

--[[
	A field must never share a name with a method on the same table.

	`TradeSession.__index = TradeSession` means an instance looks at itself first, so an
	instance field called `status` shadows `TradeSession.status` and the method
	becomes permanently uncallable: `instance:status()` finds the field and
	tries to call a table.

	Nothing catches it. It compiles, the type checker is content, and the unit
	specs call the module functions directly rather than through an instance --
	which is exactly the shape that never reaches the shadow. It surfaced the
	first time a game called `cycle:hand()` and got "attempt to call a table
	value", and a scan then found the same collision in four modules.

	The field is renamed rather than the method, because the method is the
	published surface and the field is private.
]]
TradeSession.__index = TradeSession

local function validOffer(offer: Offer?): boolean
	if not offer then
		return false
	end
	-- NaN < 0 is false, so a bare less-than accepts currency 0/0 and stores it.
	if offer.currency ~= nil then
		local currency = offer.currency
		if type(currency) ~= "number" or currency ~= currency or currency < 0 then
			return false
		end
	end
	for _, stack in offer.items do
		local count = stack.count
		-- NaN <= 0 is false, so a bare comparison accepts a count of 0/0.
		if type(count) ~= "number" or count ~= count or count <= 0 then
			return false
		end
	end
	return true
end

-- The offer used to keep the caller's stack tables. Raising the count after
-- the offer, including after both sides had locked, changed what result()
-- would transfer.
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

function TradeSession.new(config: { a: string, b: string, cooldownSeconds: number?, clock: (() -> number)? }): Self
	assert(config.a ~= config.b, "a player cannot trade with themselves")
	return setmetatable({
		a = config.a,
		b = config.b,
		sides = {
			[config.a] = { offer = nil, locked = false, confirmed = false },
			[config.b] = { offer = nil, locked = false, confirmed = false },
		},
		state = "open" :: Status,
		cancelReason = nil,
		dataSaveFailed = false,
		clock = config.clock or os.clock,
		cooldownSeconds = config.cooldownSeconds or 3,
		lastOfferAt = {},
	}, TradeSession)
end

function TradeSession.setDataSaveFailed(self: Self, failed: boolean): ()
	self.dataSaveFailed = failed
end

function TradeSession.offer(self: Self, side: string, offer: Offer): (boolean, string?)
	local state = self.sides[side]
	if not state then
		return false, "not_a_party"
	end
	if self.state == "cancelled" or self.state == "confirmed" then
		return false, "session_closed"
	end
	if state.locked then
		return false, "side_locked"
	end
	local now = self.clock()
	local last = self.lastOfferAt[side]
	if last and now - last < self.cooldownSeconds then
		return false, "offer_cooldown"
	end
	if self.dataSaveFailed then
		return false, "save_failed"
	end
	if not validOffer(offer) then
		return false, "invalid_offer"
	end
	state.offer = deepCopy(offer, {})
	self.lastOfferAt[side] = now
	return true, nil
end

function TradeSession.lock(self: Self, side: string): (boolean, string?)
	local state = self.sides[side]
	if not state then
		return false, "not_a_party"
	end
	if not state.offer then
		return false, "no_offer"
	end
	if self.state == "cancelled" or self.state == "confirmed" then
		return false, "session_closed"
	end
	if self.dataSaveFailed then
		return false, "save_failed"
	end
	state.locked = true
	if self.sides[self.a].locked and self.sides[self.b].locked then
		self.state = "locked"
	end
	return true, nil
end

function TradeSession.confirm(self: Self, side: string): (boolean, string?)
	local state = self.sides[side]
	if not state then
		return false, "not_a_party"
	end
	if self.state == "cancelled" or self.state == "confirmed" then
		return false, "session_closed"
	end
	if not state.locked then
		return false, "must_lock_first"
	end
	state.confirmed = true
	if self.sides[self.a].confirmed and self.sides[self.b].confirmed then
		self.state = "confirmed"
	end
	return true, nil
end

function TradeSession.cancel(self: Self, bySide: string?, reason: string?): boolean
	if self.state == "confirmed" then
		return false
	end
	self.state = "cancelled"
	self.cancelReason = reason or (bySide and ("cancelled_by_" .. bySide) or "cancelled")
	return true
end

-- The exact transfer list once both sides confirmed; nil otherwise.
function TradeSession.result(self: Self): { from: string, to: string, give: Offer, take: Offer }?
	if self.state ~= "confirmed" then
		return nil
	end
	local sa, sb = self.sides[self.a], self.sides[self.b]
	return {
		from = self.a,
		to = self.b,
		give = deepCopy(sa.offer, {}),
		take = deepCopy(sb.offer, {}),
	}
end

function TradeSession.status(self: Self): (Status, string?)
	return self.state, self.cancelReason
end

return TradeSession
