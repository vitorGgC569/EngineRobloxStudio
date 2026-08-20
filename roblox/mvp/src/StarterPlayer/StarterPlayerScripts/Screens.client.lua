--!strict
-- The screens behind the buttons.
--
-- Índice (collection), Melhoria (card upgrades), Itens (potions),
-- Pronto! (rewards and codes), and Praça (rebirth and the Robux shop).
--
-- One modal frame reused by every screen. Five separate always-loaded panels
-- would cost five times the instances for something the player sees one of at
-- a time, and would make "which screen is open" a state that can be wrong.
--
-- Everything shown is server-published. A screen never computes a price, a
-- multiplier or an eligibility rule -- it asks, renders, and sends intent back.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("Shared")
local CardCatalog = require(shared:WaitForChild("CardCatalog"))
local Format = require(shared:WaitForChild("Format"))
local PotionCatalog = require(shared:WaitForChild("PotionCatalog"))
local RebirthCatalog = require(shared:WaitForChild("RebirthCatalog"))
local RewardCatalog = require(shared:WaitForChild("RewardCatalog"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)

local INK = Color3.fromRGB(28, 30, 40)
local INK_DEEP = Color3.fromRGB(17, 18, 25)
local TEXT = Color3.fromRGB(248, 250, 252)
local MUTED = Color3.fromRGB(150, 158, 172)
local GOLD = Color3.fromRGB(250, 206, 80)
local BLUE = Color3.fromRGB(108, 178, 255)
local GREEN = Color3.fromRGB(118, 226, 118)
local RED = Color3.fromRGB(232, 84, 84)

local RARITY_COLOR = {
	Common = Color3.fromRGB(186, 194, 206),
	Uncommon = Color3.fromRGB(118, 226, 132),
	Rare = Color3.fromRGB(92, 176, 255),
	Epic = Color3.fromRGB(190, 122, 255),
	Legendary = Color3.fromRGB(250, 200, 92),
	Mythic = Color3.fromRGB(255, 118, 110),
}

local gui = Instance.new("ScreenGui")
gui.Name = "Screens"
gui.DisplayOrder = 60
gui.ResetOnSpawn = false
gui.Enabled = true
gui.Parent = playerGui

-- ------------------------------------------------------------------ helpers

local function corner(instance: GuiObject, radius: number)
	local ui = Instance.new("UICorner")
	ui.CornerRadius = UDim.new(0, radius)
	ui.Parent = instance
end

local function stroke(instance: GuiObject, colour: Color3, thickness: number?)
	local ui = Instance.new("UIStroke")
	ui.Color = colour
	ui.Thickness = thickness or 3
	ui.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ui.Parent = instance
	return ui
end

local function text(parent: GuiObject, content: string, size: UDim2, position: UDim2, colour: Color3, textSize: number, alignment: Enum.TextXAlignment?): TextLabel
	local item = Instance.new("TextLabel")
	item.BackgroundTransparency = 1
	item.Size = size
	item.Position = position
	item.Text = content
	item.TextColor3 = colour
	item.TextSize = textSize
	item.Font = Enum.Font.FredokaOne
	item.TextXAlignment = alignment or Enum.TextXAlignment.Center
	item.TextTruncate = Enum.TextTruncate.AtEnd
	item.Parent = parent
	return item
end

local function button(parent: GuiObject, label: string, size: UDim2, position: UDim2, fill: Color3, textColour: Color3): TextButton
	local item = Instance.new("TextButton")
	item.Size = size
	item.Position = position
	item.BackgroundColor3 = fill
	item.BorderSizePixel = 0
	item.Text = label
	item.TextColor3 = textColour
	item.TextSize = 18
	item.Font = Enum.Font.FredokaOne
	item.AutoButtonColor = true
	item.Parent = parent
	corner(item, 8)
	stroke(item, Color3.fromRGB(255, 255, 255), 2)
	return item
end

-- -------------------------------------------------------------- modal shell

local shade = Instance.new("TextButton")
shade.Name = "Shade"
shade.Size = UDim2.fromScale(1, 1)
shade.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
shade.BackgroundTransparency = 0.42
shade.BorderSizePixel = 0
shade.Text = ""
shade.AutoButtonColor = false
shade.Visible = false
shade.Parent = gui

local window = Instance.new("Frame")
window.Name = "Window"
window.AnchorPoint = Vector2.new(0.5, 0.5)
window.Position = UDim2.fromScale(0.5, 0.5)
window.Size = UDim2.fromOffset(620, 440)
window.BackgroundColor3 = INK_DEEP
window.BorderSizePixel = 0
window.Parent = shade
corner(window, 12)
local windowStroke = stroke(window, BLUE, 3)

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 52)
header.BackgroundColor3 = BLUE
header.BorderSizePixel = 0
header.Parent = window
corner(header, 12)

