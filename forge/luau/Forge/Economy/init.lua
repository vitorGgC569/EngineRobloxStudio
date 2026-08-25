--!strict
--[[
	Economy — numbers, formulas, wallets and income for incremental games.

	Four pure modules with no engine dependencies:

		Economy.BigNumber      scientific-notation big numbers with suffix format
		Economy.Formula        immutable arithmetic chains, renderable
		Economy.Balance        multi-currency wallet with atomic debits
		Economy.IncomeEngine   cached aggregation of passive income

		local Economy = require(ReplicatedStorage.Economy)
		local wallet = Economy.Balance.new({ currencies = { coins = {} } })
]]

local Economy = {
	BigNumber = require(script.Parent.BigNumber),
	Formula = require(script.Parent.Formula),
	Balance = require(script.Parent.Balance),
	IncomeEngine = require(script.Parent.IncomeEngine),
}

return Economy
