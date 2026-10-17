--!nonstrict
-- Prisma: presentation only. Garden owns prices, proximity and all mutations.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local net = ReplicatedStorage:WaitForChild("GardenNet")
local Action = net:WaitForChild("Action")
local State = net:WaitForChild("State")
local Toast = net:WaitForChild("Toast")

local C = {
	ink = Color3.fromRGB(36, 56, 63), muted = Color3.fromRGB(83, 107, 114),
	paper = Color3.fromRGB(247, 252, 250), mint = Color3.fromRGB(196, 242, 224),
	green = Color3.fromRGB(32, 104, 82), lavender = Color3.fromRGB(231, 222, 252),
	purple = Color3.fromRGB(101, 71, 143), line = Color3.fromRGB(206, 224, 220),
	gold = Color3.fromRGB(255, 226, 155), error = Color3.fromRGB(163, 52, 70),
	disabled = Color3.fromRGB(229, 235, 233), white = Color3.new(1, 1, 1),
}
local connections = {}
local alive = true
local snapshot = nil
local currentTab = "species"
local panelOpen = false
local gamepad = false
local compact = false
local requestTimes = {}
local speciesRows, upgradeRows, collectionRows, tabs = {}, {}, {}, {}
local toastQueue = {}
local toastBusy = false
local toastGeneration = 0
local toastWidth = 360

local function connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(connections, connection)
	return connection
end

local function make(className, parent, props)
	local object = Instance.new(className)
	for key, value in pairs(props or {}) do object[key] = value end
	object.Parent = parent
	return object
end

local function round(object, radius)
	make("UICorner", object, { CornerRadius = UDim.new(0, radius or 14) })
end

local function outline(object, color, thickness)
	return make("UIStroke", object, { Color = color or C.line, Thickness = thickness or 1 })
end

local function frame(parent, name, color)
	return make("Frame", parent, {
		Name = name, BackgroundColor3 = color or C.paper, BorderSizePixel = 0,
	})
end

local function label(parent, name, text, size, color)
	return make("TextLabel", parent, {
		Name = name, BackgroundTransparency = 1, BorderSizePixel = 0,
		Text = text, TextSize = size or 16, TextColor3 = color or C.ink,
		Font = Enum.Font.GothamMedium, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd,
	})
end

local function button(parent, name, text)
	local object = make("TextButton", parent, {
		Name = name, Text = text, TextSize = 15, Font = Enum.Font.GothamBold,
		TextColor3 = C.green, BackgroundColor3 = C.mint, BorderSizePixel = 0,
		AutoButtonColor = false, Selectable = true, TextWrapped = true,
	})
	round(object, 12)
	local stroke = outline(object)
	connect(object.MouseEnter, function() stroke.Color = C.purple end)
	connect(object.MouseLeave, function() stroke.Color = C.line end)
	connect(object.SelectionGained, function() stroke.Color = C.purple; stroke.Thickness = 3 end)
	connect(object.SelectionLost, function() stroke.Color = C.line; stroke.Thickness = 1 end)
	return object
end

