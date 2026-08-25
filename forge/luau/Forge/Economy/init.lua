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
	BigNumber = require(script.BigNumber),
	Formula = require(script.Formula),
	Balance = require(script.Balance),
	IncomeEngine = require(script.IncomeEngine),
}


--[[
	Siblings, resolved on the first thing that asks for one.

	This family holds modules beside this file, and until now the only way to
	reach them was to require the instance directly — so `Forge.Economy.Audit`
	was nil while `require(ReplicatedStorage.Forge.Economy.Audit)` worked. Two
	conventions in one engine, and the inconsistency is the defect: the first
	game written against `Forge.Core.Boot` died on `attempt to index nil`.

	Lazy rather than eager, matching `Forge` itself. Touching one family must
	not drag in every module it contains — several of them build tables and
	open connections at load, and paying for all of that to read one constant
	is how a require graph becomes a frame budget.
]]
return setmetatable(Economy, {
	__index = function(self, key: string): any
		local child = script:FindFirstChild(key)
		if not child or not child:IsA("ModuleScript") then
			return nil
		end
		local module = require(child) :: any
		rawset(self, key, module)
		return module
	end,
})
