--!optimize 2

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local StarterPlayer = game:GetService("StarterPlayer")
local Players = game:GetService("Players")
local constants = require(ReplicatedStorage.constants)
local Balance = require(ReplicatedStorage.Balance)
local Currency = require(ReplicatedStorage.Currency)
local Difficulty = require(ReplicatedStorage.Packages["jjt-difficulties"])
local Lumin = require(ReplicatedStorage.Packages.framework)
local DataController = require(ServerScriptService.Controllers.DataController)
local CurrencyController = require(ServerScriptService.Controllers.CurrencyController)
local Formula = require(ReplicatedStorage.Formula)
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Packets = require(ReplicatedStorage.Packets)

local ButtonController = {}

ButtonController.SufficientColor = Color3.fromRGB(255, 255, 255)
ButtonController.InsufficientColor = Color3.fromRGB(255, 60, 60)
ButtonController.AmountsPerButton = DataController.ServerProfile.Data.Buttons

export type Generation = {
	IsVariable: boolean,
	Add: (number) -> Balance.Balance,
	Mul: (number) -> Balance.Balance,
	Pow: (number) -> Balance.Balance,
}

export type ButtonInfo = {
	Name: string,
	Difficulty: typeof(setmetatable({}, Difficulty)),
	MaxAmount: number?,
	Formula: Formula.Formula?,
	FormulaVariable: string?,
	Effect: {
		Generation: Generation?,
		OnPurchase: () -> ()?,
		WalkSpeed: number?,
		[string]: Generation,
	},
	Descriptions: {
		Default: string
	},
	Cost: (number) -> Balance.Balance,
	
	Roots: {string}?,
	Purchased: boolean?,
	IsReady: boolean?,
}
type ButtonCache = { model: Model, mainFrame: Frame, info: ButtonInfo }

ButtonController.buttons = {} :: {[string]: ButtonCache}

local childrenPerButton = {} :: {[string]: {string}}


function ButtonController:GetButtonAmount(button: string)
	return ButtonController.AmountsPerButton[button] or 0
end

function ButtonController:SetButtonAmount(button: string, amount: number)
	ButtonController.AmountsPerButton[button] = amount
end

function ButtonController:IncrementButtonAmount(button: string, delta: number)
	ButtonController:SetButtonAmount(button, ButtonController:GetButtonAmount(button) + delta)
end

function ButtonController:CreateCurrencyOption(currency: Currency.Currency, amount: AlyaNum.AlyaNum)
	local option = constants.ASSETS.Button.CurrencyOption:Clone()
	local connection: RBXScriptConnection
	if currency ~= nil then
		local details = Currency[currency]
		option.ImageLabel.Image = "rbxassetid://" .. tostring(details.Image)
		option.LayoutOrder = details.LayoutOrder
		option.AmountLabel.Text = amount:lessEquals(0) and "Free!" or amount:toString()
		connection = RunService.Heartbeat:Connect(function()
			if option == nil or option.Parent == nil then
				connection:Disconnect()
				return nil
			end
			local inBalance = CurrencyController.Currencies:get(currency)
			option.AmountLabel.TextColor3 = if inBalance ~= nil and amount:lessEquals(inBalance) then ButtonController.SufficientColor else ButtonController.InsufficientColor
		end)
	end
	option.Destroying:Once(function()
		return connection:Disconnect()
	end)
	return option
end

function ButtonController:LoadButton(buttonModel: Instance)
	if (not buttonModel:IsA("Model")) then
		return
	end
	local module = buttonModel:FindFirstChildOfClass("ModuleScript")
	if (module == nil) then
		return
	end
	local info = require(module) :: ButtonInfo
	local mainPart = buttonModel:FindFirstChild("Button")
	if (mainPart == nil) then
		return
	end
	local surfaceGui = mainPart:FindFirstChildOfClass("SurfaceGui")
	if (surfaceGui == nil) then
		return
	end
	local mainFrame = surfaceGui:FindFirstChildOfClass("Frame")
	if (mainFrame == nil) then
		return
	end
	buttonModel:SetAttribute("OriginalCFrame", buttonModel:GetPivot())
	local id = buttonModel.Name
	childrenPerButton[id] = {}
	if (info.Roots == nil) then
		info.Roots = id == "B1" and {} or {"B" .. (tonumber(string.sub(id, 2)) - 1)}
	end
	for i, root in pairs(info.Roots) do
		if (childrenPerButton[root] == nil) then
			childrenPerButton[root] = {id}
		else
			table.insert(childrenPerButton[root], id)
		end
	end
	
	mainFrame.NameLabel.Text = info.Name
	mainFrame.DescriptionLabel.TextScaled = false
	surfaceGui.DifficultyLabel.Image = "rbxassetid://" .. info.Difficulty.image
	ButtonController.buttons[id] = {
		model = buttonModel,
		mainFrame = mainFrame,
		info = info
	}
	local line = buttonModel:FindFirstChild("Line")
	if (line ~= nil) then
		line.CanCollide = false
	end
end

function ButtonController:GetButtonCost(button: string)
	return ButtonController.buttons[button].info.Cost(ButtonController:GetButtonAmount(button) + 1)
end

