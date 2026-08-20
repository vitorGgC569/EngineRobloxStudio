--!strict
-- L6: the shop.
--
-- Authored because `tidepool` asked for it and the composer came back PLANNED.
-- Until now purchases went through `Economy.spend` directly, which works and
-- leaves the catalogue, the pricing and the stock rules in every game that has
-- a shop -- so each one reinvents the same four mistakes.
--
-- **A purchase is one atomic step.** Check-then-spend written as two calls is
-- how a player buys the last item twice from two taps, and the second one is
-- free. `purchase` debits and grants inside one path, and refuses as a whole.
--
-- **A refusal must say which refusal.** "Cannot buy" covers not-affordable,
-- out-of-stock, not-unlocked, already-owned and unknown-offer, and a UI given
-- one boolean shows the same message for all five. Every refusal here is a
-- named reason.
--
-- **Price is server truth.** A client that computes its own total will disagree
-- the moment a discount lands, and the disagreement always favours whoever is
-- reading the wrong number. Prices come from this catalogue and nowhere else.
--
-- **Stock that is not tracked is not limited.** A "limited to 3" offer with no
-- counter sells forever, and nothing reports it -- the receipt says 3 and the
-- ledger says 40.

local Analytics = require(script.Parent.Analytics)

local Shop = {}

export type Offer = {
	id: string,
	displayName: string,
	price: number,
	currency: string,
	--- What the purchase delivers. Interpreted by the caller: an item id, a tier
	--- id, a cosmetic. The shop moves currency and records the grant; what a
	--- grant means is the game's business.
	grants: string,
	--- How many one player may ever buy. Absent means unlimited.
	limitPerPlayer: number?,
	--- Progression tier required. Absent means always available.
	requiresTier: number?,
	--- Buying it once and being unable to buy it again, ever.
	unique: boolean?,
	tags: { string }?,
}

export type Ledger = {
	get: (userId: number) -> { [string]: number }?,
	set: (userId: number, purchases: { [string]: number }) -> (),
}

export type Shop = any

export type Refusal =
	"UNKNOWN_OFFER" | "CANNOT_AFFORD" | "LIMIT_REACHED" | "ALREADY_OWNED" | "TIER_LOCKED"

local function fail(message: string): never
	error("[Shop] " .. message, 0)
end

function Shop.memoryLedger(): Ledger
	local held: { [number]: { [string]: number } } = {}
	return {
		get = function(userId: number): { [string]: number }?
			return held[userId]
		end,
		set = function(userId: number, purchases: { [string]: number })
			held[userId] = purchases
		end,
	}
end

--- Check a catalogue before anything is sold.
---
--- Every problem found here would otherwise appear once per purchase attempt,
--- which is how one mispriced offer becomes a support queue.
function Shop.validate(offers: { Offer }, currencies: { string }?): { string }
	local problems: { string } = {}
	local known: { [string]: true } = {}
	for _, id in ipairs(currencies or {}) do
		known[id] = true
	end

	local seen: { [string]: true } = {}
	for index, offer in ipairs(offers) do
		local label = string.format("offers[%d]", index)
		if type(offer.id) ~= "string" or offer.id == "" then
			table.insert(problems, label .. " needs a non-empty id")
			continue
		end
		if seen[offer.id] then
			table.insert(problems, string.format("offer %q is listed twice", offer.id))
			continue
		end
		seen[offer.id] = true

		if type(offer.price) ~= "number" or offer.price < 0 then
			table.insert(problems, string.format("offer %q has no price", offer.id))
		elseif offer.price == 0 then
			-- Not an error, but almost never intended: a free offer in a shop is
			-- usually a missing number rather than a gift.
			table.insert(problems, string.format(
				"offer %q costs nothing; a free offer in a shop is usually a price "
				.. "somebody forgot to set", offer.id))
		end
		if type(offer.currency) ~= "string" or offer.currency == "" then
			table.insert(problems, string.format("offer %q names no currency", offer.id))
		elseif currencies ~= nil and not known[offer.currency] then
			table.insert(problems, string.format(
				"offer %q is priced in %q, which the economy does not define",
				offer.id, offer.currency))
		end
		if type(offer.grants) ~= "string" or offer.grants == "" then
			table.insert(problems, string.format(
				"offer %q grants nothing, so buying it takes currency and delivers "
				.. "no change the player can see", offer.id))
		end
		if offer.limitPerPlayer ~= nil then
			local limit = offer.limitPerPlayer
			if type(limit) ~= "number" or limit < 1 or limit % 1 ~= 0 then
				table.insert(problems, string.format(
					"offer %q has a limit of %s; it must be a whole number of at least 1",
					offer.id, tostring(limit)))
			end
		end
		if offer.unique == true and offer.limitPerPlayer ~= nil and offer.limitPerPlayer > 1 then
			table.insert(problems, string.format(
				"offer %q is unique and also limited to %d; the two disagree",
				offer.id, offer.limitPerPlayer))
		end
	end
	return problems
