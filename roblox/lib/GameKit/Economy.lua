--!strict
-- L6: economy.
--
-- Every currency movement in a game built on this SDK goes through one function,
-- for three reasons that are all lessons rather than preferences.
--
-- **Atomicity.** Check-then-deduct written twice in two services is how a player
-- spends the same thousand twice. `spend` reads and writes the balance in one
-- place with no yield between them.
--
-- **Instrumentation.** Sinks and sources are the only way to know whether an
-- economy inflates, and the only moment anyone will ever remember to log them is
-- the moment the money moves. Emitting from here means a feature is instrumented
-- whether or not its author thought about analytics.
--
-- **Replayability.** The ledger records every movement with its reason. A
-- headless simulation can replay thousands of player-hours against the same
-- catalogue and answer "is the second upgrade priced wrong" -- a question the
-- live game can only answer after shipping.
--
-- Balances live behind an injected store, so persistence is `Save`'s problem and
-- an economy can be simulated with a plain table.

local Analytics = require(script.Parent.Analytics)

local Economy = {}

export type Entry = {
	--- Monotonic within a session; the ledger's ordering, not a timestamp.
	sequence: number,
	userId: number,
	currency: string,
	flow: string,
	amount: number,
	balance: number,
	reason: string,
	sku: string?,
	at: number,
}

export type Currency = {
	id: string,
	displayName: string,
	--- Whole numbers only. Cash is integral in almost every tycoon, and a
	--- fractional balance is how a display ends up reading "$12.000000001".
	integral: boolean?,
	startingBalance: number?,
	maximum: number?,
}

--- `get` returns nil for a balance that has never been written.
---
--- "Never held any cash" and "spent down to nothing" are different facts, and
--- conflating them is an exploit rather than a rounding error: a store that
--- returns 0 for both makes an unseeded balance indistinguishable from an empty
--- one, so every time a player goes broke they are handed the starting balance
--- again. Measured here as twenty successful purchases from a wallet that could
--- afford three.
export type Store = {
	get: (userId: number, currency: string) -> number?,
	set: (userId: number, currency: string, value: number) -> (),
}

export type Economy = {
	currencies: { [string]: Currency },
	ledger: { Entry },
	balance: (self: Economy, player: Player, currency: string) -> number,
	grant: (self: Economy, player: Player, currency: string, amount: number, reason: string, sku: string?) -> number,
	spend: (self: Economy, player: Player, currency: string, amount: number, reason: string, sku: string?) -> (boolean, number),
	canAfford: (self: Economy, player: Player, currency: string, amount: number) -> boolean,
	flows: (self: Economy) -> { [string]: { [string]: number } },
}

local function fail(message: string): never
	error("[GameKit.Economy] " .. message, 3)
end

--- A store backed by a plain table. Real games inject `Save`'s profile store;
--- simulations and tests use this.
function Economy.memoryStore(): Store
	local balances: { [number]: { [string]: number } } = {}
	return {
		get = function(userId: number, currency: string): number?
			local wallet = balances[userId]
			return if wallet then wallet[currency] else nil
		end,
		set = function(userId: number, currency: string, value: number)
			local wallet = balances[userId]
			if wallet == nil then
				wallet = {}
				balances[userId] = wallet
			end
			wallet[currency] = value
		end,
	}
end