local function tween(object, seconds, props)
	local animation = TweenService:Create(object, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	animation:Play()
	return animation
end

local function number(value)
	local text = tostring(math.floor(tonumber(value) or 0))
	local formatted = text:reverse():gsub("(%d%d%d)", "%1."):reverse():gsub("^%.", "")
	return formatted
end

local function colorOf(species)
	return Color3.fromRGB(species.color[1], species.color[2], species.color[3])
end

-- A faceted crystal built entirely from GUI rectangles: no uploaded assets.
local function crystal(parent, color, size)
	local holder = make("Frame", parent, { Name = "Crystal", Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1 })
	local body = frame(holder, "Facet", color)
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Position = UDim2.fromScale(0.5, 0.5)
	body.Size = UDim2.fromScale(0.55, 0.55)
	body.Rotation = 45
	round(body, 4)
	outline(body, color:Lerp(C.white, 0.4), 2)
	make("UIGradient", body, {
		Color = ColorSequence.new(color:Lerp(C.white, 0.6), color), Rotation = 90,
	})
	local shine = frame(holder, "Shine", C.white)
	shine.Size = UDim2.fromScale(0.11, 0.28)
	shine.Position = UDim2.fromScale(0.36, 0.29)
	shine.Rotation = 35
	shine.BackgroundTransparency = 0.35
	round(shine, 3)
	return holder
end

local screen = make("ScreenGui", playerGui, {
	Name = "CrystalGardenHUD", ResetOnSpawn = false, DisplayOrder = 10,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets, ClipToDeviceSafeArea = true,
})
local safe = make("Frame", screen, { Name = "SafeArea", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 })
local root = make("Frame", safe, { Name = "Layout", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
local uiScale = make("UIScale", root, { Scale = 1 })

local hud = make("Frame", root, { Name = "Header", BackgroundTransparency = 1 })
local titleMark = crystal(hud, Color3.fromRGB(154, 216, 206), 28)
titleMark.Position = UDim2.fromOffset(0, 1)
local title = label(hud, "Title", "JARDIM DE CRISTAIS", 16, C.ink)
title.Font = Enum.Font.GothamBold
title.Position = UDim2.fromOffset(32, 0)
title.Size = UDim2.new(1, -136, 0, 30)
local menuButton = button(hud, "Menu", "Menu [M]")
menuButton.AnchorPoint = Vector2.new(1, 0)
menuButton.Position = UDim2.fromScale(1, 0)
menuButton.Size = UDim2.fromOffset(96, 50)
menuButton.BackgroundColor3 = C.lavender
menuButton.TextColor3 = C.purple

local stats = make("Frame", hud, { Name = "Stats", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 58), Size = UDim2.new(1, 0, 0, 66) })
local function stat(name, caption, x, background)
	local tile = frame(stats, name, background)
	tile.Position = UDim2.new(x, x == 0 and 0 or 4, 0, 0)
	tile.Size = UDim2.new(1 / 3, -6, 1, 0)
	round(tile)
	outline(tile)
	local heading = label(tile, "Caption", caption, 12, C.muted)
	heading.Position = UDim2.fromOffset(10, 6)
	heading.Size = UDim2.new(1, -20, 0, 17)
	local value = label(tile, "Value", "—", 20, C.ink)
	value.Font = Enum.Font.GothamBold
	value.Position = UDim2.fromOffset(10, 26)
	value.Size = UDim2.new(1, -20, 0, 32)
	return tile, value, heading
end
local _, coinsText = stat("Coins", "MOEDAS", 0, C.gold)
local bagTile, bagText, bagCaption = stat("Backpack", "MOCHILA", 1 / 3, C.mint)
local _, weatherText, weatherCaption = stat("Weather", "CLIMA", 2 / 3, C.lavender)
weatherText.TextSize = 14
weatherText.TextWrapped = true
weatherText.TextTruncate = Enum.TextTruncate.None
local bagPulse = make("UIScale", bagTile, { Scale = 1 })

local goalCard = frame(hud, "Goal", C.paper)
goalCard.Position = UDim2.fromOffset(0, 132)
goalCard.Size = UDim2.new(1, 0, 0, 42)
round(goalCard, 10)
outline(goalCard)
local goalText = label(goalCard, "Objective", "Conectando ao seu jardim…", 13, C.ink)
goalText.Position = UDim2.fromOffset(10, 3)
goalText.Size = UDim2.new(1, -76, 0, 27)
local goalCount = label(goalCard, "Progress", "", 12, C.muted)
goalCount.TextXAlignment = Enum.TextXAlignment.Right
goalCount.Position = UDim2.new(1, -72, 0, 3)
goalCount.Size = UDim2.fromOffset(62, 27)
local goalTrack = frame(goalCard, "Track", C.line)
goalTrack.Position = UDim2.fromOffset(10, 33)
goalTrack.Size = UDim2.new(1, -20, 0, 4)
round(goalTrack, 3)
local goalFill = frame(goalTrack, "Fill", C.green)
goalFill.Size = UDim2.fromScale(0, 1)
round(goalFill, 3)

local dock = make("Frame", root, { Name = "Actions", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1) })
local gardenHint = label(dock, "GardenHint", "Aproxime-se de um canteiro para plantar.", 13, C.ink)
gardenHint.Size = UDim2.new(1, 0, 0, 24)
gardenHint.TextXAlignment = Enum.TextXAlignment.Center
local harvestButton = button(dock, "HarvestAll", "Colher tudo")
harvestButton.Position = UDim2.fromOffset(0, 28)
harvestButton.Size = UDim2.new(0.5, -4, 0, 50)
local sellButton = button(dock, "Sell", "Vender no mercado")
sellButton.Position = UDim2.new(0.5, 4, 0, 28)
sellButton.Size = UDim2.new(0.5, -4, 0, 50)
sellButton.BackgroundColor3 = C.gold
local locationHint = label(dock, "LocationHint", "Colha perto do seu lote • venda perto do mercado", 11, C.muted)
locationHint.Position = UDim2.fromOffset(0, 82)
locationHint.Size = UDim2.new(1, 0, 0, 18)
locationHint.TextXAlignment = Enum.TextXAlignment.Center

local panel = frame(root, "GardenMenu", C.paper)
panel.AnchorPoint = Vector2.new(0.5, 0)
panel.Visible = false
panel.Active = true
panel.SelectionGroup = true
panel.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
panel.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
panel.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
panel.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
round(panel, 18)
outline(panel, C.line, 2)
local panelTitle = label(panel, "Heading", "Seu jardim", 21, C.ink)
panelTitle.Font = Enum.Font.GothamBold
panelTitle.Position = UDim2.fromOffset(16, 9)
panelTitle.Size = UDim2.new(1, -76, 0, 30)
local closeButton = button(panel, "Close", "×")
closeButton.AnchorPoint = Vector2.new(1, 0)
closeButton.Position = UDim2.new(1, -12, 0, 8)
closeButton.Size = UDim2.fromOffset(50, 50)
closeButton.TextSize = 24
closeButton.BackgroundColor3 = C.lavender
local subtitle = label(panel, "Subtitle", "Plante. Colha. Faça seu jardim florescer.", 12, C.muted)
subtitle.Position = UDim2.fromOffset(16, 42)
subtitle.Size = UDim2.new(1, -80, 0, 20)

local tabBar = make("Frame", panel, { Name = "Tabs", BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 68), Size = UDim2.new(1, -24, 0, 50) })
local tabOrder = { "species", "upgrades", "collection" }
local tabNames = { species = "Espécies", upgrades = "Melhorias", collection = "Coleção" }
local pages = {}
for index, id in ipairs(tabOrder) do
	local tab = button(tabBar, id, tabNames[id])
	tab.Position = UDim2.new((index - 1) / 3, 0, 0, 0)
	tab.Size = UDim2.new(1 / 3, -4, 1, 0)
	tabs[id] = tab
	local page = make("ScrollingFrame", panel, {
		Name = id, BackgroundTransparency = 1, BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 128), Size = UDim2.new(1, -24, 1, -140),
		ScrollBarThickness = 5, ScrollBarImageColor3 = C.purple,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y, Active = true, Visible = id == currentTab,
	})
	make("UIPadding", page, { PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 9), PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 8) })
	make("UIListLayout", page, { Padding = UDim.new(0, 9), SortOrder = Enum.SortOrder.LayoutOrder })
	pages[id] = page
