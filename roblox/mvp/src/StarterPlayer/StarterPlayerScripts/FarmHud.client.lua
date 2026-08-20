--!strict
-- The game's whole interface.
--
-- Laid out to match the reference collector: navigation tabs across the top, a
-- shop cluster top-left, money bottom-left, a card hotbar across the bottom,
-- and multipliers bottom-right. That arrangement is not arbitrary -- it keeps
-- the centre of the screen, where the game actually happens, completely clear.
--
-- Chunky rather than minimal: thick borders and heavy type read on a phone at
-- arm's length, which is where most of these games are played. The one place
-- restraint applies is the money readout, which stays plain text.
--
-- Every value comes from a player attribute the server publishes each second.
-- The HUD computes nothing, so what is on screen and what the server believes
-- cannot drift apart.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Format = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Format"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local INK = Color3.fromRGB(28, 30, 40)
local INK_DEEP = Color3.fromRGB(18, 19, 26)
local TEXT = Color3.fromRGB(248, 250, 252)
local MUTED = Color3.fromRGB(158, 166, 180)
local GOLD = Color3.fromRGB(250, 206, 80)
local BLUE = Color3.fromRGB(108, 178, 255)
local GREEN = Color3.fromRGB(118, 226, 118)
local PINK = Color3.fromRGB(240, 118, 190)

local RARITY_COLOR = {
	Common = Color3.fromRGB(186, 194, 206),
	Uncommon = Color3.fromRGB(118, 226, 132),
	Rare = Color3.fromRGB(92, 176, 255),
	Epic = Color3.fromRGB(190, 122, 255),
	Legendary = Color3.fromRGB(250, 200, 92),
	Mythic = Color3.fromRGB(255, 118, 110),
}

local gui = Instance.new("ScreenGui")
gui.Name = "FarmHud"
gui.DisplayOrder = 40
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.Parent = playerGui

-- ------------------------------------------------------------------ helpers

local function corner(instance: GuiObject, radius: number)
	local ui = Instance.new("UICorner")
	ui.CornerRadius = UDim.new(0, radius)
	ui.Parent = instance
end

--- The thick outline that gives every panel its weight.
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
	item.TextStrokeColor3 = Color3.fromRGB(12, 12, 18)
	item.TextStrokeTransparency = 0.35
	item.Parent = parent
	return item
end

local function panel(parent: GuiObject, size: UDim2, position: UDim2, anchor: Vector2, outline: Color3): Frame
	local frame = Instance.new("Frame")
	frame.Size = size
	frame.Position = position
	frame.AnchorPoint = anchor
	frame.BackgroundColor3 = INK
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.Parent = parent
	corner(frame, 10)
	stroke(frame, outline, 3)
	return frame
end

-- --------------------------------------------------------------- top tabs

local tabs = Instance.new("Frame")
tabs.Name = "Tabs"
tabs.AnchorPoint = Vector2.new(0.5, 0)
tabs.Position = UDim2.new(0.5, 0, 0, 8)
tabs.Size = UDim2.fromOffset(560, 46)
tabs.BackgroundTransparency = 1
tabs.Parent = gui

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
tabLayout.Padding = UDim.new(0, 12)
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.Parent = tabs

local activeTab = "Base"
local tabButtons: { [string]: TextButton } = {}

local tabOrder = 0
local function makeTab(name: string, icon: string, colour: Color3)
	tabOrder += 1
	local button = Instance.new("TextButton")
	button.Name = name
	button.LayoutOrder = tabOrder
	button.Size = UDim2.fromOffset(172, 44)
	button.BackgroundColor3 = INK
	button.BackgroundTransparency = 0.05
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	button.Parent = tabs
	corner(button, 9)
	stroke(button, colour, 3)

	text(button, icon, UDim2.fromOffset(34, 44), UDim2.fromOffset(10, 0), colour, 22)
	text(button, name, UDim2.new(1, -50, 1, 0), UDim2.fromOffset(46, 0), colour, 21, Enum.TextXAlignment.Left)

	tabButtons[name] = button
	return button
end