local title = text(header, "", UDim2.new(1, -70, 1, 0), UDim2.fromOffset(18, 0), Color3.fromRGB(18, 20, 28), 25, Enum.TextXAlignment.Left)

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(38, 34)
closeButton.Position = UDim2.new(1, -48, 0, 9)
closeButton.BackgroundColor3 = RED
closeButton.BorderSizePixel = 0
closeButton.Text = "X"
closeButton.TextColor3 = TEXT
closeButton.TextSize = 20
closeButton.Font = Enum.Font.FredokaOne
closeButton.Parent = window
corner(closeButton, 7)
stroke(closeButton, TEXT, 2)

local body = Instance.new("ScrollingFrame")
body.Name = "Body"
body.Position = UDim2.fromOffset(14, 62)
body.Size = UDim2.new(1, -28, 1, -76)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 6
body.CanvasSize = UDim2.new()
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.Parent = window

local bodyLayout = Instance.new("UIListLayout")
bodyLayout.Padding = UDim.new(0, 8)
bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
bodyLayout.Parent = body

local function clearBody()
	for _, child in ipairs(body:GetChildren()) do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

local function closeScreen()
	shade.Visible = false
end
closeButton.Activated:Connect(closeScreen)
shade.Activated:Connect(closeScreen)

--- A row in the body list. Rows are the only layout primitive these screens
--- use, which is what keeps five different screens looking like one product.
local function row(height: number, order: number, outline: Color3?): Frame
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, -8, 0, height)
	frame.BackgroundColor3 = INK
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel = 0
	frame.LayoutOrder = order
	frame.Parent = body
	corner(frame, 9)
	if outline then
		stroke(frame, outline, 2)
	end
	return frame
end

local function openScreen(name: string, colour: Color3)
	title.Text = name
	header.BackgroundColor3 = colour
	windowStroke.Color = colour
	clearBody()
	shade.Visible = true
end

-- ------------------------------------------------------------------ screens

local Screens = {}

--- Índice: every card, owned or not. The completion count is the point.
function Screens.index()
	openScreen("Índice", BLUE)

	local owned: { [string]: boolean } = {}
	for entry in string.gmatch(tostring(player:GetAttribute("CardCollection") or ""), "[^,]+") do
		owned[entry] = true
	end

	local ordered = {}
	for id, card in pairs(CardCatalog.Cards) do
		table.insert(ordered, { id = id, card = card })
	end
	table.sort(ordered, function(a, b)
		local ra = CardCatalog.Rarities[a.card.rarity]
		local rb = CardCatalog.Rarities[b.card.rarity]
		if ra.order ~= rb.order then
			return ra.order < rb.order
		end
		return a.card.name < b.card.name
	end)

	local total, have = #ordered, 0
	for _, entry in ipairs(ordered) do
		if owned[entry.id] then
			have += 1
		end
	end

	local summary = row(46, 0, GREEN)
	text(summary, string.format("Coleção  %d / %d", have, total), UDim2.new(1, -20, 1, 0), UDim2.fromOffset(12, 0), TEXT, 21, Enum.TextXAlignment.Left)

	for index, entry in ipairs(ordered) do
		local card = entry.card
		local isOwned = owned[entry.id] == true
		local colour = RARITY_COLOR[card.rarity] or MUTED
		local line = row(56, index, if isOwned then colour else Color3.fromRGB(58, 62, 74))

		local swatch = Instance.new("Frame")
		swatch.Size = UDim2.fromOffset(6, 40)
		swatch.Position = UDim2.fromOffset(10, 8)
		swatch.BackgroundColor3 = colour
		swatch.BackgroundTransparency = if isOwned then 0 else 0.6
		swatch.BorderSizePixel = 0
		swatch.Parent = line
		corner(swatch, 3)

		text(line, if isOwned then card.name else "???", UDim2.new(0.5, 0, 0, 24), UDim2.fromOffset(26, 6), if isOwned then TEXT else MUTED, 18, Enum.TextXAlignment.Left)
		text(line, card.rarity, UDim2.new(0.5, 0, 0, 20), UDim2.fromOffset(26, 30), colour, 14, Enum.TextXAlignment.Left)
		text(line, if isOwned then string.format("poder %d", card.power) else "não descoberta", UDim2.new(0.4, -20, 1, 0), UDim2.new(0.6, 0, 0, 0), MUTED, 15, Enum.TextXAlignment.Right)
	end