end

local toastCard = frame(root, "Toast", C.paper)
toastCard.AnchorPoint = Vector2.new(0.5, 1)
toastCard.Visible = false
toastCard.ZIndex = 20
round(toastCard, 14)
local toastStroke = outline(toastCard, C.green, 2)
local toastKind = label(toastCard, "Kind", "JARDIM", 11, C.green)
toastKind.Position = UDim2.fromOffset(14, 7)
toastKind.Size = UDim2.new(1, -28, 0, 16)
local toastText = label(toastCard, "Message", "", 15, C.ink)
toastText.Position = UDim2.fromOffset(14, 25)
toastText.Size = UDim2.new(1, -28, 0, 41)
toastText.TextWrapped = true
toastText.TextTruncate = Enum.TextTruncate.None
local effects = make("Frame", root, { Name = "HarvestEffects", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 15 })

local function displayNextToast()
	if not alive or toastBusy or #toastQueue == 0 then return end
	toastBusy = true
	local item = table.remove(toastQueue, 1)
	toastGeneration += 1
	local generation = toastGeneration
	local isError = item.kind == "error" or item.kind == "warning"
	local color = isError and C.error or (item.kind == "success" and C.green or C.purple)
	toastStroke.Color = color
	toastKind.TextColor3 = color
	toastKind.Text = isError and "ATENÇÃO" or (item.kind == "success" and "BOA COLHEITA!" or "SEU JARDIM")
	toastText.Text = item.message
	toastCard.Visible = true
	toastCard.Size = UDim2.fromOffset(toastWidth - 12, 72)
	tween(toastCard, 0.18, { Size = UDim2.fromOffset(toastWidth, 72) })
	task.delay(3.2, function()
		if not alive or generation ~= toastGeneration then return end
		toastCard.Visible = false
		toastBusy = false
		displayNextToast()
	end)