--- Screens.client.lua publishes a BindableFunction; the HUD only asks. Keeping
--- the screens in one script means a button can never open a half-built panel
--- that another script was still assembling.
local function openScreen(name: string)
	local screens = playerGui:WaitForChild("Screens", 10)
	local api = screens and screens:FindFirstChild("OpenScreen")
	if api and api:IsA("BindableFunction") then
		api:Invoke(name)
	end
end

makeTab("Praça", "🏅", GOLD).Activated:Connect(function() openScreen("plaza") end)
makeTab("Base", "🟦", BLUE).Activated:Connect(function() openScreen("base") end)
makeTab("Vender", "💵", GREEN).Activated:Connect(function() openScreen("sell") end)

-- ------------------------------------------------------------- shop cluster

local shop = panel(gui, UDim2.fromOffset(196, 62), UDim2.fromOffset(12, 96), Vector2.new(0, 0), PINK)
shop.Name = "Shop"
text(shop, "🧺", UDim2.fromOffset(54, 62), UDim2.fromOffset(6, 0), TEXT, 30)
text(shop, "Loja", UDim2.new(1, -62, 1, 0), UDim2.fromOffset(58, 0), TEXT, 26, Enum.TextXAlignment.Left)

local shopHit = Instance.new("TextButton")
shopHit.Size = UDim2.fromScale(1, 1)
shopHit.BackgroundTransparency = 1
shopHit.Text = ""
shopHit.Parent = shop
shopHit.Activated:Connect(function() openScreen("plaza") end)

local grid = Instance.new("Frame")
grid.Name = "ShopGrid"
grid.Position = UDim2.fromOffset(12, 164)
grid.Size = UDim2.fromOffset(196, 196)
grid.BackgroundTransparency = 1
grid.Parent = gui

local gridLayout = Instance.new("UIGridLayout")
gridLayout.CellSize = UDim2.fromOffset(92, 92)
gridLayout.CellPadding = UDim2.fromOffset(10, 10)
gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
gridLayout.Parent = grid

local tileOrder = 0
local function makeTile(name: string, icon: string, colour: Color3, badge: string?)
	tileOrder += 1
	local tile = Instance.new("TextButton")
	tile.Name = name
	tile.LayoutOrder = tileOrder
	tile.BackgroundColor3 = INK
	tile.BackgroundTransparency = 0.08
	tile.BorderSizePixel = 0
	tile.Text = ""
	tile.AutoButtonColor = false
	tile.Parent = grid
	corner(tile, 9)
	stroke(tile, colour, 3)

	text(tile, icon, UDim2.new(1, 0, 0, 44), UDim2.fromOffset(0, 8), colour, 28)
	text(tile, name, UDim2.new(1, 0, 0, 26), UDim2.new(0, 0, 1, -32), TEXT, 17)

	if badge then
		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromOffset(24, 24)
		dot.Position = UDim2.new(1, -14, 0, -10)
		dot.BackgroundColor3 = Color3.fromRGB(232, 72, 72)
		dot.BorderSizePixel = 0
		dot.Parent = tile
		corner(dot, 6)
		stroke(dot, Color3.fromRGB(255, 255, 255), 2)
		text(dot, badge, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), TEXT, 15)
	end
	return tile
end

makeTile("Índice", "📘", BLUE).Activated:Connect(function() openScreen("index") end)
makeTile("Melhoria", "💠", GREEN).Activated:Connect(function() openScreen("upgrade") end)
makeTile("Itens", "🧪", Color3.fromRGB(232, 118, 96)).Activated:Connect(function() openScreen("items") end)
makeTile("Pronto!", "🎁", GOLD, "1").Activated:Connect(function() openScreen("rewards") end)

-- ------------------------------------------------------------------- money

local money = Instance.new("Frame")
money.Name = "Money"
money.AnchorPoint = Vector2.new(0, 1)
money.Position = UDim2.new(0, 14, 1, -12)
money.Size = UDim2.fromOffset(300, 70)
money.BackgroundTransparency = 1
money.Parent = gui

local cashLabel = text(money, "$0", UDim2.new(1, -56, 0, 46), UDim2.fromOffset(56, 18), TEXT, 40, Enum.TextXAlignment.Left)
cashLabel.TextStrokeTransparency = 0
text(money, "🪙", UDim2.fromOffset(50, 50), UDim2.fromOffset(0, 16), GOLD, 34)
local rateLabel = text(money, "+$0/s", UDim2.new(1, -56, 0, 20), UDim2.fromOffset(58, 0), GREEN, 17, Enum.TextXAlignment.Left)