end

--- Melhoria: raise a slotted card's level. Upgrades compound, so the screen
--- shows what a level costs and what it returns rather than just a button.
function Screens.upgrade()
	openScreen("Melhoria", GREEN)

	local slots = player:GetAttribute("SlotSummary")
	local header = row(58, 0, GREEN)
	text(header, "Melhore as cartas que mais rendem", UDim2.new(1, -20, 0, 26), UDim2.fromOffset(12, 6), TEXT, 19, Enum.TextXAlignment.Left)
	text(header, "Cada nível soma +25% de produção à carta.", UDim2.new(1, -20, 0, 20), UDim2.fromOffset(12, 32), MUTED, 15, Enum.TextXAlignment.Left)

	local filled = player:GetAttribute("FilledSlots") or 0
	if filled == 0 then
		local empty = row(60, 1)
		text(empty, "Nenhuma carta encaixada ainda.", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), MUTED, 17)
		return
	end

	for index = 1, math.min(filled, 40) do
		local line = row(58, index, Color3.fromRGB(60, 64, 78))
		text(line, string.format("Slot %d", index), UDim2.new(0.4, 0, 1, 0), UDim2.fromOffset(14, 0), TEXT, 18, Enum.TextXAlignment.Left)
		local upgrade = button(line, "Melhorar", UDim2.fromOffset(120, 36), UDim2.new(1, -134, 0, 11), GREEN, Color3.fromRGB(16, 32, 16))
		upgrade.Activated:Connect(function()
			local remote = remotes and remotes:FindFirstChild("UpgradeSlot")
			if remote then
				remote:FireServer(index)
			end
		end)
	end
	local _ = slots
end

--- Itens: buy and drink potions.
function Screens.items()
	openScreen("Itens", Color3.fromRGB(232, 118, 96))

	local held = {}
	for entry in string.gmatch(tostring(player:GetAttribute("PotionsHeld") or ""), "[^,]+") do
		local id, count = string.match(entry, "^(%w+):(%d+)$")
		if id then
			held[id] = tonumber(count) or 0
		end
	end

	local active = {}
	for entry in string.gmatch(tostring(player:GetAttribute("PotionsActive") or ""), "[^,]+") do
		local id, seconds = string.match(entry, "^(%w+):(%d+)$")
		if id then
			active[id] = tonumber(seconds) or 0
		end
	end

	for index, potion in ipairs(PotionCatalog.Potions) do
		local colour = Color3.fromRGB(potion.color[1], potion.color[2], potion.color[3])
		local line = row(74, index, colour)

		text(line, potion.icon, UDim2.fromOffset(46, 74), UDim2.fromOffset(8, 0), colour, 26)
		text(line, potion.name, UDim2.new(0.52, 0, 0, 24), UDim2.fromOffset(56, 8), TEXT, 18, Enum.TextXAlignment.Left)
		text(line, potion.description, UDim2.new(0.52, 0, 0, 20), UDim2.fromOffset(56, 30), MUTED, 14, Enum.TextXAlignment.Left)

		local remaining = active[potion.id]
		local state = if remaining and remaining > 0
			then string.format("ativa · %s", Format.duration(remaining))
			else string.format("tem %d", held[potion.id] or 0)
		text(line, state, UDim2.new(0.52, 0, 0, 18), UDim2.fromOffset(56, 50), if remaining then colour else MUTED, 13, Enum.TextXAlignment.Left)

		local use = button(line, "Usar", UDim2.fromOffset(78, 30), UDim2.new(1, -178, 0, 22), colour, Color3.fromRGB(18, 20, 26))
		use.Activated:Connect(function()
			local remote = remotes and remotes:FindFirstChild("UsePotion")
			if remote then
				remote:FireServer(potion.id)
			end
		end)

		local buy = button(line, Format.money(potion.price), UDim2.fromOffset(92, 30), UDim2.new(1, -96, 0, 22), GOLD, Color3.fromRGB(32, 26, 8))
		buy.Activated:Connect(function()
			local remote = remotes and remotes:FindFirstChild("BuyPotion")
			if remote then
				remote:FireServer(potion.id)
			end
		end)
	end