end

local function notify(message, kind)
	if not alive then return end
	-- Bound the queue even if a stream of server messages arrives.
	if #toastQueue >= 5 then table.remove(toastQueue, 1) end
	table.insert(toastQueue, { message = tostring(message), kind = kind or "info" })
	displayNextToast()
end

local function request(verb, id)
	if not snapshot then notify("Seu jardim está carregando. Aguarde um instante."); return end
	local key = verb .. ":" .. (id or "")
	local now = os.clock()
	if now - (requestTimes[key] or -math.huge) < 0.4 then return end
	requestTimes[key] = now
	-- Never submit a client price, value, mutation, ownership or position.
	Action:FireServer(verb, id)
end

local function styleAction(object, text, enabled, selected)
	object.Text = text
	object.BackgroundColor3 = selected and C.lavender or (enabled and C.mint or C.disabled)
	object.TextColor3 = selected and C.purple or (enabled and C.green or C.muted)
end

local function speciesCard(page, species, index, collection)
	local card = frame(page, species.id, C.white)
	card.Size = UDim2.new(1, 0, 0, 130)
	card.LayoutOrder = index
	round(card, 12)
	outline(card)
	local icon = crystal(card, colorOf(species), 40)
	icon.Position = UDim2.fromOffset(7, 14)
	local name = label(card, "Name", species.name, 16, C.ink)
	name.Font = Enum.Font.GothamBold
	name.Position = UDim2.fromOffset(52, 10)
	name.Size = UDim2.new(1, -62, 0, 23)
	local detail = label(card, "Detail", "", 12, C.muted)
	detail.Position = UDim2.fromOffset(52, 37)
	detail.Size = UDim2.new(1, -62, 0, 32)
	detail.TextWrapped = true
	detail.TextTruncate = Enum.TextTruncate.None
	local status = label(card, "Status", "", 12, C.purple)
	status.Position = UDim2.fromOffset(12, 79)
	status.Size = UDim2.new(0.52, -16, 0, 43)
	status.TextWrapped = true
	local actionButton
	if not collection then
		actionButton = button(card, "Choose", "Carregando…")
		actionButton.AnchorPoint = Vector2.new(1, 0)
		actionButton.Position = UDim2.new(1, -10, 0, 74)
		actionButton.Size = UDim2.new(0.48, -2, 0, 50)
		connect(actionButton.Activated, function()
			if not snapshot then request("select", species.id); return end
			if snapshot.unlocked and snapshot.unlocked[species.id] then
				if snapshot.selected ~= species.id then request("select", species.id) end
			elseif (snapshot.coins or 0) >= species.unlockCost then
				request("unlock", species.id)
			else
				notify("Faltam " .. number(species.unlockCost - (snapshot.coins or 0)) .. " moedas para liberar " .. species.name .. ".", "info")
			end
		end)
	else
		status.Size = UDim2.new(1, -24, 0, 43)
		card.Selectable = true
		card.Active = true
		local stroke = card:FindFirstChildOfClass("UIStroke")
		connect(card.SelectionGained, function() stroke.Color = C.purple; stroke.Thickness = 3 end)
		connect(card.SelectionLost, function() stroke.Color = C.line; stroke.Thickness = 1 end)
	end
	return { card = card, icon = icon, detail = detail, status = status, button = actionButton }
end

for index, species in ipairs(Config.species) do
	speciesRows[species.id] = speciesCard(pages.species, species, index, false)
	collectionRows[species.id] = speciesCard(pages.collection, species, index, true)
end