-- ------------------------------------------------------------- multipliers

local multipliers = Instance.new("Frame")
multipliers.Name = "Multipliers"
multipliers.AnchorPoint = Vector2.new(1, 1)
multipliers.Position = UDim2.new(1, -14, 1, -14)
multipliers.Size = UDim2.fromOffset(220, 64)
multipliers.BackgroundTransparency = 1
multipliers.Parent = gui

local luckLabel = text(multipliers, "Sorte: 1.00x", UDim2.new(1, 0, 0, 28), UDim2.fromOffset(0, 0), GREEN, 21, Enum.TextXAlignment.Right)
local cashMultLabel = text(multipliers, "Dinheiro: 1.00x", UDim2.new(1, 0, 0, 28), UDim2.fromOffset(0, 32), TEXT, 19, Enum.TextXAlignment.Right)

-- ------------------------------------------------------------------ status

local status = panel(gui, UDim2.fromOffset(250, 40), UDim2.new(0.5, 0, 0, 60), Vector2.new(0.5, 0), Color3.fromRGB(84, 88, 102))
status.Name = "FarmStatus"
local slotsLabel = text(status, "SLOTS 0/10", UDim2.new(0.5, -10, 1, 0), UDim2.fromOffset(12, 0), MUTED, 16, Enum.TextXAlignment.Left)
local boxesLabel = text(status, "NO BOXES", UDim2.new(0.5, -10, 1, 0), UDim2.new(0.5, 0, 0, 0), TEXT, 16, Enum.TextXAlignment.Right)

-- ----------------------------------------------------------------- hotbar

local hotbar = Instance.new("Frame")
hotbar.Name = "Hotbar"
hotbar.AnchorPoint = Vector2.new(0.5, 1)
hotbar.Position = UDim2.new(0.5, 0, 1, -10)
hotbar.Size = UDim2.fromOffset(640, 62)
hotbar.BackgroundTransparency = 1
hotbar.Parent = gui

local hotbarLayout = Instance.new("UIListLayout")
hotbarLayout.FillDirection = Enum.FillDirection.Horizontal
hotbarLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
hotbarLayout.VerticalAlignment = Enum.VerticalAlignment.Center
hotbarLayout.Padding = UDim.new(0, 6)
hotbarLayout.SortOrder = Enum.SortOrder.LayoutOrder
hotbarLayout.Parent = hotbar

local hotbarSlots: { Frame } = {}
for index = 1, 10 do
	local cell = Instance.new("Frame")
	cell.Name = string.format("Cell%d", index)
	cell.Size = UDim2.fromOffset(58, 58)
	cell.BackgroundColor3 = INK_DEEP
	cell.BackgroundTransparency = 0.15
	cell.BorderSizePixel = 0
	cell.LayoutOrder = index
	cell.Parent = hotbar
	corner(cell, 7)
	stroke(cell, Color3.fromRGB(96, 100, 114), 2)

	text(cell, tostring(index % 10), UDim2.fromOffset(16, 16), UDim2.fromOffset(4, 2), MUTED, 13, Enum.TextXAlignment.Left)
	local card = text(cell, "", UDim2.new(1, -6, 0, 30), UDim2.fromOffset(3, 24), TEXT, 12)
	card.Name = "CardName"
	card.TextWrapped = true

	hotbarSlots[index] = cell
end

-- -------------------------------------------------------------- held card

local held = panel(gui, UDim2.fromOffset(280, 56), UDim2.new(0.5, 0, 1, -82), Vector2.new(0.5, 1), GOLD)
held.Name = "HeldCard"
held.Visible = false
local heldName = text(held, "", UDim2.new(1, -20, 0, 26), UDim2.fromOffset(12, 6), TEXT, 20, Enum.TextXAlignment.Left)
local heldHint = text(held, "", UDim2.new(1, -20, 0, 20), UDim2.fromOffset(12, 30), MUTED, 14, Enum.TextXAlignment.Left)
local heldStroke = stroke(held, GOLD, 3)

