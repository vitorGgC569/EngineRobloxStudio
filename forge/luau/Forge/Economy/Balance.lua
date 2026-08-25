--!strict
--[[
	Balance — a multi-currency wallet with atomic spending.

	Currencies are declared up front with their metadata; anything outside the
	registry cannot be minted by accident, and a debit that cannot be covered
	everywhere is applied nowhere:

		local wallet = Balance.new({
			currencies = {
				gold = { start = 0 },
				gems = { start = 0, big = true },
			},
		})

		wallet:credit({ gold = 120 })
		if wallet:canAfford({ gold = 50, gems = 1 }) then
			wallet:debit({ gold = 50, gems = 1 })
		end

	Currencies marked big = true store BigNumber values internally and snapshot
	to exact scientific-notation strings.
]]

local BigNumber = require(script.Parent.BigNumber)

export type CurrencyMeta = {
	start: number?,
	big: boolean?,
}

export type CurrencyRegistry = { [string]: CurrencyMeta }

export type Costs = { [string]: number }

export type Snapshot = { [string]: any }

-- ================================ helpers ====================================

local function initialValue(meta: CurrencyMeta): any
	if meta.big then
		return BigNumber.new(meta.start or 0)
	end
	return meta.start or 0
end

local function addTo(meta: CurrencyMeta, amount: any, delta: number): any
	if meta.big then
		return BigNumber.add(amount, BigNumber.new(delta))
	end
	return amount + delta
end

local function subtractFrom(meta: CurrencyMeta, amount: any, delta: number): any
	if meta.big then
		return BigNumber.sub(amount, BigNumber.new(delta))
	end
	return amount - delta
end

local function leftover(meta: CurrencyMeta, amount: any, cost: number): number
	if meta.big then
		return BigNumber.toNumber(BigNumber.sub(amount, BigNumber.new(cost)))
	end
	return amount - cost
end

local function evaluate(self: Balance, costs: Costs): (boolean, Costs)
	local remainder: Costs = {}
	local affordable = true
	for name, cost in costs do
		local meta = self.registry[name]
		if meta == nil then
			if cost > 0 then
				affordable = false
				remainder[name] = cost
			end
		else
			local remaining = leftover(meta, self.amounts[name], cost)
			remainder[name] = remaining
			if remaining < 0 then
				affordable = false
			end
		end
	end
	return affordable, remainder
end

-- ============================== construction ================================

local Balance = {}
Balance.__index = Balance

export type Balance = typeof(setmetatable({} :: {
	registry: CurrencyRegistry,
	amounts: { [string]: any },
}, Balance))

function Balance.new(config: { currencies: CurrencyRegistry }?): Balance
	local registry: CurrencyRegistry = if config ~= nil then config.currencies or {} else {}
	local self = setmetatable({
		registry = {},
		amounts = {},
	}, Balance)
	for name, meta in registry do
		self.registry[name] = meta
		self.amounts[name] = initialValue(meta)
	end
	return self
end

-- ============================ queries and edits ==============================

function Balance.get(self: Balance, name: string): any
	local meta = self.registry[name]
	if meta == nil then
		return 0
	end
	return self.amounts[name]
end

function Balance.credit(self: Balance, gains: Costs): Balance
	for name, gain in gains do
		local meta = self.registry[name]
		if meta ~= nil then
			self.amounts[name] = addTo(meta, self.amounts[name], gain)
		end
	end
	return self
end

-- ================================ spending ===================================

function Balance.canAfford(self: Balance, costs: Costs): boolean
	local affordable = evaluate(self, costs)
	return affordable
end

function Balance.debit(self: Balance, costs: Costs): (boolean, Costs)
	local affordable, remainder = evaluate(self, costs)
	if not affordable then
		return false, remainder
	end
	for name, cost in costs do
		local meta = self.registry[name]
		if meta ~= nil then
			self.amounts[name] = subtractFrom(meta, self.amounts[name], cost)
		end
	end
	return true, remainder
end

-- =============================== persistence =================================

function Balance.snapshot(self: Balance): Snapshot
	local snap: Snapshot = {}
	for name, meta in self.registry do
		local amount = self.amounts[name]
		if meta.big then
			local big = amount :: BigNumber
			snap[name] = string.format("%.17ge%+d", big.mantissa, big.exponent)
		else
			snap[name] = amount :: number
		end
	end
	return snap
end

function Balance.restore(self: Balance, snap: Snapshot)
	for name, meta in self.registry do
		local raw = snap[name]
		if meta.big then
			if type(raw) == "string" then
				self.amounts[name] = BigNumber.parse(raw :: string)
			elseif type(raw) == "table" then
				local big = raw :: BigNumber
				self.amounts[name] = BigNumber.new({ mantissa = big.mantissa, exponent = big.exponent })
			else
				self.amounts[name] = initialValue(meta)
			end
		elseif type(raw) == "number" then
			self.amounts[name] = raw :: number
		else
			self.amounts[name] = initialValue(meta)
		end
	end
end

return Balance