local upgradeNames = { backpack = "Mochila", soil = "Solo fértil" }
for index, id in ipairs({ "backpack", "soil" }) do
	local card = frame(pages.upgrades, id, C.white)
	card.LayoutOrder = index
	card.Size = UDim2.new(1, 0, 0, 156)
	round(card, 12)
	outline(card)
	local name = label(card, "Name", upgradeNames[id], 18, C.ink)
	name.Font = Enum.Font.GothamBold
	name.Position = UDim2.fromOffset(14, 10)
	name.Size = UDim2.new(1, -28, 0, 26)
	local detail = label(card, "Benefit", "", 14, C.muted)
	detail.Position = UDim2.fromOffset(14, 41)
	detail.Size = UDim2.new(1, -28, 0, 43)
	detail.TextWrapped = true
	detail.TextTruncate = Enum.TextTruncate.None
	local level = label(card, "Level", "", 12, C.purple)
	level.Position = UDim2.fromOffset(14, 94)
	level.Size = UDim2.new(0.42, -14, 0, 35)
	local buy = button(card, "Upgrade", "Carregando…")
	buy.AnchorPoint = Vector2.new(1, 0)
	buy.Position = UDim2.new(1, -12, 0, 93)
	buy.Size = UDim2.new(0.58, -12, 0, 50)
	upgradeRows[id] = { detail = detail, level = level, button = buy }
	connect(buy.Activated, function()
		if not snapshot then request("upgrade", id); return end
		local levelNow = (snapshot.upgrades or {})[id] or 0
		if levelNow >= #Config.upgrades[id] then notify("Esta melhoria já está no nível máximo."); return end
		local cost = (snapshot.nextCosts or {})[id]
		if type(cost) ~= "number" then notify("Aguardando o preço da melhoria."); return end
		if (snapshot.coins or 0) < cost then notify("Faltam " .. number(cost - (snapshot.coins or 0)) .. " moedas para melhorar."); return end
		request("upgrade", id)
	end)
end
local help = label(pages.upgrades, "Help", "Como jogar\nEscolha uma espécie e use o prompt de um canteiro vazio. Espere o cristal crescer, colha e leve a mochila ao mercado. O clima pode tornar sua colheita especial!", 14, C.muted)
help.Size = UDim2.new(1, 0, 0, 124)
help.LayoutOrder = 3
help.TextWrapped = true
help.TextTruncate = Enum.TextTruncate.None
local saveText = label(pages.upgrades, "SaveMode", "", 12, C.muted)
saveText.Size = UDim2.new(1, 0, 0, 40)
saveText.LayoutOrder = 4
saveText.TextWrapped = true

local function selectedSpecies()
	if snapshot then
		for _, species in ipairs(Config.species) do
			if species.id == snapshot.selected then return species end
		end
	end
	return nil
end

local function harvestAnimation(amount)
	local species = selectedSpecies()
	local color = species and colorOf(species) or C.mint
	bagPulse.Scale = 1.08
	tween(bagPulse, 0.32, { Scale = 1 })
	local total = label(effects, "HarvestCount", "+" .. number(amount) .. " colhido" .. (amount == 1 and "" or "s"), 19, C.green)
	total.Font = Enum.Font.GothamBold
	total.TextXAlignment = Enum.TextXAlignment.Center
	total.AnchorPoint = Vector2.new(0.5, 0.5)
	total.Position = UDim2.fromScale(0.5, 0.55)
	total.Size = UDim2.fromOffset(240, 32)
	tween(total, 0.85, { Position = UDim2.fromScale(0.5, 0.43), TextTransparency = 1 })
	for index = 1, math.min(amount + 3, 9) do
		local mote = crystal(effects, color, 16 + index % 3 * 4)
		mote.AnchorPoint = Vector2.new(0.5, 0.5)
		mote.Position = UDim2.fromScale(0.5 + (index - 5) * 0.016, 0.56)
		tween(mote, 0.65 + index * 0.025, { Position = UDim2.fromScale(0.5, 0.075), Size = UDim2.fromOffset(0, 0), Rotation = index * 30 })
		task.delay(1, function() mote:Destroy() end)
	end
	task.delay(1, function() total:Destroy() end)
end