-- ------------------------------------------------------------------ toast

local toast = text(gui, "", UDim2.fromOffset(460, 30), UDim2.new(0.5, -230, 0, 108), TEXT, 20)
toast.Name = "Toast"
toast.TextTransparency = 1

local toastToken = 0
local function say(message: string, colour: Color3?)
	toastToken += 1
	local token = toastToken
	toast.Text = message
	toast.TextColor3 = colour or TEXT
	toast.TextTransparency = 1
	TweenService:Create(toast, TweenInfo.new(0.15), { TextTransparency = 0 }):Play()
	task.delay(2.8, function()
		if token == toastToken then
			TweenService:Create(toast, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
		end
	end)
end

-- ----------------------------------------------------- welcome-back modal

--- Shown once on join when the farm earned while the player was away. This is
--- the reference's most prominent monetisation surface, so it is built as a
--- real screen rather than a line of text.
local function showWelcomeBack(boxes: number, seconds: number)
	local shade = Instance.new("Frame")
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	shade.BackgroundTransparency = 0.45
	shade.BorderSizePixel = 0
	shade.ZIndex = 50
	shade.Parent = gui

	local card = panel(shade, UDim2.fromOffset(420, 260), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5), BLUE)
	card.ZIndex = 51
	card.BackgroundColor3 = INK_DEEP

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, 52)
	header.BackgroundColor3 = BLUE
	header.BorderSizePixel = 0
	header.ZIndex = 52
	header.Parent = card
	corner(header, 10)
	text(header, "Bem-vindo de volta!", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Color3.fromRGB(20, 22, 30), 25).ZIndex = 53

	local close = Instance.new("TextButton")
	close.Size = UDim2.fromOffset(38, 34)
	close.Position = UDim2.new(1, -46, 0, 9)
	close.BackgroundColor3 = Color3.fromRGB(232, 72, 72)
	close.BorderSizePixel = 0
	close.Text = "X"
	close.TextColor3 = TEXT
	close.TextSize = 20
	close.Font = Enum.Font.FredokaOne
	close.ZIndex = 54
	close.Parent = card
	corner(close, 7)
	stroke(close, TEXT, 2)

	text(card, "Você ganhou:", UDim2.new(1, 0, 0, 30), UDim2.fromOffset(0, 66), TEXT, 22).ZIndex = 52

	local amount = Instance.new("Frame")
	amount.Size = UDim2.new(1, -40, 0, 66)
	amount.Position = UDim2.fromOffset(20, 100)
	amount.BackgroundColor3 = Color3.fromRGB(10, 11, 16)
	amount.BorderSizePixel = 0
	amount.ZIndex = 52
	amount.Parent = card
	corner(amount, 8)
	text(amount, Format.money(boxes), UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), GREEN, 38).ZIndex = 53

	text(card, string.format("enquanto esteve fora por %s", Format.duration(seconds)), UDim2.new(1, 0, 0, 24), UDim2.fromOffset(0, 172), MUTED, 15).ZIndex = 52

	local ok = Instance.new("TextButton")
	ok.Size = UDim2.fromOffset(200, 48)
	ok.Position = UDim2.new(0.5, -100, 1, -60)
	ok.BackgroundColor3 = GREEN
	ok.BorderSizePixel = 0
	ok.Text = "OK"
	ok.TextColor3 = Color3.fromRGB(18, 30, 18)
	ok.TextSize = 26
	ok.Font = Enum.Font.FredokaOne
	ok.ZIndex = 53
	ok.Parent = card
	corner(ok, 9)
	stroke(ok, Color3.fromRGB(240, 255, 240), 3)

	local function dismiss()
		shade:Destroy()
	end
	close.Activated:Connect(dismiss)
	ok.Activated:Connect(dismiss)
end

-- ----------------------------------------------------------------- binding