end

--- Pronto!: daily reward and code redemption.
function Screens.rewards()
	openScreen("Pronto!", GOLD)

	local streak = player:GetAttribute("DailyStreak") or 0
	local available = player:GetAttribute("DailyAvailable") == true

	local daily = row(96, 0, GOLD)
	text(daily, "Recompensa diária", UDim2.new(1, -20, 0, 26), UDim2.fromOffset(14, 8), TEXT, 20, Enum.TextXAlignment.Left)
	text(daily, string.format("sequência: %d dia(s)", streak), UDim2.new(1, -20, 0, 20), UDim2.fromOffset(14, 34), MUTED, 15, Enum.TextXAlignment.Left)

	local claim = button(daily, if available then "Resgatar" else "Já resgatada", UDim2.fromOffset(150, 34), UDim2.new(1, -164, 0, 30), if available then GREEN else Color3.fromRGB(70, 74, 88), if available then Color3.fromRGB(16, 32, 16) else MUTED)
	claim.Activated:Connect(function()
		local remote = remotes and remotes:FindFirstChild("ClaimDaily")
		if remote and available then
			remote:FireServer()
		end
	end)

	local codeRow = row(96, 1, BLUE)
	text(codeRow, "Códigos", UDim2.new(1, -20, 0, 26), UDim2.fromOffset(14, 8), TEXT, 20, Enum.TextXAlignment.Left)

	local input = Instance.new("TextBox")
	input.Size = UDim2.new(1, -180, 0, 36)
	input.Position = UDim2.fromOffset(14, 44)
	input.BackgroundColor3 = INK_DEEP
	input.BorderSizePixel = 0
	input.PlaceholderText = "digite um código"
	input.Text = ""
	input.TextColor3 = TEXT
	input.TextSize = 17
	input.Font = Enum.Font.FredokaOne
	input.ClearTextOnFocus = false
	input.Parent = codeRow
	corner(input, 7)
	stroke(input, Color3.fromRGB(70, 76, 92), 2)

	local submit = button(codeRow, "Resgatar", UDim2.fromOffset(150, 36), UDim2.new(1, -164, 0, 44), BLUE, Color3.fromRGB(14, 22, 34))
	submit.Activated:Connect(function()
		local remote = remotes and remotes:FindFirstChild("RedeemCode")
		if remote and input.Text ~= "" then
			remote:FireServer(input.Text)
			input.Text = ""
		end
	end)
end