local function refreshTimed()
	if not snapshot then return end
	local now = workspace:GetServerTimeNow()
	local ready, growing, nextReady = 0, 0, math.huge
	for _, bed in ipairs(snapshot.beds or {}) do
		if bed.speciesId and type(bed.readyAt) == "number" then
			if bed.readyAt <= now then ready += 1 else growing += 1; nextReady = math.min(nextReady, bed.readyAt - now) end
		end
	end
	local bagCount, capacity = snapshot.bagCount or 0, snapshot.capacity or Config.capacityBase
	local full = bagCount >= capacity
	styleAction(harvestButton, ready > 0 and ("Colher " .. ready .. " pronto" .. (ready == 1 and "" or "s")) or "Colher tudo", ready > 0 and not full, false)
	styleAction(sellButton, "Vender • " .. number(snapshot.bagValue) .. " moedas", bagCount > 0, false)
	if bagCount > 0 then sellButton.BackgroundColor3 = C.gold end
	if full then
		gardenHint.Text = "Mochila cheia! Leve sua colheita ao mercado."
	elseif ready > 0 then
		gardenHint.Text = ready .. " cristal" .. (ready == 1 and " pronto" or "is prontos") .. " no seu lote."
	elseif growing > 0 then
		gardenHint.Text = "Próximo cristal em " .. math.ceil(nextReady) .. "s • lote " .. tostring(snapshot.plotId or "—")
	else
		local species = selectedSpecies()
		gardenHint.Text = species and ("Plantar " .. species.name .. " • " .. number(species.cost) .. " moedas") or "Escolha uma espécie no menu."
	end
	local weather = snapshot.weather or {}
	local remaining = type(weather.endsAt) == "number" and math.max(0, math.ceil(weather.endsAt - now)) or 0
	weatherCaption.Text = "CLIMA • " .. remaining .. "s"
	weatherText.Text = (weather.name or "—") .. "\n×" .. tostring(weather.multiplier or 1):gsub("%.", ",")
end

local function refresh()
	if not snapshot then return end
	local coins = snapshot.coins or 0
	coinsText.Text = number(coins)
	bagText.Text = number(snapshot.bagCount) .. " / " .. number(snapshot.capacity)
	bagCaption.Text = "MOCHILA • " .. number(snapshot.bagValue) .. " moedas"
	local goal = snapshot.goal or {}
	goalText.Text = goal.text or "Plante seu primeiro cristal."
	local target, progress = tonumber(goal.target) or 0, tonumber(goal.progress) or 0
	goalCount.Text = number(progress) .. "/" .. number(target)
	goalFill.Size = UDim2.fromScale(target > 0 and math.clamp(progress / target, 0, 1) or 0, 1)
	for _, species in ipairs(Config.species) do
		local row = speciesRows[species.id]
		local unlocked = (snapshot.unlocked or {})[species.id] == true
		local selected = snapshot.selected == species.id
		row.detail.Text = number(species.cost) .. " plantar • " .. species.growSeconds .. "s • " .. number(species.value) .. " vender"
		row.status.Text = unlocked and (selected and "Para plantar agora" or "Disponível") or "Espécie bloqueada"
		styleAction(row.button, unlocked and (selected and "Selecionada" or "Selecionar") or ("Liberar • " .. number(species.unlockCost)), unlocked or coins >= species.unlockCost, selected)
		local collection = collectionRows[species.id]
		local count = (snapshot.collection or {})[species.id] or 0
		collection.detail.Text = "Valor base: " .. number(species.value) .. " moedas • " .. species.growSeconds .. "s"
		collection.status.Text = count > 0 and (number(count) .. " colhido" .. (count == 1 and "" or "s") .. " • descoberta!") or (unlocked and "Plante e colha para descobrir" or "Libere na loja para cultivar")
		collection.icon.Visible = count > 0
		collection.card.BackgroundColor3 = count > 0 and C.white or C.disabled
	end
	for id, row in pairs(upgradeRows) do
		local level = (snapshot.upgrades or {})[id] or 0
		local maximum = #Config.upgrades[id]
		local maxed = level >= maximum
		local cost = (snapshot.nextCosts or {})[id]
		row.level.Text = "Nível " .. level .. " / " .. maximum
		if id == "backpack" then
			row.detail.Text = "Capacidade: " .. number(snapshot.capacity) .. " cristais" .. (maxed and "." or (". Próximo nível: +" .. Config.capacityStep .. " espaços."))
		else
			row.detail.Text = "Cristais crescem mais rápido. A redução pode chegar a " .. math.floor(Config.maxSoilReduction * 100 + 0.5) .. "%."
		end
		local available = type(cost) == "number"
		styleAction(row.button, maxed and "Nível máximo" or (available and ("Melhorar • " .. number(cost)) or "Aguardando preço…"), not maxed and available and coins >= cost, maxed)
	end
	local saveMode = snapshot.saveMode == "cloud" and "na nuvem" or (snapshot.saveMode == "session" and "somente nesta sessão" or "aguardando")
	saveText.Text = "Salvamento: " .. saveMode .. " • Colhidos: " .. number(snapshot.harvested) .. " • Venda total: " .. number(snapshot.sold) .. " moedas"
	refreshTimed()