end

function Shop.define(offers: { Offer }, economy: any, ledger: Ledger): Shop
	if type(economy) ~= "table" or type(economy.spend) ~= "function" then
		fail("a shop needs an economy that can spend; purchases must move currency "
			.. "through the same ledger everything else does")
	end
	if type(ledger) ~= "table" or type(ledger.get) ~= "function" or type(ledger.set) ~= "function" then
		fail("ledger must provide get and set")
	end

	local problems = Shop.validate(offers)
	if #problems > 0 then
		fail("the catalogue does not validate: " .. table.concat(problems, "; "))
	end

	local self = {} :: any
	self.offers = {}
	self.order = {}
	for _, offer in ipairs(offers) do
		self.offers[offer.id] = offer
		table.insert(self.order, offer.id)
	end
	self.economy = economy
	self.ledger = ledger

	local function purchasesFor(player: Player): { [string]: number }
		local existing = ledger.get(player.UserId)
		if existing ~= nil then
			return existing
		end
		local fresh: { [string]: number } = {}
		ledger.set(player.UserId, fresh)
		return fresh
	end

	--- What this player may buy right now, and why not when they may not.
	---
	--- Computed server-side and handed to the UI whole. A client deciding
	--- availability for itself will be wrong the moment a tier unlocks.
	function self.available(player: Player, tier: number?): { { [string]: any } }
		local purchases = purchasesFor(player)
		local listing: { { [string]: any } } = {}
		for _, id in ipairs(self.order) do
			local offer = self.offers[id]
			local owned = purchases[id] or 0
			local refusal: Refusal? = nil
			if offer.unique == true and owned > 0 then
				refusal = "ALREADY_OWNED"
			elseif offer.limitPerPlayer ~= nil and owned >= offer.limitPerPlayer then
				refusal = "LIMIT_REACHED"
			elseif offer.requiresTier ~= nil and (tier or 0) < offer.requiresTier then
				refusal = "TIER_LOCKED"
			end
			table.insert(listing, {
				id = offer.id,
				displayName = offer.displayName,
				price = offer.price,
				currency = offer.currency,
				grants = offer.grants,
				owned = owned,
				available = refusal == nil,
				refusal = refusal,
			})
		end
		return listing
	end

	--- Buy one. Returns the offer and nil, or nil and a named refusal.
	---
	--- Debit and record happen together: an economy that spends and a ledger
	--- that does not record is a player charged for nothing, and it is
	--- indistinguishable from a purchase that never happened.
	function self.purchase(player: Player, offerId: string, tier: number?): (Offer?, Refusal?)
		local offer = self.offers[offerId]
		if offer == nil then
			return nil, "UNKNOWN_OFFER"
		end

		local purchases = purchasesFor(player)
		local owned = purchases[offerId] or 0
		if offer.unique == true and owned > 0 then
			return nil, "ALREADY_OWNED"
		end
		if offer.limitPerPlayer ~= nil and owned >= offer.limitPerPlayer then
			return nil, "LIMIT_REACHED"
		end
		if offer.requiresTier ~= nil and (tier or 0) < offer.requiresTier then
			return nil, "TIER_LOCKED"
		end

		local spent = self.economy:spend(player, offer.currency, offer.price, "shop:" .. offerId)
		if not spent then
			return nil, "CANNOT_AFFORD"
		end

		purchases[offerId] = owned + 1
		ledger.set(player.UserId, purchases)
		Analytics.custom(player, "shop_purchase", offer.price, {
			offerId = offerId, currency = offer.currency, grants = offer.grants,
		})
		return offer, nil
	end

	function self.owned(player: Player, offerId: string): number
		return purchasesFor(player)[offerId] or 0
	end

	return self
end

--- Offers nobody can ever buy, and offers that undercut the ladder.
---
--- Run against a progression ladder rather than in isolation: an offer gated
--- behind a tier the game does not have is dead content, and it is invisible in
--- the catalogue on its own.
function Shop.problems(offers: { Offer }, tierCount: number): { string }
	local problems: { string } = {}
	for _, offer in ipairs(offers) do
		if offer.requiresTier ~= nil and offer.requiresTier > tierCount then
			table.insert(problems, string.format(
				"offer %q needs tier %d and the ladder stops at %d; no player can ever "
				.. "reach it", offer.id, offer.requiresTier, tierCount))
		end
	end
	return problems
end

return Shop