--- Praça: rebirth and the Robux storefront.
function Screens.plaza()
	openScreen("Praça", GOLD)

	local level = player:GetAttribute("RebirthLevel") or 0
	local lifetime = player:GetAttribute("LifetimeCash") or 0
	local nextTier = RebirthCatalog.next(level)

	local rebirth = row(112, 0, Color3.fromRGB(190, 122, 255))
	text(rebirth, "Renascimento", UDim2.new(1, -20, 0, 26), UDim2.fromOffset(14, 8), TEXT, 20, Enum.TextXAlignment.Left)
	if nextTier then
		text(rebirth, string.format("%s · x%.1f dinheiro · +%d slots", nextTier.name, nextTier.cashMultiplier, nextTier.slotBonus), UDim2.new(1, -20, 0, 20), UDim2.fromOffset(14, 34), MUTED, 15, Enum.TextXAlignment.Left)
		text(rebirth, string.format("progresso: %s / %s", Format.money(lifetime), Format.money(nextTier.requirement)), UDim2.new(1, -20, 0, 20), UDim2.fromOffset(14, 56), if lifetime >= nextTier.requirement then GREEN else MUTED, 15, Enum.TextXAlignment.Left)

		local go = button(rebirth, "Renascer", UDim2.fromOffset(150, 36), UDim2.new(1, -164, 0, 40), if lifetime >= nextTier.requirement then Color3.fromRGB(190, 122, 255) else Color3.fromRGB(70, 74, 88), TEXT)
		go.Activated:Connect(function()
			local remote = remotes and remotes:FindFirstChild("Rebirth")
			if remote then
				remote:FireServer()
			end
		end)
	else
		text(rebirth, "Nível máximo alcançado.", UDim2.new(1, -20, 0, 20), UDim2.fromOffset(14, 34), GREEN, 16, Enum.TextXAlignment.Left)
	end

	local storeHeader = row(40, 1)
	text(storeHeader, "Loja Robux", UDim2.new(1, -20, 1, 0), UDim2.fromOffset(14, 0), TEXT, 19, Enum.TextXAlignment.Left)

	for index, product in ipairs(RewardCatalog.Products) do
		local colour = Color3.fromRGB(product.color[1], product.color[2], product.color[3])
		local line = row(70, index + 1, colour)
		text(line, product.name, UDim2.new(0.6, 0, 0, 24), UDim2.fromOffset(14, 8), TEXT, 18, Enum.TextXAlignment.Left)
		text(line, product.description, UDim2.new(0.6, 0, 0, 20), UDim2.fromOffset(14, 32), MUTED, 14, Enum.TextXAlignment.Left)

		local ready = RewardCatalog.isConfigured(product.id)
		local buy = button(line, if ready then string.format("R$ %d", product.robux) else "indisponível",
			UDim2.fromOffset(146, 34), UDim2.new(1, -160, 0, 18),
			if ready then GREEN else Color3.fromRGB(64, 68, 82),
			if ready then Color3.fromRGB(16, 32, 16) else MUTED)
		buy.Activated:Connect(function()
			if not ready then
				return
			end
			local remote = remotes and remotes:FindFirstChild("BuyProduct")
			if remote then
				remote:FireServer(product.id)
			end
		end)
	end

	-- Say plainly why the store is inert rather than letting a player press a
	-- dead button and wonder.
	if #RewardCatalog.configured() == 0 then
		local note = row(56, 100, Color3.fromRGB(90, 94, 110))
		text(note, "Produtos ainda não criados no Creator Dashboard.", UDim2.new(1, -20, 1, 0), UDim2.fromOffset(14, 0), MUTED, 15, Enum.TextXAlignment.Left)
	end
end

--- Vender: sell every box without walking to the shop.
function Screens.sell()
	openScreen("Vender", GREEN)
	local boxes = player:GetAttribute("Boxes") or 0
	local value = player:GetAttribute("PendingValue") or 0

	local line = row(110, 0, GREEN)
	text(line, string.format("%s caixas prontas", Format.short(boxes)), UDim2.new(1, -20, 0, 28), UDim2.fromOffset(14, 10), TEXT, 21, Enum.TextXAlignment.Left)
	text(line, string.format("valem %s", Format.money(value)), UDim2.new(1, -20, 0, 24), UDim2.fromOffset(14, 40), GREEN, 18, Enum.TextXAlignment.Left)

	local sell = button(line, "Vender tudo", UDim2.fromOffset(170, 38), UDim2.new(1, -184, 0, 36), GREEN, Color3.fromRGB(16, 32, 16))
	sell.Activated:Connect(function()
		local remote = remotes and remotes:FindFirstChild("SellBoxes")
		if remote then
			remote:FireServer()
		end
		closeScreen()
	end)
end

--- Base: close everything and look at the farm.
function Screens.base()
	closeScreen()
end

-- Published so the HUD's buttons can open these without duplicating them.
local api = Instance.new("BindableFunction")
api.Name = "OpenScreen"
api.Parent = gui
api.OnInvoke = function(name: string)
	local handler = (Screens :: any)[name]
	if handler then
		handler()
		return true
	end
	return false
end