function Economy.define(currencies: { Currency }, store: Store): Economy
	if type(currencies) ~= "table" or #currencies == 0 then
		fail("at least one currency must be declared")
	end
	if type(store) ~= "table" or type(store.get) ~= "function" or type(store.set) ~= "function" then
		fail("store must supply get and set")
	end

	local byId: { [string]: Currency } = {}
	for index, currency in ipairs(currencies) do
		if type(currency.id) ~= "string" or currency.id == "" then
			fail(string.format("currencies[%d] needs an id", index))
		end
		if byId[currency.id] ~= nil then
			fail(string.format("currency %q is declared twice", currency.id))
		end
		if currency.maximum ~= nil and currency.startingBalance ~= nil and currency.startingBalance > currency.maximum then
			fail(string.format("currency %q starts above its own maximum", currency.id))
		end
		byId[currency.id] = currency
	end

	local economy = {} :: any
	economy.currencies = byId
	economy.ledger = {} :: { Entry }

	local sequence = 0

	local function requireCurrency(currencyId: string): Currency
		local currency = byId[currencyId]
		if currency == nil then
			local available = {}
			for id in pairs(byId) do
				table.insert(available, id)
			end
			table.sort(available)
			fail(string.format("unknown currency %q; declared: %s", tostring(currencyId), table.concat(available, ", ")))
		end
		return currency
	end

	local function normalise(currency: Currency, value: number): number
		local result = value
		if currency.integral ~= false then
			result = math.floor(result)
		end
		if currency.maximum ~= nil then
			result = math.min(result, currency.maximum)
		end
		return math.max(result, 0)
	end

	local function record(player: Player, currency: string, flow: string, amount: number, balance: number, reason: string, sku: string?)
		sequence += 1
		table.insert(economy.ledger, {
			sequence = sequence,
			userId = player.UserId,
			currency = currency,
			flow = flow,
			amount = amount,
			balance = balance,
			reason = reason,
			sku = sku,
			at = os.clock(),
		})
	end

	function economy:balance(player: Player, currencyId: string): number
		local currency = requireCurrency(currencyId)
		local stored = store.get(player.UserId, currencyId)
		if stored == nil then
			-- Seeded exactly once, on the first read of a wallet that has never
			-- been written. Keying this off `== 0` instead is what turns a
			-- starting balance into an infinite one, because a player who spends
			-- everything then looks identical to a player who just arrived.
			local seeded = normalise(currency, currency.startingBalance or 0)
			store.set(player.UserId, currencyId, seeded)
			return seeded
		end
		return stored
	end

	function economy:canAfford(player: Player, currencyId: string, amount: number): boolean
		if type(amount) ~= "number" or amount < 0 then
			fail("amount must be a non-negative number")
		end
		return self:balance(player, currencyId) >= amount
	end

	function economy:grant(player: Player, currencyId: string, amount: number, reason: string, sku: string?): number
		local currency = requireCurrency(currencyId)
		if type(amount) ~= "number" or amount <= 0 then
			fail("grant amount must be positive")
		end
		if type(reason) ~= "string" or reason == "" then
			fail("grant needs a reason; an unattributed source cannot be analysed")
		end
		local current = self:balance(player, currencyId)
		local updated = normalise(currency, current + amount)
		store.set(player.UserId, currencyId, updated)

		-- The amount actually credited, which differs from the request whenever a
		-- maximum clipped it. Reporting the request would overstate the source.
		local credited = updated - current
		if credited > 0 then
			record(player, currencyId, "source", credited, updated, reason, sku)
			Analytics.economy(player, "source", currencyId, credited, updated, reason, sku)
		end
		return updated
	end

	function economy:spend(player: Player, currencyId: string, amount: number, reason: string, sku: string?): (boolean, number)
		local currency = requireCurrency(currencyId)
		if type(amount) ~= "number" or amount <= 0 then
			fail("spend amount must be positive")
		end
		if type(reason) ~= "string" or reason == "" then
			fail("spend needs a reason; an unattributed sink cannot be analysed")
		end

		-- Read, compare and write with nothing between them. Any yield here --
		-- an analytics call, a remote, a wait -- reopens the double-spend this
		-- function exists to close.
		local current = self:balance(player, currencyId)
		if current < amount then
			return false, current
		end
		local updated = normalise(currency, current - amount)
		store.set(player.UserId, currencyId, updated)

		record(player, currencyId, "sink", amount, updated, reason, sku)
		Analytics.economy(player, "sink", currencyId, amount, updated, reason, sku)
		return true, updated
	end

	--- Totals per currency per reason, which is the shape an economy review
	--- actually wants: which sources print money and which sinks remove it.
	function economy:flows(): { [string]: { [string]: number } }
		local totals: { [string]: { [string]: number } } = {}
		for _, entry in ipairs(economy.ledger) do
			local key = entry.currency .. ":" .. entry.flow
			local bucket = totals[key]
			if bucket == nil then
				bucket = {}
				totals[key] = bucket
			end
			bucket[entry.reason] = (bucket[entry.reason] or 0) + entry.amount
		end
		return totals
	end

	return economy :: Economy
end

--- Net currency created minus destroyed, per currency.
---
--- A positive number over a long session means the economy inflates: whatever
--- the shop costs today will be trivial tomorrow. This is the cheapest possible
--- read on whether a tycoon's pacing holds.
function Economy.netFlow(economy: Economy): { [string]: number }
	local net: { [string]: number } = {}
	for _, entry in ipairs(economy.ledger) do
		local delta = if entry.flow == "source" then entry.amount else -entry.amount
		net[entry.currency] = (net[entry.currency] or 0) + delta
	end
	return net
end

return Economy
