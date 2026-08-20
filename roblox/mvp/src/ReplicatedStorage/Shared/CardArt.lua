--!strict
-- Card faces, drawn in code.
--
-- One builder used by the belt offer, the card in the player's hand and the
-- slot display, so a card looks the same everywhere it appears. Rarity is
-- carried by a gradient and a frame rather than by a word, because a player
-- reading a belt at a glance sees colour long before they read text.
--
-- If `runtimeAssetId` is set on a card, its image is drawn in the art panel
-- and the gradient becomes its backdrop. Until then the gradient *is* the art,
-- and the card is complete without it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CardCatalog = require(ReplicatedStorage.Shared.CardCatalog)
local FarmCatalog = require(ReplicatedStorage.Shared.FarmCatalog)

local CardArt = {}

CardArt.WIDTH = 7
CardArt.HEIGHT = 10
CardArt.DEPTH = 0.4

--- Two-stop gradients per rarity, dark at the base so text stays readable.
local GRADIENTS = {
	Common    = { Color3.fromRGB(196, 202, 214), Color3.fromRGB(108, 116, 132) },
	Uncommon  = { Color3.fromRGB(140, 240, 158), Color3.fromRGB(38, 132, 74) },
	Rare      = { Color3.fromRGB(126, 198, 255), Color3.fromRGB(30, 88, 178) },
	Epic      = { Color3.fromRGB(206, 148, 255), Color3.fromRGB(96, 40, 168) },
	Legendary = { Color3.fromRGB(255, 222, 130), Color3.fromRGB(196, 130, 24) },
	Mythic    = { Color3.fromRGB(255, 154, 146), Color3.fromRGB(176, 38, 44) },
}

--- A distinct emblem per card, picked from the id so the same card always
--- draws the same glyph without needing a table entry per card.
local EMBLEMS = { "✦", "✧", "❖", "✤", "✵", "❂", "✹", "✶", "⬢", "◆", "▲", "✿" }