function ButtonController:RefreshButton(button: string, cached: ButtonCache?)
	local label = "Amount: " .. ButtonController:GetButtonAmount(button)
	if (cached == nil) then
		cached = ButtonController.buttons[button]
	end
	local info = cached.info
	local maxAmount = info.MaxAmount
	if (maxAmount ~= nil) then
		label ..= "/" .. maxAmount
	end
	cached.mainFrame.AmountLabel.Text = label
	local costFrame = cached.mainFrame.Cost
	for i, v in pairs(costFrame:GetChildren()) do
		if (v:IsA("Frame")) then
			v:Destroy()
		end
	end
	if (ButtonController:IsVisible(info)) then
		cached.model:PivotTo(cached.model:GetAttribute("OriginalCFrame"))
	else
		cached.model:PivotTo(CFrame.new(0, -500, 0)) -- hide it from the world
	end
	local currentAmount = ButtonController:GetButtonAmount(button)
	if (currentAmount > 0 and info.Purchased ~= true) then
		info.Purchased = true
		if (info.Effect.OnPurchase ~= nil) then
			task.spawn(function()
				repeat task.wait() until info.IsReady == true
				info.Effect.OnPurchase()
			end)
		end
		if (info.Effect.WalkSpeed ~= nil) then
			StarterPlayer.CharacterWalkSpeed += info.Effect.WalkSpeed
			for i, player in pairs(Players:GetPlayers()) do
				if (player.Character ~= nil and player.Character:FindFirstChild("Humanoid") ~= nil) then
					player.Character.Humanoid.WalkSpeed += info.Effect.WalkSpeed
				end
			end
		end
	end
	if (info.MaxAmount == nil or currentAmount < info.MaxAmount) then
		cached.model:SetAttribute("Buyable", true)
		costFrame.HeadingLabel.Text = "Cost: "
		local cost = ButtonController:GetButtonCost(button)
		for currency, amount in pairs(cost.amountPerCurrency) do
			ButtonController:CreateCurrencyOption(currency, amount).Parent = costFrame
		end
	else
		cached.model:SetAttribute("Buyable", false)
		costFrame.HeadingLabel.Text = "Maxed!"
	end
	
	local description = info.Descriptions.Default
	if (info.Formula ~= nil) then
		description ..= `\n<font color="#{Color3.fromRGB(170, 255, 127):ToHex()}" size="20">Formula: &lt;{info.Formula:toString(info.FormulaVariable)}&gt;</font>`
	end
	cached.mainFrame.DescriptionLabel.Text = description
end

function ButtonController:RefreshButtons()
	for i, cached in pairs(ButtonController.buttons) do
		ButtonController:RefreshButton(i, cached)
	end
end

function ButtonController:IsVisible(info: ButtonInfo)
	for i, root in pairs(info.Roots) do
		if (ButtonController:GetButtonAmount(root) == 0) then
			return false
		end
	end
	return true
end


function ButtonController:Init()
	for i, button in pairs(constants.BUTTONS) do
		local id = button.Name
		if (ButtonController:GetButtonAmount(id) == 0) then
			ButtonController:SetButtonAmount(id, 0)
		end
	end
	Packets.buyButton.listen(function(data, player)
		if (not DataController:CheckPermLevel(player, "Purchase")) then
			Packets.error.sendTo("You don't meet the required permission level.", player)
			return
		end
		local id = data.button
		local cached = ButtonController.buttons[id]
		local info = cached.info
		if ((not ButtonController:IsVisible(info)) or (info.MaxAmount ~= nil and ButtonController:GetButtonAmount(id) >= info.MaxAmount)) then
			return
		end
		local cost = ButtonController:GetButtonCost(id)
		local canAfford, remaining = CurrencyController.Currencies:canAfford(cost)
		if (canAfford == false) then
			Packets.error.sendTo("Cannot afford.", player)
			return
		end
		for currency, amount in pairs(remaining) do
			CurrencyController.Currencies.amountPerCurrency[currency] = amount
		end
		ButtonController:IncrementButtonAmount(id, 1)
		ButtonController:RefreshButton(id, cached)
		for i, child in pairs(childrenPerButton[id]) do
			ButtonController:RefreshButton(child)
		end
		local buttonPart = cached.model:FindFirstChild("Button")
		Packets.buttonBought.sendToAll({
			button = id,
			difficulty = info.Difficulty.id
		})		
		task.spawn(function()
			local tweenInfo = TweenInfo.new(0.6, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
			for i = 1, 3 do
				local clone = Instance.new("Part")
				clone.CFrame = buttonPart.CFrame
				clone.Size = buttonPart.Size
				clone.Material = Enum.Material.Neon
				clone.Color = info.Difficulty.color
				clone.Transparency = 0.8
				clone.CastShadow = false
				clone.CanCollide = false
				clone.CanQuery = false
				clone.Anchored = true
				TweenService:Create(clone, tweenInfo, { Transparency = 1, CFrame = clone.CFrame + Vector3.new(0, 3, 0), Size = clone.Size + Vector3.new(3, 0.5, 3) }):Play()
				Debris:AddItem(clone)
				task.wait(0.15)
				clone.Parent = workspace
			end
		end)
	end)
	
	ButtonController:RefreshButtons()
end

for i, buttonModel in pairs(constants.BUTTONS) do
	ButtonController:LoadButton(buttonModel)
end

return ButtonController