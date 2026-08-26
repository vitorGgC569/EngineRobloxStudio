--!strict
-- Shop panel (intermission): loadout picker, crate opening with card-flip reveal,
-- owned-skin list with equip buttons. Toggled with the SHOP button / B key.

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local SkinCatalog = require(Shared.SkinCatalog)
local Titles = require(Shared.Titles)
local Keybinds = require(Shared.Keybinds)

local Theme = require(script.Parent.Theme)
local MenuState = require(script.Parent.MenuState)

local Shop = {}

local function skinById(id: string)
	for _, skin in SkinCatalog do
		if skin.id == id then
			return skin
		end
	end
	return nil
end

local function rarityColor(rarityName: string): Color3
	for _, rarity in GameConfig.Economy.Rarities do
		if rarity.name == rarityName then
			return Color3.fromRGB(rarity.color[1], rarity.color[2], rarity.color[3])
		end
	end
	return Theme.Colors.Text
end

function Shop.start(remotes: any)
	local gui = Theme.screenGui("Shop", 4)
	local profile: any = nil

	-- Toggle button
	local toggle = Theme.button(gui, {
		Size = UDim2.new(0, 90, 0, 36),
		Position = UDim2.new(0, 12, 0, 64),
		Text = "SHOP  [B]",
		TextSize = 14,
	})

	local panel = Theme.frame(gui, {
		Size = UDim2.new(0, 620, 0, 420),
		Position = UDim2.new(0.5, -310, 0.5, -210),
		BackgroundTransparency = 0.05,
		Visible = false,
	})
	-- Releases the locked mouse while this panel is open.
	MenuState.track(panel)
	Theme.corner(panel, 14)
	Theme.gradient(panel, Theme.Colors.PanelLight, Theme.Colors.Panel, 90)
	Theme.stroke(panel, Color3.fromRGB(60, 64, 78), 1, 0.3)

	Theme.label(panel, {
		Size = UDim2.new(1, 0, 0, 34),
		Position = UDim2.new(0, 0, 0, 8),
		Text = "SHOP & LOADOUT",
		TextSize = 22,
		Font = Theme.FontDisplay,
	})
	local close = Theme.button(panel, {
		Size = UDim2.new(0, 32, 0, 32),
		Position = UDim2.new(1, -40, 0, 8),
		Text = "X",
	})

	-- Loadout picker
	Theme.label(panel, {
		Size = UDim2.new(0, 200, 0, 20),
		Position = UDim2.new(0, 16, 0, 48),
		Text = "PRIMARY WEAPON",
		TextSize = 13,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local loadoutButtons = {}
	for i, weaponId in { "AssaultRifle", "Shotgun", "SMG" } do
		local button = Theme.button(panel, {
			Size = UDim2.new(0, 120, 0, 34),
			Position = UDim2.new(0, 16 + (i - 1) * 128, 0, 70),
			Text = weaponId,
			TextSize = 14,
		})
		button.Activated:Connect(function()
			remotes.fire("SelectLoadout", { primary = weaponId })
		end)
		loadoutButtons[weaponId] = button
	end

	-- Crate section
	Theme.label(panel, {
		Size = UDim2.new(0, 300, 0, 20),
		Position = UDim2.new(0, 16, 0, 116),
		Text = ("CRATE — %d COINS"):format(GameConfig.Economy.CrateCostCoins),
		TextSize = 13,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local buyCrate = Theme.button(panel, {
		Size = UDim2.new(0, 150, 0, 36),
		Position = UDim2.new(0, 16, 0, 138),
		Text = "OPEN CRATE",
		TextSize = 15,
		BackgroundColor3 = Theme.Colors.Gold,
		TextColor3 = Theme.Colors.Bg,
	})
	buyCrate.Activated:Connect(function()
		remotes.fire("BuyCrate", { currency = "Coins" })
	end)
	-- Open with an earned key (from daily rewards / quests) instead of coins.
	local keyCrate = Theme.button(panel, {
		Size = UDim2.new(0, 170, 0, 36),
		Position = UDim2.new(0, 16, 0, 178),
		Text = "USE KEY (0)",
		TextSize = 14,
		BackgroundColor3 = Theme.Colors.Survivor,
		TextColor3 = Theme.Colors.Bg,
	})
	keyCrate.Activated:Connect(function()
		remotes.fire("BuyCrate", { currency = "Keys" })
	end)

	-- Card-flip result row
	local cards = {}
	for i = 1, 3 do
		local card = Theme.frame(panel, {
			Size = UDim2.new(0, 120, 0, 70),
			Position = UDim2.new(0, 200 + (i - 1) * 130, 0, 122),
			BackgroundColor3 = Theme.Colors.PanelLight,
			Visible = false,
		})
		Theme.corner(card, 10)
		local nameLabel = Theme.label(card, {
			Size = UDim2.new(1, -8, 0, 40),
			Position = UDim2.new(0, 4, 0, 4),
			Text = "?",
			TextSize = 14,
			TextWrapped = true,
		})
		local tag = Theme.label(card, {
			Size = UDim2.new(1, 0, 0, 18),
			Position = UDim2.new(0, 0, 1, -22),
			Text = "",
			TextSize = 11,
			TextColor3 = Theme.Colors.TextDim,
		})
		cards[i] = { frame = card, name = nameLabel, tag = tag }
	end

	-- Owned skins list
	Theme.label(panel, {
		Size = UDim2.new(0, 300, 0, 20),
		Position = UDim2.new(0, 16, 0, 222),
		Text = "YOUR SKINS",
		TextSize = 13,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local list = Instance.new("ScrollingFrame")
	list.Size = UDim2.new(1, -32, 0, 158)
	list.Position = UDim2.new(0, 16, 0, 244)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = panel
	local listLayout = Instance.new("UIGridLayout")
	listLayout.CellSize = UDim2.new(0, 136, 0, 44)
	listLayout.CellPadding = UDim2.new(0, 8, 0, 8)
	listLayout.Parent = list

	local function refreshSkins()
		for _, child in list:GetChildren() do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
		if profile == nil then
			return
		end
		for _, skin in SkinCatalog do
			if profile.ownedSkins and profile.ownedSkins[skin.id] then
				local equipped = profile.equipped and (profile.equipped[skin.slot] == skin.id)
				local button = Theme.button(list, {
					Size = UDim2.new(0, 136, 0, 44),
					Text = (equipped and "✓ " or "") .. skin.name,
					TextSize = 13,
					BackgroundColor3 = equipped and Theme.Colors.Survivor or Theme.Colors.PanelLight,
				})
				local stripe = Instance.new("Frame")
				stripe.Size = UDim2.new(0, 4, 1, 0)
				stripe.BorderSizePixel = 0
				stripe.BackgroundColor3 = rarityColor(skin.rarity)
				stripe.Parent = button
				button.Activated:Connect(function()
					remotes.fire("EquipSkin", { skinId = skin.id })
				end)
			end
		end
		-- Owned nametag titles, equippable inline.
		for _, title in Titles.All do
			if profile.ownedTitles and profile.ownedTitles[title.id] then
				local equipped = profile.equipped and profile.equipped.Title == title.id
				local button = Theme.button(list, {
					Size = UDim2.new(0, 136, 0, 44),
					Text = (equipped and "✓ " or "") .. "Title: " .. title.text,
					TextSize = 12,
					BackgroundColor3 = equipped and Theme.Colors.Gold or Theme.Colors.PanelLight,
					TextColor3 = equipped and Theme.Colors.Bg or Theme.Colors.Text,
				})
				local stripe = Instance.new("Frame")
				stripe.Size = UDim2.new(0, 4, 1, 0)
				stripe.BorderSizePixel = 0
				stripe.BackgroundColor3 = rarityColor(title.rarity)
				stripe.Parent = button
				button.Activated:Connect(function()
					remotes.fire("EquipTitle", { titleId = title.id })
				end)
			end
		end
	end

	local function refreshLoadout()
		if profile == nil then
			return
		end
		for weaponId, button in loadoutButtons do
			button.BackgroundColor3 = if profile.loadout and profile.loadout.primary == weaponId
				then Theme.Colors.Survivor
				else Theme.Colors.PanelLight
		end
	end

	remotes.on("ProfileSync", function(data)
		profile = data
		refreshSkins()
		refreshLoadout()
		local keys = data.crateKeys or 0
		keyCrate.Text = ("USE KEY (%d)"):format(keys)
		keyCrate.AutoButtonColor = keys > 0
		keyCrate.BackgroundColor3 = keys > 0 and Theme.Colors.Survivor or Theme.Colors.PanelLight
	end)

	remotes.on("CrateResult", function(result)
		local winner = skinById(result.winner)
		local decoys = result.decoys or {}
		for i, card in cards do
			card.frame.Visible = true
			if i == 1 and winner then
				card.name.Text = winner.name
				card.name.TextColor3 = rarityColor(winner.rarity)
				card.tag.Text = result.duplicate and "DUPLICATE (+coins)" or "WON — " .. winner.rarity
			else
				local decoy = skinById(decoys[i - 1] or "")
				card.name.Text = decoy and decoy.name or "?"
				card.name.TextColor3 = decoy and rarityColor(decoy.rarity) or Theme.Colors.TextDim
				card.tag.Text = "missed"
			end
		end
		task.delay(6, function()
			for _, card in cards do
				card.frame.Visible = false
			end
		end)
	end)

	local function setOpen(open: boolean)
		panel.Visible = open
	end
	toggle.Activated:Connect(function()
		setOpen(not panel.Visible)
	end)
	close.Activated:Connect(function()
		setOpen(false)
	end)
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and Keybinds.matches(Players.LocalPlayer, "shop", input.KeyCode) then
			setOpen(not panel.Visible)
		end
	end)

	return {}
end

return Shop