end

local function focusOrder()
	local order = { tabs.species, tabs.upgrades, tabs.collection, closeButton }
	if currentTab == "species" then
		for _, species in ipairs(Config.species) do table.insert(order, speciesRows[species.id].button) end
	elseif currentTab == "upgrades" then
		for _, id in ipairs({ "backpack", "soil" }) do table.insert(order, upgradeRows[id].button) end
	elseif currentTab == "collection" then
		for _, species in ipairs(Config.species) do table.insert(order, collectionRows[species.id].card) end
	end
	for index, object in ipairs(order) do
		object.NextSelectionUp = order[index - 1] or order[#order]
		object.NextSelectionDown = order[index + 1] or order[1]
		object.NextSelectionLeft = order[index - 1] or order[#order]
		object.NextSelectionRight = order[index + 1] or order[1]
	end
end

local function chooseTab(id)
	currentTab = id
	for _, tabId in ipairs(tabOrder) do
		pages[tabId].Visible = tabId == id
		styleAction(tabs[tabId], tabNames[tabId], true, tabId == id)
	end
	panelTitle.Text = id == "collection" and "Seu álbum de cristais" or (id == "upgrades" and "Cultive ainda mais" or "Escolha seu cristal")
	if snapshot then refresh() end
	focusOrder()
	if gamepad and panelOpen then GuiService.SelectedObject = tabs[id] end
end

local function setPanel(open)
	panelOpen = open
	panel.Visible = open
	if open then
		chooseTab(currentTab)
	elseif GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(panel) then
		GuiService.SelectedObject = gamepad and menuButton or nil
	end
end

for _, id in ipairs(tabOrder) do connect(tabs[id].Activated, function() chooseTab(id) end) end
connect(menuButton.Activated, function() setPanel(not panelOpen) end)
connect(closeButton.Activated, function() setPanel(false) end)
connect(harvestButton.Activated, function()
	if snapshot and (snapshot.bagCount or 0) >= (snapshot.capacity or Config.capacityBase) then
		notify("Sua mochila está cheia. Venda no mercado antes de colher."); return
	end
	request("harvestAll")
end)
connect(sellButton.Activated, function()
	if snapshot and (snapshot.bagCount or 0) == 0 then notify("Sua mochila está vazia. Colha um cristal primeiro."); return end
	request("sell")
end)

local function inputMode(inputType)
	gamepad = string.find(inputType.Name, "Gamepad", 1, true) ~= nil
	menuButton.Text = gamepad and "Menu [Y]" or (UserInputService.TouchEnabled and "Menu" or "Menu [M]")
	if gamepad and panelOpen then
		GuiService.SelectedObject = tabs[currentTab]
	elseif not gamepad and GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(screen) then
		GuiService.SelectedObject = nil
	end
end
connect(UserInputService.LastInputTypeChanged, inputMode)
inputMode(UserInputService:GetLastInputType())

-- Only menu keys are reserved. World prompts keep Roblox's E/touch/gamepad UI.
ContextActionService:BindAction("CrystalGardenMenu", function(_, state)
	if UserInputService:GetFocusedTextBox() then return Enum.ContextActionResult.Pass end
	if state == Enum.UserInputState.Begin then setPanel(not panelOpen) end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.M, Enum.KeyCode.ButtonY)
ContextActionService:BindAction("CrystalGardenClose", function(_, state)
	if not panelOpen or UserInputService:GetFocusedTextBox() then return Enum.ContextActionResult.Pass end
	if state == Enum.UserInputState.Begin then setPanel(false) end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.ButtonB)

menuButton.NextSelectionDown = harvestButton
harvestButton.NextSelectionUp = menuButton
harvestButton.NextSelectionRight = sellButton
sellButton.NextSelectionLeft = harvestButton
sellButton.NextSelectionUp = menuButton
connect(GuiService:GetPropertyChangedSignal("SelectedObject"), function()
	local selected = GuiService.SelectedObject
	local page = pages[currentTab]
	if not panelOpen or not selected or not selected:IsDescendantOf(page) then return end
	-- Explicitly scroll focused cards into view on D-pad navigation.
	local card = selected
	while card.Parent ~= page do card = card.Parent end
	local scale = uiScale.Scale
	local top = (card.AbsolutePosition.Y - page.AbsolutePosition.Y) / scale
	local bottom = top + card.AbsoluteSize.Y / scale
	local height = page.AbsoluteSize.Y / scale
	local y = page.CanvasPosition.Y
	if top < 0 then y += top - 3 elseif bottom > height then y += bottom - height + 6 else return end
	page.CanvasPosition = Vector2.new(0, math.max(0, y))
end)

local function resize()
	local size = safe.AbsoluteSize
	if size.X < 1 or size.Y < 1 then return end
	local scale = math.clamp(math.min(size.X / 390, size.Y / 620), 0.9, 1)
	uiScale.Scale = scale
	local width, height = size.X / scale, size.Y / scale
	root.Size = UDim2.fromOffset(width, height)
	compact = size.X < 600
	local margin = compact and 10 or 18
	local hudWidth = math.min(width - margin * 2, 680)
	hud.Position = UDim2.fromOffset(margin, 8)
	local short = height < 460
	hud.Size = UDim2.fromOffset(hudWidth, short and 116 or 174)
	title.Visible = not short
	titleMark.Visible = not short
	stats.Position = UDim2.fromOffset(0, short and 0 or 58)
	stats.Size = UDim2.new(1, short and -108 or 0, 0, 66)
	goalCard.Position = UDim2.fromOffset(0, short and 74 or 132)
	title.TextSize = compact and 14 or 16
	local touchBottom = UserInputService.TouchEnabled and 106 or 8
	-- On short landscape displays, keep the dock above the central bottom edge.
	if height < 470 then touchBottom = UserInputService.TouchEnabled and 26 or 8 end
	dock.Position = UDim2.new(0.5, 0, 1, -touchBottom)
	dock.Size = UDim2.fromOffset(math.min(width - margin * 2, 450), 100)
	-- A 390x260 safe area cannot fit the header and a usable scrolling menu.
	-- Give the open menu the full height; restore all HUD stats on close.
	local tinyMenu = panelOpen and height < 340
	hud.Visible = not tinyMenu
	local panelTop = tinyMenu and 8 or (short and 132 or 190)
	local panelHeight = math.max(150, math.min(520, height - panelTop - 10))
	panel.Position = UDim2.new(0.5, 0, 0, panelTop)
	panel.Size = UDim2.fromOffset(math.min(width - margin * 2, 580), panelHeight)
	-- Open menus temporarily occupy the dock area, keeping long lists scrollable.
	dock.Visible = not panelOpen
	toastWidth = math.min(width - margin * 2, 420)
	toastCard.Size = UDim2.fromOffset(toastWidth, 72)
	toastCard.Position = UDim2.new(0.5, 0, 1, -(touchBottom + (panelOpen and 12 or 106)))
end
connect(safe:GetPropertyChangedSignal("AbsoluteSize"), resize)
connect(panel:GetPropertyChangedSignal("Visible"), resize)
resize()
chooseTab("species")

-- Listener order is deliberate: the first sync response cannot be lost.
connect(State.OnClientEvent, function(value)
	if type(value) ~= "table" then return end
	local previous = snapshot
	snapshot = value
	refresh()
	if previous then
		local amount = (value.harvested or 0) - (previous.harvested or 0)
		if amount > 0 then harvestAnimation(amount) end
	end
end)
connect(Toast.OnClientEvent, function(message, kind) notify(message, kind) end)
Action:FireServer("sync")

-- Server time, not client wall time, drives growth and weather countdowns.
task.spawn(function()
	while alive do
		task.wait(0.25)
		if alive then refreshTimed() end
	end
end)
task.delay(10, function()
	if alive and not snapshot then
		goalText.Text = "Aguardando seu jardim…"
		notify("O jardim ainda está carregando. Aguarde a conexão com o servidor.", "info")
	end
end)
connect(script.Destroying, function()
	alive = false
	toastGeneration += 1
	ContextActionService:UnbindAction("CrystalGardenMenu")
	ContextActionService:UnbindAction("CrystalGardenClose")
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(screen) then GuiService.SelectedObject = nil end
	for _, connection in ipairs(connections) do connection:Disconnect() end
	screen:Destroy()
end)