local function emblemFor(cardId: string): string
	local sum = 0
	for index = 1, #cardId do
		sum += string.byte(cardId, index)
	end
	return EMBLEMS[(sum % #EMBLEMS) + 1]
end

function CardArt.rarityColor(rarity: string): Color3
	local info = CardCatalog.Rarities[rarity] or CardCatalog.Rarities.Common
	return info.color
end

function CardArt.frameColor(rarity: string, mutationId: string?): Color3
	local mutation = FarmCatalog.MutationById[mutationId or "none"]
	if mutation and mutation.id ~= "none" then
		return Color3.fromRGB(mutation.color[1], mutation.color[2], mutation.color[3])
	end
	return CardArt.rarityColor(rarity)
end

--- Draw the face onto a SurfaceGui.
function CardArt.paint(surface: SurfaceGui, cardId: string, rarity: string, mutationId: string?)
	local card = CardCatalog.Cards[cardId]
	local rarityInfo = CardCatalog.Rarities[rarity] or CardCatalog.Rarities.Common
	local mutation = FarmCatalog.MutationById[mutationId or "none"]
	local isMutated = mutation ~= nil and mutation.id ~= "none"
	local accent = CardArt.frameColor(rarity, mutationId)
	local stops = GRADIENTS[rarity] or GRADIENTS.Common

	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(22, 24, 32)
	backdrop.BorderSizePixel = 0
	backdrop.Parent = surface

	-- The art panel. A gradient when there is no image, a backdrop when there is.
	local art = Instance.new("Frame")
	art.Name = "Art"
	art.Size = UDim2.new(1, -26, 0.58, 0)
	art.Position = UDim2.fromOffset(13, 13)
	art.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	art.BorderSizePixel = 0
	art.Parent = backdrop

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(stops[1], stops[2])
	gradient.Rotation = 68
	gradient.Parent = art

	local artCorner = Instance.new("UICorner")
	artCorner.CornerRadius = UDim.new(0, 10)
	artCorner.Parent = art

	if card and card.runtimeAssetId then
		local image = Instance.new("ImageLabel")
		image.Name = "Image"
		image.Size = UDim2.fromScale(1, 1)
		image.BackgroundTransparency = 1
		image.ScaleType = Enum.ScaleType.Crop
		image.Image = "rbxassetid://" .. tostring(card.runtimeAssetId)
		image.Parent = art
		local imageCorner = Instance.new("UICorner")
		imageCorner.CornerRadius = UDim.new(0, 10)
		imageCorner.Parent = image
	else
		-- No image: the emblem carries the card's identity.
		local emblem = Instance.new("TextLabel")
		emblem.Name = "Emblem"
		emblem.Size = UDim2.fromScale(1, 1)
		emblem.BackgroundTransparency = 1
		emblem.Text = emblemFor(cardId)
		emblem.TextColor3 = Color3.fromRGB(255, 255, 255)
		emblem.TextTransparency = 0.25
		emblem.TextScaled = true
		emblem.Font = Enum.Font.FredokaOne
		emblem.Parent = art

		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0.14, 0)
		padding.PaddingBottom = UDim.new(0.14, 0)
		padding.Parent = emblem
	end

	-- Rarity ribbon across the top of the art.
	local ribbon = Instance.new("Frame")
	ribbon.Name = "Ribbon"
	ribbon.Size = UDim2.new(1, -26, 0, 42)
	ribbon.Position = UDim2.fromOffset(13, 13)
	ribbon.BackgroundColor3 = accent
	ribbon.BorderSizePixel = 0
	ribbon.Parent = backdrop
	local ribbonCorner = Instance.new("UICorner")
	ribbonCorner.CornerRadius = UDim.new(0, 8)
	ribbonCorner.Parent = ribbon

	local ribbonText = Instance.new("TextLabel")
	ribbonText.Size = UDim2.fromScale(1, 1)
	ribbonText.BackgroundTransparency = 1
	ribbonText.Text = if isMutated
		then string.format("%s  x%.1f", string.upper(mutation.name), mutation.multiplier)
		else rarityInfo.label
	ribbonText.TextColor3 = Color3.fromRGB(20, 22, 30)
	ribbonText.TextScaled = true
	ribbonText.Font = Enum.Font.FredokaOne
	ribbonText.Parent = ribbon

	local name = Instance.new("TextLabel")
	name.Name = "CardName"
	name.Size = UDim2.new(1, -26, 0, 66)
	name.Position = UDim2.new(0, 13, 0.62, 6)
	name.BackgroundTransparency = 1
	name.Text = card and card.name or cardId
	name.TextColor3 = Color3.fromRGB(248, 250, 252)
	name.TextScaled = true
	name.Font = Enum.Font.FredokaOne
	name.Parent = backdrop

	local power = Instance.new("TextLabel")
	power.Name = "Power"
	power.Size = UDim2.new(1, -26, 0, 40)
	power.Position = UDim2.new(0, 13, 0.76, 4)
	power.BackgroundTransparency = 1
	power.Text = string.format("PODER %d", card and card.power or 0)
	power.TextColor3 = accent
	power.TextScaled = true
	power.Font = Enum.Font.FredokaOne
	power.Parent = backdrop

	local income = Instance.new("TextLabel")
	income.Name = "Income"
	income.Size = UDim2.new(1, -26, 0, 48)
	income.Position = UDim2.new(0, 13, 0.86, 0)
	income.BackgroundTransparency = 1
	income.Text = string.format("$%.1f/s", FarmCatalog.slotIncome(rarity, mutationId or "none", 1))
	income.TextColor3 = Color3.fromRGB(126, 240, 118)
	income.TextScaled = true
	income.Font = Enum.Font.FredokaOne
	income.Parent = backdrop
end

--- Build a standing card. Used on the belt, in the hand and on a slot.
function CardArt.build(cardId: string, rarity: string, mutationId: string?, scale: number?): Model
	local size = scale or 1
	local accent = CardArt.frameColor(rarity, mutationId)
	local mutation = FarmCatalog.MutationById[mutationId or "none"]
	local isMutated = mutation ~= nil and mutation.id ~= "none"

	local model = Instance.new("Model")
	model.Name = "Card_" .. cardId

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(CardArt.WIDTH * size, CardArt.HEIGHT * size, CardArt.DEPTH * size)
	body.Anchored = true
	body.CanCollide = false
	body.CastShadow = false
	body.Material = Enum.Material.SmoothPlastic
	body.Color = Color3.fromRGB(28, 30, 38)
	body.Parent = model

	local frame = Instance.new("Part")
	frame.Name = "Frame"
	frame.Size = Vector3.new((CardArt.WIDTH + 0.8) * size, (CardArt.HEIGHT + 0.8) * size, CardArt.DEPTH * 0.55 * size)
	frame.Anchored = true
	frame.CanCollide = false
	frame.CastShadow = false
	frame.Material = if isMutated then Enum.Material.Neon else Enum.Material.SmoothPlastic
	frame.Color = accent
	frame.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = body
	weld.Part1 = frame
	weld.Parent = body

	local surface = Instance.new("SurfaceGui")
	surface.Name = "Face"
	surface.Face = Enum.NormalId.Front
	surface.CanvasSize = Vector2.new(350, 500)
	surface.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	surface.LightInfluence = 0
	surface.Parent = body
	CardArt.paint(surface, cardId, rarity, mutationId)

	model.PrimaryPart = body
	model:SetAttribute("CardId", cardId)
	model:SetAttribute("Rarity", rarity)
	model:SetAttribute("Mutation", mutationId or "none")

	-- Position the frame behind the face once the model has a pivot.
	frame.CFrame = body.CFrame * CFrame.new(0, 0, CardArt.DEPTH * 0.5 * size)
	return model
end

return CardArt
