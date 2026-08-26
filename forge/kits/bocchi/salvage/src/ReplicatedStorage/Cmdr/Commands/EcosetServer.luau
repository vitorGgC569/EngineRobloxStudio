return function (context, currency: string, mantissa: number, exponent: number?)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")
	local CurrencyController = require(ServerScriptService.Controllers.CurrencyController)
	local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
	
	CurrencyController.Currencies:set(currency, exponent == nil and mantissa or AlyaNum.fromOnoe({mantissa = mantissa, exponent = exponent}))
end