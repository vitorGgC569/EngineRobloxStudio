--!native
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Currency = require(ReplicatedStorage.Currency)
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)

local ZERO = AlyaNum.new(0) -- utility

--- @class Balance
--- A class used to perform calculations on multiple currencies at once.
--- Note that all Balance objects are immutable when using its builtin methods. Balance.amountPerCurrency is mutable, however.
local Balance = {}
Balance.__index = Balance

--- Create a new Balance object.
--- @param amountPerCurrency -- Default amount of currencies in the balance
--- @param clone -- Optional parameter, indicating whether or not to clone amountPerCurrency. Default is true.
function Balance.new(amountPerCurrency: {[Currency.Currency]: AlyaNum.Number}?, clone: boolean?): Balance
	local newAmountPerCurrency: {[Currency.Currency]: AlyaNum.AlyaNum};
	if (amountPerCurrency ~= nil) then
		if (clone == false) then
			newAmountPerCurrency = amountPerCurrency
		else
			newAmountPerCurrency = {}
		end
		for currency, amount in pairs(newAmountPerCurrency) do
			newAmountPerCurrency[currency] = AlyaNum.new(amount)
		end
	else
		newAmountPerCurrency = {}
	end
	
	return setmetatable({
		amountPerCurrency = newAmountPerCurrency
	}, Balance)
end

--- Get the amount of the currency specified in the Balance object.
--- @param currency -- Currency to get amount of
function Balance.get(self: Balance, currency: Currency.Currency): AlyaNum.AlyaNum
	return self.amountPerCurrency[currency] or ZERO
end

--- Sets the amount of the currency specified in the Balance object.
--- @param currency -- Currency to get amount of
function Balance.set(self: Balance, currency: Currency.Currency, amount: (AlyaNum.AlyaNum | number)?): Balance
	if (amount == nil) then
		self.amountPerCurrency[currency] = nil
		return self
	end
	self.amountPerCurrency[currency] = AlyaNum.new(amount)
	return self
end
	
function Balance.add(self: Balance, value: Balance)
	local newBalance = Balance.new()
	for currency, amount in pairs(self.amountPerCurrency) do
		newBalance.amountPerCurrency[currency] = AlyaNum.new(amount)
	end
	for currency, amount in pairs(value.amountPerCurrency) do
		local currentAmount = newBalance.amountPerCurrency[currency]
		newBalance.amountPerCurrency[currency] = currentAmount == nil and amount or AlyaNum.add(currentAmount, amount)
	end
	return newBalance
end

function Balance.sub(self: Balance, value: Balance)
	local newBalance = Balance.new()
	for currency, amount in pairs(self.amountPerCurrency) do
		newBalance.amountPerCurrency[currency] = AlyaNum.new(amount)
	end
	for currency, amount in pairs(value.amountPerCurrency) do
		local currentAmount = newBalance.amountPerCurrency[currency]
		newBalance.amountPerCurrency[currency] = currentAmount == nil and amount:unary() or AlyaNum.sub(currentAmount, amount)
	end
	return newBalance
end

function Balance.mul(self: Balance, value: Balance | number)
	local constant = typeof(value) == "number" and AlyaNum.new(value) or nil
	local newBalance = Balance.new()
	for currency, amount in pairs(self.amountPerCurrency) do
		local value = constant or (value :: Balance).amountPerCurrency[currency]
		newBalance.amountPerCurrency[currency] = value == nil and amount or amount:mul(value)
	end
	return newBalance
end

function Balance.pow(self: Balance, value: Balance | number)
	local constant = typeof(value) == "number" and AlyaNum.new(value) or nil
	local newBalance = Balance.new()
	for currency, amount in pairs(self.amountPerCurrency) do
		local value = constant or (value :: Balance).amountPerCurrency[currency]
		newBalance.amountPerCurrency[currency] = value == nil and amount or amount:pow(value)
	end
	return newBalance
end

function Balance.canAfford(self: Balance, value: Balance)
	local remainingPerCurrency = {}
	local result = true
	for currency, amount in pairs(self.amountPerCurrency) do
		local other = value.amountPerCurrency[currency]
		if other ~= nil then
			local remaining = amount:sub(other)
			remainingPerCurrency[currency] = remaining
			if remaining.sign == -1 then
				result = false
			end
		end
	end
	
	return result, remainingPerCurrency
end

function Balance.getFormatted(currency: Currency.Currency, cost: AlyaNum.AlyaNum, excludeName: boolean?)
	local c = tostring(cost)
	return if excludeName == true then c else `{c} {currency}`
end

function Balance.toString(self: Balance, currency: Currency.Currency?, cost: AlyaNum.AlyaNum?)
	if currency ~= nil then
		return Balance.getFormatted(currency, cost or self:getCost(currency))
	end
	local label = ""
	
	local size = 0
	for _ in self.amountPerCurrency do
		size += 1
	end
	
	local i = 1
	for currency, details in pairs(Currency) do
		local cc = self.amountPerCurrency[currency]
		if cc ~= nil then
			label ..= self:toString(currency, cc)
			if i < size then
				label ..= ", "
			end
			i += 1
		end
	end
	return label
end

Balance.__add = Balance.add
Balance.__sub = Balance.sub
Balance.__mul = Balance.mul

export type Balance = typeof(setmetatable({} :: { amountPerCurrency: {[Currency.Currency]: AlyaNum.AlyaNum} }, Balance))

return Balance
