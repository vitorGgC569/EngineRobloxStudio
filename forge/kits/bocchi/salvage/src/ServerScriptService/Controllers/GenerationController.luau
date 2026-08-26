--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local MarketplaceService = game:GetService("MarketplaceService")
local constants = require(ReplicatedStorage.constants)
local Balance = require(ReplicatedStorage.Balance)
local Currency = require(ReplicatedStorage.Currency)
local ButtonController = require(ServerScriptService.Controllers.ButtonController)
local DataController = require(ServerScriptService.Controllers.DataController)
local CurrencyController = require(ServerScriptService.Controllers.CurrencyController)
local Lumin = require(ReplicatedStorage.Packages.framework)
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Packets = require(ReplicatedStorage.Packets)
local Utils = require(ReplicatedStorage.Utils)

local GenerationController = {}

local amountsPerButton = ButtonController.AmountsPerButton
local effectsPerButton = (function()
	local effects = {}
	for i, cached in pairs(ButtonController.buttons) do
		cached.info.Effect.Id = i
		local f = string.byte(string.sub(i, 1, 1))
		local order = f * 1000 + tonumber(string.sub(i, 2))
		if order == nil then
			print(i, "is being stupid", order)
			continue
		end
		cached.info.Effect.Order = order
		effects[order] = cached.info.Effect
		if cached.info.MaxAmount == nil or cached.info.MaxAmount > 1 then
			cached.info.Effect.Generation.IsVariable = true
		end
	end
	local sorted = table.sort(effects, function(a, b)
		return a.Order > b.Order
	end)
	return effects
end)()

local BLANK = Balance.new()
local ALL_1 = Balance.new()
for currency, _ in pairs(Currency) do
	ALL_1 = ALL_1:set(currency, 1)
end


local cachedTotals = {}

function GenerationController:Calculate(generationName: string)
	local cachedTotal = cachedTotals[generationName]
	if (cachedTotal == nil) then
		local n = {
			Add = BLANK,
			Mul = ALL_1,
			Pow = ALL_1
		}
		cachedTotals[generationName] = n
		cachedTotal = n
	end
	local totalAdd = BLANK
	local totalMul = ALL_1
	local totalPow = ALL_1
	
	for i, effect in pairs(effectsPerButton) do
		local generation = effect[generationName]
		if (generation == nil) then
			continue
		end
		local amount = amountsPerButton[effect.Id]
		if (amount == nil or amount < 1) then
			continue
		end		local isVariable = generation.IsVariable
		if (isVariable == true or generation.Cached ~= true) then
			generation.Cached = true
			if (generation.Add ~= nil) then
				local bal = generation.Add(amount)
				if (isVariable ~= true) then
					cachedTotal.Add = cachedTotal.Add:add(bal)
				else
					totalAdd = totalAdd:add(bal)
				end
			end
			
			if (generation.Mul ~= nil) then
				local bal = generation.Mul(amount)
				if (isVariable ~= true) then
					cachedTotal.Mul = cachedTotal.Mul:mul(bal)
				else
					totalMul = totalMul:mul(bal)
				end
			end
			
			if (generation.Pow ~= nil) then
				local bal = generation.Pow(amount)
				if (isVariable ~= true) then
					cachedTotal.Pow = cachedTotal.Pow:mul(bal)
				else
					totalPow = totalPow:mul(bal)
				end
			end
		end
	end
	
	local total = cachedTotal.Add:add(totalAdd):mul(totalMul):mul(cachedTotal.Mul):pow(totalPow):pow(cachedTotal.Pow) :: Balance.Balance
	return total
end

function GenerationController:Init()
	local t = 0
	Utils.Currencies = CurrencyController.Currencies
	local function setCurrencies(currencies: Balance.Balance)
		local amountPerCurrency = currencies.amountPerCurrency
		for currency, amount in pairs(currencies.amountPerCurrency) do
			CurrencyController.Currencies.amountPerCurrency[currency] = amount
			local prevMost = CurrencyController.MostCurrencies.amountPerCurrency[currency]
			if prevMost == nil or prevMost:lessThan(amount) then
				CurrencyController.MostCurrencies.amountPerCurrency[currency] = amount
			end
		end
		Packets.changeCurrencies.sendToAll(amountPerCurrency)
	end
	local function addCurrencies(currencies: Balance.Balance)
		setCurrencies(CurrencyController.Currencies:add(currencies))
	end
	RunService.Heartbeat:Connect(function(dt)
		t += dt
		if (t > 0.1) then
			DataController.ServerProfile.Data.Playtime += t
			Utils.Playtime = DataController.ServerProfile.Data.Playtime
			Utils.SessionTime += t
			if (Utils.SessionTime > DataController.ServerProfile.Data.LongestSession) then
				DataController.ServerProfile.Data.LongestSession = Utils.SessionTime
			end

			-- generation
			local calculated = GenerationController:Calculate("Generation")
			if (calculated ~= nil) then
				addCurrencies(calculated:mul(t))
				Packets.changeIncome.sendToAll(calculated.amountPerCurrency)
			end
			Packets.changeTime.sendToAll({playTime = Utils.Playtime, sessionTime = Utils.SessionTime})
			t = 0
		end
	end)
	Utils.SetCurrencies = setCurrencies
	Utils.AddCurrencies = addCurrencies
	Utils.CalculateGeneration = function(generationName: string)
		return GenerationController:Calculate(generationName)
	end
	Utils.RefreshButton = function(button: number)
		ButtonController:RefreshButton(button)
	end
	Utils.Buttons = ButtonController.AmountsPerButton
	for button, cached in pairs(ButtonController.buttons) do
		cached.info.IsReady = true
	end
	Utils.ClearCache = function()
		table.clear(cachedTotals)
		for i, effect in ipairs(effectsPerButton) do
			for i, generation in pairs(effect) do
				if (type(generation) == "table") then
					generation.Cached = false
				end
			end
		end
	end
end

function GenerationController:OnPlayerAdded(player: Player)
	if player.UserId ~= DataController.ServerOwner then
		return
	end
	local hasPass = MarketplaceService:UserOwnsGamePassAsync(DataController.ServerOwner, Utils.DoubleBocchiPass.Id)
	if hasPass then
		print("bro bought the x2 bocchi pass lol", DataController.ServerOwner)
	end
	Utils.DoubleBocchiPass.Enabled = hasPass
end


return GenerationController