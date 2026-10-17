--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Config = require(ReplicatedStorage.Shared.Config)
local Content = require(ReplicatedStorage.Shared.Content)
local Wire = require(ReplicatedStorage.Shared.Wire)

local Net = Forge.Net
local UI = Forge.UI
local Feel = Forge.Feel

Wire.install()
Feel.mount()

local player = Players.LocalPlayer
local screen = UI.mount("MeteorRushHUD", { ignoreInset = true })

local function corner(instance: GuiObject, radius: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 14)
	c.Parent = instance
end

local function stroke(instance: GuiObject, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(184, 143, 91)
	s.Thickness = 1.5
	s.Transparency = transparency or 0.25
	s.Parent = instance
end

local function label(parent: Instance, name: string, text: string, size: UDim2, position: UDim2, fontSize: number): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.Size = size
	t.Position = position
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextSize = fontSize
	t.Font = Enum.Font.GothamBold
	t.TextWrapped = true
	t.Parent = parent
	return t
end

local function button(parent: Instance, name: string, text: string, size: UDim2, position: UDim2): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = size
	b.Position = position
	b.BackgroundColor3 = Content.palette.panel
	b.BackgroundTransparency = 0.08
	b.BorderSizePixel = 0
	b.Text = text
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextSize = 18
	b.Font = Enum.Font.GothamBold
	b.AutoButtonColor = true
	b.Parent = parent
	corner(b, 14)
	stroke(b, 0.15)
	return b
end

local function formatNumber(value: number): string
	local n = math.max(0, value)
	if n >= 1e12 then return string.format("%.1fT", n / 1e12) end
	if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
	if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
	if n >= 1e3 then return string.format("%.1fK", n / 1e3) end
	return tostring(math.floor(n))
end

-- ================================ top HUD ====================================
local stats = Instance.new("Frame")
stats.Name = "Stats"
stats.Size = UDim2.fromOffset(250, 82)
stats.Position = UDim2.fromOffset(18, 18)
stats.BackgroundColor3 = Content.palette.panel
stats.BackgroundTransparency = 0.08
stats.BorderSizePixel = 0
stats.Parent = screen
corner(stats, 18)
stroke(stats)

local stardust = label(stats, "Stardust", "✦ 0 STARDUST", UDim2.new(1, -18, 0, 36), UDim2.fromOffset(12, 7), 22)
stardust.TextXAlignment = Enum.TextXAlignment.Left
stardust.TextColor3 = Content.palette.gold
local rate = label(stats, "Rate", "+0 / sec", UDim2.new(1, -18, 0, 27), UDim2.fromOffset(12, 44), 16)
rate.TextXAlignment = Enum.TextXAlignment.Left
rate.TextColor3 = Content.palette.accent

local objective = Instance.new("TextLabel")
objective.Name = "Objective"
objective.AnchorPoint = Vector2.new(0.5, 0)
objective.Size = UDim2.new(0.58, 0, 0, 52)
objective.Position = UDim2.new(0.5, 0, 0, 20)
objective.BackgroundColor3 = Content.palette.panel
objective.BackgroundTransparency = 0.12
objective.BorderSizePixel = 0
objective.Text = "☄ CAPTURE A METEOR • RETURN TO YOUR DECODER"
objective.TextColor3 = Color3.new(1, 1, 1)
objective.TextSize = 18
objective.Font = Enum.Font.GothamBold
objective.Parent = screen
corner(objective, 16)
stroke(objective, 0.35)

local collectionButton = button(screen, "Collection", "☄ COLLECTION", UDim2.fromOffset(175, 48), UDim2.new(1, -193, 0, 18))
collectionButton.AnchorPoint = Vector2.new(0, 0)
local upgradesButton = button(screen, "Upgrades", "⚡ UPGRADES", UDim2.fromOffset(175, 48), UDim2.new(1, -193, 0, 74))
local shopButton = button(screen, "Shop", "★ SHOP", UDim2.fromOffset(175, 48), UDim2.new(1, -193, 0, 130))
shopButton.Visible = Config.monetization.doubleStardustPassId > 0
	or Config.monetization.extraVaultPassId > 0
	or Config.monetization.stardustPackProductId > 0

-- ================================ toast =====================================
local toast = Instance.new("TextLabel")
toast.Name = "Toast"
toast.AnchorPoint = Vector2.new(0.5, 1)
toast.Size = UDim2.new(0.54, 0, 0, 54)
toast.Position = UDim2.new(0.5, 0, 1, -28)
toast.BackgroundColor3 = Content.palette.panel
toast.BackgroundTransparency = 1
toast.TextTransparency = 1
toast.TextColor3 = Color3.new(1, 1, 1)
toast.TextSize = 19
toast.Font = Enum.Font.GothamBold
toast.TextWrapped = true
toast.BorderSizePixel = 0
toast.Parent = screen
corner(toast, 16)
local toastSerial = 0

local function showToast(text: string, kind: string?)
	toastSerial += 1
	local serial = toastSerial
	toast.Text = text
	toast.BackgroundColor3 = if kind == "warn" then Content.palette.danger elseif kind == "good" then Color3.fromRGB(39, 135, 95) else Content.palette.panel
	TweenService:Create(toast, TweenInfo.new(0.14), { BackgroundTransparency = 0.08, TextTransparency = 0 }):Play()
	task.delay(2.6, function()
		if serial ~= toastSerial then return end
		TweenService:Create(toast, TweenInfo.new(0.22), { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
	end)
end

-- ================================ modal =====================================
local shade = Instance.new("Frame")
shade.Name = "Shade"
shade.Size = UDim2.fromScale(1, 1)
shade.BackgroundColor3 = Color3.new(0, 0, 0)
shade.BackgroundTransparency = 0.45
shade.BorderSizePixel = 0
shade.Visible = false
shade.ZIndex = 20
shade.Parent = screen

local modal = Instance.new("Frame")
modal.Name = "Modal"
modal.AnchorPoint = Vector2.new(0.5, 0.5)
modal.Size = UDim2.new(0.78, 0, 0.72, 0)
modal.Position = UDim2.fromScale(0.5, 0.52)
modal.BackgroundColor3 = Content.palette.panel
modal.BorderSizePixel = 0
modal.ZIndex = 21
modal.Parent = shade
corner(modal, 22)
stroke(modal, 0.05)

local modalTitle = label(modal, "Title", "COLLECTION", UDim2.new(1, -100, 0, 52), UDim2.fromOffset(20, 10), 27)
modalTitle.ZIndex = 22
modalTitle.TextXAlignment = Enum.TextXAlignment.Left
local close = button(modal, "Close", "×", UDim2.fromOffset(48, 44), UDim2.new(1, -62, 0, 12))
close.ZIndex = 22

local scroll = Instance.new("ScrollingFrame")
scroll.Name = "Content"
scroll.Size = UDim2.new(1, -30, 1, -82)
scroll.Position = UDim2.fromOffset(15, 70)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 5
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.fromOffset(0, 0)
scroll.ZIndex = 22
scroll.Parent = modal

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 10)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = scroll

local padding = Instance.new("UIPadding")
padding.PaddingLeft = UDim.new(0, 3)
padding.PaddingRight = UDim.new(0, 3)
padding.PaddingBottom = UDim.new(0, 15)
padding.Parent = scroll

local latestState: any = nil

local function clearModal()
	for _, child in scroll:GetChildren() do
		if child ~= layout and child ~= padding then child:Destroy() end
	end
end

local function row(titleText: string, subtitleText: string, color: Color3?): Frame
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, -8, 0, 72)
	frame.BackgroundColor3 = color or Color3.fromRGB(66, 56, 44)
	frame.BackgroundTransparency = 0.06
	frame.BorderSizePixel = 0
	frame.ZIndex = 23
	frame.Parent = scroll
	corner(frame, 14)

	local title = label(frame, "Name", titleText, UDim2.new(0.65, -12, 0, 28), UDim2.fromOffset(14, 9), 19)
	title.ZIndex = 24
	title.TextXAlignment = Enum.TextXAlignment.Left
	local sub = label(frame, "Sub", subtitleText, UDim2.new(0.65, -12, 0, 25), UDim2.fromOffset(14, 38), 14)
	sub.ZIndex = 24
	sub.TextColor3 = Color3.fromRGB(221, 205, 171)
	sub.TextXAlignment = Enum.TextXAlignment.Left
	return frame
end

local function fetchState(): any
	local ok, result = pcall(function()
		return Net.request("state", {})
	end)
	if ok and type(result) == "table" then
		latestState = result
		return result
	end
	return latestState or { specimens = {}, upgrades = {}, costs = {} }
end

local function renderCollection()
	shade.Visible = true
	modalTitle.Text = "☄ SPECIMEN COLLECTION"
	clearModal()
	pcall(function() Net.request("collectionSeen", {}) end)
	local state = fetchState()
	local specimens = state.specimens or {}
	if #specimens == 0 then
		local empty = row("No specimens yet", "Capture a meteor and bring it to your Decoder.", Color3.fromRGB(76, 66, 50))
		empty.Size = UDim2.new(1, -8, 0, 88)
		return
	end
	for _, specimen in specimens do
		local rarity = Content.rarity(tonumber(specimen.rarity) or 1)
		local mutation = tostring(specimen.mutation or "")
		local suffix = if mutation ~= "" then " • " .. string.upper(mutation) else ""
		local frame = row(
			tostring(specimen.name) .. suffix,
			string.format("%s • +%s Stardust/sec", tostring(specimen.rarityName), formatNumber(tonumber(specimen.income) or 0)),
			rarity.color
		)
		frame.BackgroundTransparency = 0.68
	end
end

local function renderUpgrades()
	shade.Visible = true
	modalTitle.Text = "⚡ LAB UPGRADES"
	clearModal()
	local state = fetchState()
	for _, id in { "speed", "vault", "reactor" } do
		local spec = Content.upgrades[id]
		local level = tonumber((state.upgrades or {})[id]) or 0
		local cost = tonumber((state.costs or {})[id]) or 0
		local frame = row(
			spec.label .. "  •  LV." .. level,
			if level >= spec.max then "MAX LEVEL" else ("Next: " .. formatNumber(cost) .. " Stardust"),
			if id == "speed" then Color3.fromRGB(176, 112, 58) elseif id == "vault" then Color3.fromRGB(121, 96, 66) else Color3.fromRGB(94, 123, 74)
		)
		local buy = button(frame, "Buy", if level >= spec.max then "MAX" else "BUY", UDim2.fromOffset(118, 42), UDim2.new(1, -132, 0.5, -21))
		buy.ZIndex = 24
		buy.Active = level < spec.max
		buy.AutoButtonColor = level < spec.max
		buy.Activated:Connect(function()
			local ok, result = pcall(function()
				return Net.request("buyUpgrade", { id = id })
			end)
			if not ok or not result or result.ok ~= true then
				showToast(if result and result.reason then result.reason else "Upgrade failed.", "warn")
			else
				showToast(spec.label .. " upgraded!", "good")
			end
			task.wait(0.05)
			renderUpgrades()
		end)
	end

	local help = row("Why only three upgrades?", "Speed gets you to drops. Vault lets you keep more specimens. Reactor multiplies passive income.")
	help.Size = UDim2.new(1, -8, 0, 88)
end

local function renderShop()
	shade.Visible = true
	modalTitle.Text = "★ LAB SHOP"
	clearModal()

	local offers = {
		{ id = "doubleStardust", enabled = Config.monetization.doubleStardustPassId > 0,
			title = "2x Stardust", sub = "Permanent: doubles specimen passive income." },
		{ id = "extraVault", enabled = Config.monetization.extraVaultPassId > 0,
			title = "+4 Vault Slots", sub = "Permanent: keep four more decoded specimens." },
		{ id = "stardustPack", enabled = Config.monetization.stardustPackProductId > 0,
			title = "1,500 Stardust", sub = "One-time developer product. No random reward." },
	}
	for _, offer in offers do
		if offer.enabled then
			local frame = row(offer.title, offer.sub, Color3.fromRGB(83, 67, 49))
			local buy = button(frame, "Buy", "VIEW", UDim2.fromOffset(118, 42), UDim2.new(1, -132, 0.5, -21))
			buy.ZIndex = 24
			buy.Activated:Connect(function()
				local ok, result = pcall(function()
					return Net.request("promptPurchase", { id = offer.id })
				end)
				if not ok or not result or result.ok ~= true then
					showToast(if result and result.reason then result.reason else "Purchase prompt unavailable.", "warn")
				end
			end)
		end
	end

	local note = row("No paid RNG", "Purchases improve convenience or grant fixed currency. Meteor rarity remains server-rolled gameplay.")
	note.Size = UDim2.new(1, -8, 0, 88)
end

collectionButton.Activated:Connect(renderCollection)
upgradesButton.Activated:Connect(renderUpgrades)
shopButton.Activated:Connect(renderShop)
close.Activated:Connect(function() shade.Visible = false end)

-- ================================ reveal ====================================
local reveal = Instance.new("Frame")
reveal.Name = "Reveal"
reveal.AnchorPoint = Vector2.new(0.5, 0.5)
reveal.Size = UDim2.fromOffset(420, 245)
reveal.Position = UDim2.fromScale(0.5, 0.5)
reveal.BackgroundColor3 = Content.palette.panel
reveal.BackgroundTransparency = 1
reveal.BorderSizePixel = 0
reveal.Visible = false
reveal.ZIndex = 40
reveal.Parent = screen
corner(reveal, 24)

local revealRarity = label(reveal, "Rarity", "RARE", UDim2.new(1, -30, 0, 36), UDim2.fromOffset(15, 24), 22)
revealRarity.ZIndex = 41
local revealName = label(reveal, "Name", "ORBIT OWL", UDim2.new(1, -30, 0, 70), UDim2.fromOffset(15, 67), 35)
revealName.ZIndex = 41
local revealIncome = label(reveal, "Income", "+0 Stardust/sec", UDim2.new(1, -30, 0, 38), UDim2.fromOffset(15, 151), 21)
revealIncome.ZIndex = 41
revealIncome.TextColor3 = Content.palette.accent
local revealMutation = label(reveal, "Mutation", "", UDim2.new(1, -30, 0, 30), UDim2.fromOffset(15, 194), 17)
revealMutation.ZIndex = 41

local revealSerial = 0
local function showReveal(payload: any)
	revealSerial += 1
	local serial = revealSerial
	reveal.Visible = true
	reveal.BackgroundColor3 = payload.color or Content.palette.panel
	revealRarity.Text = string.upper(tostring(payload.rarityName or "UNKNOWN"))
	revealName.Text = string.upper(tostring(payload.name or "SPECIMEN"))
	revealIncome.Text = "+" .. formatNumber(tonumber(payload.income) or 0) .. " STARDUST / SEC"
	local mutation = tostring(payload.mutation or "")
	revealMutation.Text = if mutation ~= "" then "✦ " .. string.upper(mutation) .. " MUTATION ✦" else ""
	revealMutation.TextColor3 = if mutation == "void" then Color3.fromRGB(211, 126, 126) else Content.palette.cream
	reveal.BackgroundTransparency = 0.12
	reveal.Position = UDim2.fromScale(0.5, 0.54)
	TweenService:Create(reveal, TweenInfo.new(0.22, Enum.EasingStyle.Back), {
		Position = UDim2.fromScale(0.5, 0.5),
	}):Play()
	task.delay(2.4, function()
		if serial ~= revealSerial then return end
		TweenService:Create(reveal, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
		task.wait(0.22)
		if serial == revealSerial then reveal.Visible = false end
	end)
end

-- ================================ signals ===================================
local function updateHot()
	local dust = tonumber(player:GetAttribute("Stardust")) or 0
	local perSecond = tonumber(player:GetAttribute("StardustPerSecond")) or 0
	stardust.Text = "✦ " .. formatNumber(dust) .. " STARDUST"
	rate.Text = "+" .. formatNumber(perSecond) .. " / sec"
	if player:GetAttribute("CarryingMeteor") == true then
		local meteorName = tostring(player:GetAttribute("CarriedMeteorName") or "Meteor")
		local meteorRarity = tonumber(player:GetAttribute("CarriedMeteorRarity")) or 1
		local rarity = Content.rarity(meteorRarity)
		objective.Text = string.upper("☄ " .. rarity.name .. " " .. meteorName .. " • RETURN TO YOUR DECODER")
		objective.TextColor3 = rarity.color
	else
		objective.Text = "☄ SEARCH THE FIELD • CLAIM A METEOR • GET IT HOME"
		objective.TextColor3 = Content.palette.cream
	end
end

for _, attribute in { "Stardust", "StardustPerSecond", "CarryingMeteor", "CarriedMeteorName", "CarriedMeteorRarity" } do
	player:GetAttributeChangedSignal(attribute):Connect(updateHot)
end

Net.on("State", function(payload)
	latestState = payload
	updateHot()
end)

Net.on("Notify", function(payload)
	showToast(tostring(payload.text or ""), tostring(payload.kind or "info"))
end)

Net.on("MeteorClaimed", function(payload)
	showToast(
		string.format("%s %s secured • %.1fx decode bonus", string.upper(tostring(payload.rarityName or "Common")), tostring(payload.name or "Meteor"), tonumber(payload.bonus) or 1),
		"good"
	)
	updateHot()
end)

Net.on("MeteorSpawned", function(payload)
	showToast(
		string.format("★ %s %s just hit the field!", string.upper(tostring(payload.rarityName or "Rare")), tostring(payload.name or "Meteor")),
		"good"
	)
end)

Net.on("Decoded", function(payload)
	showReveal(payload)
	task.delay(0.05, function()
		latestState = fetchState()
	end)
end)

Net.on("Announce", function(payload)
	local mutation = tostring(payload.mutation or "")
	showToast(
		string.format("%s decoded %s %s%s!", tostring(payload.who), tostring(payload.rarity), tostring(payload.name), if mutation ~= "" then " [" .. mutation .. "]" else ""),
		"good"
	)
end)

Net.on("Shower", function(payload)
	local seconds = tonumber(payload.seconds) or 0
	if seconds > 0 then
		task.spawn(function()
			for remaining = seconds, 1, -1 do
				objective.Text = "☄ METEOR SHOWER IN " .. remaining .. "s ☄"
				objective.TextColor3 = Content.palette.gold
				task.wait(1)
			end
		end)
	else
		showToast("METEOR SHOWER! The crater is full of cores.", "good")
		updateHot()
	end
end)

task.spawn(function()
	task.wait(1)
	latestState = fetchState()
	updateHot()
end)

print("[Meteor Rush] client ready")
