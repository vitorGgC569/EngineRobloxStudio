--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Balance = require(ReplicatedStorage.Balance)
local DataController = require(ServerScriptService.Controllers.DataController)
local Lumin = require(ReplicatedStorage.Packages.framework)
local Packets = require(ReplicatedStorage.Packets)

local CurrencyController = {}
local currencies: Balance;

function CurrencyController:Init()
	currencies = Balance.new(DataController.ServerProfile.Data.Currencies, false) -- mutable and linked to datastores :)
	CurrencyController.Currencies = currencies -- expose currencies to public
	CurrencyController.MostCurrencies = Balance.new(DataController.ServerProfile.Data.MostCurrencies, false)
end

function CurrencyController:Start()
	Packets.changeCurrencies.sendToAll(currencies.amountPerCurrency)
	task.spawn(function()
		while wait() do
			Packets.changeCurrencies.sendToAll(currencies.amountPerCurrency)
		end
	end)
end

function CurrencyController:OnPlayerAdded(player: Player)
	pcall(function()
		Packets.changeCurrencies.sendTo(currencies.amountPerCurrency, player)
	end)
end


export type CurrencyController = typeof(CurrencyController)

return CurrencyController