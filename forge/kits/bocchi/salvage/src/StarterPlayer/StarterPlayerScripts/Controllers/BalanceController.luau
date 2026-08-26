local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local constants = require(ReplicatedStorage.constants)
local Currency = require(ReplicatedStorage.Currency)
local CurrencyPages = require(ReplicatedStorage.Currency.Pages)
local Lumin = require(ReplicatedStorage.Packages.framework)
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local HotkeysController = require(script.Parent.HotkeysController)
local Packets = require(ReplicatedStorage.Packets)
local TooltipController = require(script.Parent.TooltipController)

local BalanceController = {}

BalanceController.Page = 1

local BALANCE_WINDOW = constants.INTERFACE.BalanceWindow
local BALANCE_OPTION = constants.ASSETS.BalanceWindow.BalanceOption

local namePerPage: {[number]: string} = {}
for i, v in pairs(CurrencyPages) do
	namePerPage[v] = i
end

function BalanceController:GetCurrencyOption(currency: Currency.Currency)
	local currencyOption = BALANCE_WINDOW.Balances:FindFirstChild(currency) :: typeof (BALANCE_OPTION)
	if currencyOption ~= nil then
		return currencyOption
	end
	currencyOption = BALANCE_OPTION:Clone()
	local details = Currency[currency]
	local backgroundColor = details.Color or Color3.new(1, 1, 1)
	currencyOption.BackgroundColor3 = backgroundColor
	currencyOption.Amount.BalanceLabel.UIStroke.Color = backgroundColor
	currencyOption.Amount.IncomeLabel.UIStroke.Color = backgroundColor
	currencyOption.Name = currency

	currencyOption.ImageLabel.Image = "rbxassetid://" .. tostring(details.Image)
	TooltipController:SetTooltip(currencyOption.ImageLabel, currency)
	currencyOption.Amount.BalanceLabel.Text = AlyaNum.new(0):toString()
	currencyOption.Amount.IncomeLabel.Visible = false
	currencyOption.Parent = BALANCE_WINDOW.Balances
	
	return currencyOption
end

function BalanceController:RefreshBalanceWindow(amountsPerCurrency: {[Currency.Currency]: AlyaNum.Number}?, incomesPerCurrency: {[Currency.Currency]: AlyaNum.Number}?)
	local size = 100
	local maxPage = 1
	for currency, details in pairs(Currency) do
		local currencyOption = BalanceController:GetCurrencyOption(currency)
	
		if (amountsPerCurrency ~= nil) then
			local amount = AlyaNum.new(amountsPerCurrency[currency] or 0)
			local exists = amount:moreThan(0)
			currencyOption.Visible = (exists or currency == "Bocchi") and BalanceController.Page == details.Page
			if currencyOption.Visible == true then
				size += currencyOption.AbsoluteSize.X
			end
			currencyOption.Amount.BalanceLabel.Text = tostring(amount)
			if exists and details.Page ~= nil and details.Page > maxPage then
				maxPage = details.Page
			end
		end
		if (incomesPerCurrency ~= nil) then
			local income = AlyaNum.new(incomesPerCurrency[currency] or 0)
			if (income:moreThan(0) == true) then
				currencyOption.Amount.IncomeLabel.Text = tostring(income) .. "/s"
				currencyOption.Amount.IncomeLabel.Visible = true
			else
				currencyOption.Amount.IncomeLabel.Visible = false
			end
		end
		
		currencyOption.LayoutOrder = details.LayoutOrder
		
	end
	if (amountsPerCurrency ~= nil) then
		BalanceController.MaxPage = maxPage
		if BalanceController.MaxPage == 1 and BalanceController.Page > 1 then
			BalanceController.Page = 1
			BalanceController:RefreshBalanceWindow(amountsPerCurrency)
			return nil
		end
		BALANCE_WINDOW.Balances.NavigationOptions.Visible = BalanceController.MaxPage > 1
		BALANCE_WINDOW.Balances.NavigationOptions.PageLabel.Text = namePerPage[BalanceController.Page] or "Main"
		local newSize = UDim2.new(0, size, 1, 0)
		if BALANCE_WINDOW.Balances.CanvasSize ~= newSize then
			BALANCE_WINDOW.Balances.CanvasSize = newSize
		end
	end
end
function BalanceController:LoadNavigationOption(navOption: typeof (BALANCE_WINDOW.Balances.NavigationOptions.Left), hotkey: Enum.KeyCode, label: string, action: () -> (), priority: number)
	local highlight = function()
		TweenService:Create(navOption.ImageButton, TweenInfo.new(0.3), {
			ImageTransparency = 0,
		}):Play()
	end
	local unhighlight = function()
		TweenService:Create(navOption.ImageButton, TweenInfo.new(0.3), {
			ImageTransparency = 0.5,
		}):Play()
	end
	unhighlight()
	navOption.MouseEnter:Connect(function()
		return highlight()
	end)
	navOption.MouseMoved:Connect(function()
		return highlight()
	end)
	navOption.MouseLeave:Connect(function()
		return unhighlight()
	end)
	HotkeysController:SetHotkey(navOption.ImageButton, hotkey, function()
		if not BALANCE_WINDOW.Balances.NavigationOptions.Visible then
			return false
		end
		local success = action()
		navOption.ImageButton.Size = UDim2.new(1.15, 0, 1.15, 0)
		TweenService:Create(navOption.ImageButton, TweenInfo.new(0.3), {
			Size = UDim2.new(1, 0, 1, 0),
		}):Play()
		constants.ASSETS.Sounds.Click:Play()
		return success
	end, label, priority)
end

function BalanceController:Init()
	BalanceController:LoadNavigationOption(BALANCE_WINDOW.Balances.NavigationOptions.Left, Enum.KeyCode.Z, "Previous Page", function()
		if BalanceController.Page == 1 then
			BalanceController.Page = BalanceController.MaxPage
		else
			BalanceController.Page -= 1
		end
		BalanceController:RefreshBalanceWindow()
		return true
	end)
	BalanceController:LoadNavigationOption(BALANCE_WINDOW.Balances.NavigationOptions.Right, Enum.KeyCode.C, "Next Page", function()
		if BalanceController.Page == BalanceController.MaxPage then
			BalanceController.Page = 1
		else
			BalanceController.Page += 1
		end
		BalanceController:RefreshBalanceWindow()
		return true
	end)
	Packets.changeCurrencies.listen(function(data)
		BalanceController:RefreshBalanceWindow(data)
	end)
	
	Packets.changeIncome.listen(function(data)
		BalanceController:RefreshBalanceWindow(nil, data)
	end)
end

export type BalanceController = typeof(BalanceController)

return BalanceController