local function refresh()
	local cash = player:GetAttribute("Currency") or 0
	cashLabel.Text = Format.money(cash)
	rateLabel.Text = "+" .. Format.rate(player:GetAttribute("CashPerSecond") or 0)

	local unlocked = player:GetAttribute("Slots") or 0
	local filled = player:GetAttribute("FilledSlots") or 0
	slotsLabel.Text = string.format("SLOTS %d/%d", filled, unlocked)

	local boxes = player:GetAttribute("Boxes") or 0
	boxesLabel.Text = if boxes > 0
		then string.format("%s · %s", Format.short(boxes), Format.money(player:GetAttribute("PendingValue") or 0))
		else "NO BOXES"

	luckLabel.Text = "Sorte: " .. Format.multiplier(player:GetAttribute("Luck") or 1)
	cashMultLabel.Text = "Dinheiro: " .. Format.multiplier(player:GetAttribute("CashMultiplier") or 1)

	local card = player:GetAttribute("HeldCard")
	if card then
		local rarity = player:GetAttribute("HeldRarity") or "Common"
		local mutation = player:GetAttribute("HeldMutation")
		local colour = RARITY_COLOR[rarity] or MUTED
		held.Visible = true
		heldStroke.Color = colour
		heldName.TextColor3 = colour
		heldName.Text = if mutation and mutation ~= "none"
			then string.format("%s %s", string.upper(mutation), card)
			else tostring(card)
		heldHint.Text = string.format("%s · leve até um slot", string.lower(rarity))
	else
		held.Visible = false
	end

	local collection = tostring(player:GetAttribute("CardCollection") or "")
	local index = 1
	for entry in string.gmatch(collection, "[^,]+") do
		if index > #hotbarSlots then
			break
		end
		local cell = hotbarSlots[index]
		local nameLabel = cell:FindFirstChild("CardName") :: TextLabel?
		if nameLabel then
			nameLabel.Text = entry
		end
		index += 1
	end
	for empty = index, #hotbarSlots do
		local nameLabel = hotbarSlots[empty]:FindFirstChild("CardName") :: TextLabel?
		if nameLabel then
			nameLabel.Text = ""
		end
	end
end

for _, attribute in ipairs({
	"Currency", "CashPerSecond", "Slots", "FilledSlots", "Boxes", "PendingValue",
	"HeldCard", "HeldRarity", "HeldMutation", "Luck", "CashMultiplier", "CardCollection",
}) do
	player:GetAttributeChangedSignal(attribute):Connect(refresh)
end
refresh()

task.defer(function()
	local boxes = player:GetAttribute("OfflineBoxes")
	local seconds = player:GetAttribute("OfflineSeconds")
	if boxes and boxes > 0 then
		showWelcomeBack(boxes, seconds or 0)
	end
end)

local remotes = ReplicatedStorage:WaitForChild("Remotes", 20)
if remotes then
	local landed = remotes:FindFirstChild("CardLanded")
	if landed then
		landed.OnClientEvent:Connect(function(payload)
			if type(payload) ~= "table" then
				return
			end
			local colour = RARITY_COLOR[payload.rarity or "Common"] or TEXT
			if payload.action == "offered" then
				local mutation = payload.mutation
				local name = if mutation and mutation ~= "none"
					then string.format("%s %s", string.upper(mutation), payload.cardId)
					else tostring(payload.cardId)
				say(string.format("%s · %s · %s", name, payload.rarity, Format.rate(payload.income or 0)), colour)
			elseif payload.action == "taken" then
				say(if payload.isNew then "carta nova!" else string.format("repetida · +%s", Format.money(payload.refund or 0)), colour)
			elseif payload.action == "missed" then
				say("carta perdida", MUTED)
			elseif payload.rejected then
				say(tostring(payload.reason), MUTED)
			end
		end)
	end

	local farmEvent = remotes:FindFirstChild("FarmEvent")
	if farmEvent then
		farmEvent.OnClientEvent:Connect(function(payload)
			if type(payload) ~= "table" then
				return
			end
			if payload.action == "sell" and payload.ok then
				say(string.format("vendeu %s caixas · +%s", Format.short(payload.boxes or 0), Format.money(payload.cash or 0)), GREEN)
			elseif payload.action == "place" then
				say(if payload.ok then string.format("slot %d preenchido", payload.slot or 0) else tostring(payload.reason), if payload.ok then GREEN else MUTED)
			elseif payload.action == "unlock_slot" then
				say(if payload.ok then string.format("slot %d liberado", payload.slot or 0) else tostring(payload.reason), if payload.ok then GREEN else MUTED)
			end
		end)
	end
end
