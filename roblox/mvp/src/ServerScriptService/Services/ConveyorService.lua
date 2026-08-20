--!strict
-- Card dispensing: one click, one card, riding a real belt.
--
-- The card is a physical object that travels the conveyor and is collected at
-- the far end. That matters for more than looks: the delay between pulling and
-- receiving is where the anticipation lives, and it gives the rarity reveal
-- somewhere to happen.
--
-- Server-authoritative throughout. The client asks to pull; the server decides
-- whether it may, what it gets, and when it lands.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CardCatalog = require(ReplicatedStorage.Shared.CardCatalog)
local FarmCatalog = require(ReplicatedStorage.Shared.FarmCatalog)
local LuckCatalog = require(ReplicatedStorage.Shared.LuckCatalog)
local WorldKit = require(ServerScriptService.WorldKit)

local Build = WorldKit.Build
local Palette = WorldKit.Palette

local ConveyorService = {}
ConveyorService.__index = ConveyorService

--- Minimum gap between pulls, so a click-spammer cannot flood the belt.
local PULL_COOLDOWN = 0.45
local TRAVEL_TIMEOUT = 9

export type Pull = {
	ok: boolean,
	reason: string?,
	cardId: string?,
	rarity: string?,
	luck: number?,
	cooldownRemaining: number?,
}

function ConveyorService.new(theme)
	local self = setmetatable({}, ConveyorService)
	self.theme = theme
	self.byPlot = {}
	self.lastPullAt = {}
	--- One live offer per farm; spawning replaces it.
	self.activeOffer = {}
	self.random = Random.new()
	return self
end

--- Register a plot's belt so pulls can be routed to it.
function ConveyorService:register(plotName: string, conveyor, luckLevel: number)
	self.byPlot[plotName] = { conveyor = conveyor, luckLevel = luckLevel or 1 }
	conveyor:setSpeed(LuckCatalog.beltSpeedFor(luckLevel or 1))
end

function ConveyorService:luckLevel(plotName: string): number
	local entry = self.byPlot[plotName]
	return entry and entry.luckLevel or 1
end

function ConveyorService:setLuckLevel(plotName: string, level: number)
	local entry = self.byPlot[plotName]
	if entry == nil then
		return
	end
	entry.luckLevel = math.clamp(level, 1, LuckCatalog.MaxLuckLevel)
	entry.conveyor:setSpeed(LuckCatalog.beltSpeedFor(entry.luckLevel))
end

--- Pick a card of the rolled rarity, preferring ones the player lacks.
local function chooseCard(rarity: string, owned: { [string]: boolean }): string?
	local matching, missing = {}, {}
	for id, card in pairs(CardCatalog.Cards) do
		if card.rarity == rarity then
			table.insert(matching, id)
			if not owned[id] then
				table.insert(missing, id)
			end
		end
	end
	local pool = if #missing > 0 then missing else matching
	if #pool == 0 then
		return nil
	end
	table.sort(pool)
	return pool[math.random(1, #pool)]
end

--- The physical card that rides the belt.
---
--- Everything a player needs to judge the offer is written on it: name,
--- rarity, mutation and what it would earn. Deciding whether to take a card
--- should not require opening a menu.
function ConveyorService:buildCard(cardId: string, rarity: string, mutationId: string?): Model
	local model = Instance.new("Model")
	model.Name = "Card_" .. cardId

	local rarityInfo = CardCatalog.Rarities[rarity] or CardCatalog.Rarities.Common
	local card = CardCatalog.Cards[cardId]
	local mutation = FarmCatalog.MutationById[mutationId or "none"]
	local multiplier = FarmCatalog.mutationMultiplier(mutationId or "none")
	local income = FarmCatalog.slotIncome(rarity, mutationId or "none", 1)

	-- Stands upright, facing the player. A card lying flat on a belt shows its
	-- edge and hides the art, which is the one thing a collector wants to see
	-- before deciding whether to take it.
	local CARD_WIDTH, CARD_HEIGHT, CARD_DEPTH = 7, 10, 0.5

	local frameColor = if mutation and mutation.id ~= "none"
		then Color3.fromRGB(mutation.color[1], mutation.color[2], mutation.color[3])
		else rarityInfo.color

	local body = Build.part(model, "Body", Vector3.new(CARD_WIDTH, CARD_HEIGHT, CARD_DEPTH), Vector3.new(0, 0, 0), Palette.get(self.theme, "white"), { castShadow = false })
	body.Name = "Body"

	local border = Build.part(model, "Frame", Vector3.new(CARD_WIDTH + 0.9, CARD_HEIGHT + 0.9, CARD_DEPTH * 0.6), Vector3.new(0, 0, -0.12), { color = frameColor, material = Enum.Material.Neon }, { canCollide = false, castShadow = false })
	border.Transparency = 0.05

	-- The art panel: a SurfaceGui on the card's face, so the card reads as a
	-- card rather than as a floating label above a brick.
	local surface = Instance.new("SurfaceGui")
	surface.Name = "Art"
	surface.Face = Enum.NormalId.Front
	surface.CanvasSize = Vector2.new(350, 500)
	surface.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	surface.LightInfluence = 0
	surface.AlwaysOnTop = false
	surface.Parent = body

	local backdrop = Instance.new("Frame")
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
	backdrop.BorderSizePixel = 0
	backdrop.Parent = surface

	local artwork = Instance.new("ImageLabel")
	artwork.Size = UDim2.new(1, -24, 0.62, 0)
	artwork.Position = UDim2.fromOffset(12, 12)
	artwork.BackgroundColor3 = frameColor
	artwork.BackgroundTransparency = 0.55
	artwork.BorderSizePixel = 0
	artwork.ScaleType = Enum.ScaleType.Crop
	if card and card.runtimeAssetId then
		artwork.Image = "rbxassetid://" .. tostring(card.runtimeAssetId)
	end
	artwork.Parent = surface

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, -24, 0, 62)
	nameLabel.Position = UDim2.new(0, 12, 0.64, 8)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = card and card.name or cardId
	nameLabel.TextColor3 = Color3.fromRGB(248, 250, 252)
	nameLabel.TextScaled = true
	nameLabel.Font = Enum.Font.FredokaOne
	nameLabel.Parent = surface

	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.Size = UDim2.new(1, -24, 0, 44)
	rarityLabel.Position = UDim2.new(0, 12, 0.78, 4)
	rarityLabel.BackgroundTransparency = 1
	rarityLabel.Text = if mutation and mutation.id ~= "none"
		then string.format("%s  x%.1f", string.upper(mutation.name), multiplier)
		else rarityInfo.label
	rarityLabel.TextColor3 = frameColor
	rarityLabel.TextScaled = true
	rarityLabel.Font = Enum.Font.FredokaOne
	rarityLabel.Parent = surface

	local incomeLabel = Instance.new("TextLabel")
	incomeLabel.Size = UDim2.new(1, -24, 0, 46)
	incomeLabel.Position = UDim2.new(0, 12, 0.87, 0)
	incomeLabel.BackgroundTransparency = 1
	incomeLabel.Text = string.format("$%.1f/s", income)
	incomeLabel.TextColor3 = Color3.fromRGB(126, 240, 118)
	incomeLabel.TextScaled = true
	incomeLabel.Font = Enum.Font.FredokaOne
	incomeLabel.Parent = surface

	Build.light(border, frameColor, if mutation and mutation.id ~= "none" then 4 else 2, if mutation and mutation.id ~= "none" then 24 else 15)

	model.PrimaryPart = body
	return model
end

--- Spawn a card onto the belt for inspection.
---
--- The card is *offered*, not given. It rides the belt carrying its own prompt,
--- and the player decides whether to buy it before it reaches the end. That
--- decision -- take this one, or spawn another and hope for better -- is the
--- moment the whole loop is built around; granting the card automatically
--- removes it entirely.
function ConveyorService:spawnOffer(
	player: Player,
	plotName: string,
	ownedCards: { [string]: boolean },
	mutationId: string,
	onExpired: (string, string) -> ()
)
	local entry = self.byPlot[plotName]
	if entry == nil then
		return { ok = false, reason = "no_conveyor_for_plot" }
	end

	local now = os.clock()
	local last = self.lastPullAt[player.UserId] or 0
	if now - last < PULL_COOLDOWN then
		return { ok = false, reason = "cooldown", cooldownRemaining = PULL_COOLDOWN - (now - last) }
	end
	self.lastPullAt[player.UserId] = now

	local luck = LuckCatalog.luckFor(entry.luckLevel)
	local rarity = LuckCatalog.roll(luck, self.random)
	local cardId = chooseCard(rarity, ownedCards)
	if cardId == nil then
		return { ok = false, reason = "no_card_for_rarity", rarity = rarity }
	end

	-- One offer at a time. Spawning again discards whatever was on the belt,
	-- which is what makes "spawn until something better shows up" a decision
	-- with a cost rather than a queue that piles up.
	local previous = self.activeOffer[plotName]
	if previous and previous.model.Parent ~= nil then
		previous.model:SetAttribute("Discarded", true)
		previous.model:Destroy()
		if previous.onExpired then
			previous.onExpired(previous.cardId, previous.rarity, "replaced")
		end
	end

	local model = self:buildCard(cardId, rarity, mutationId)
	model:SetAttribute("CardId", cardId)
	model:SetAttribute("Rarity", rarity)
	model:SetAttribute("Mutation", mutationId)
	model:SetAttribute("OwnerUserId", player.UserId)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BuyCardPrompt"
	prompt.ActionText = "Take card"
	prompt.ObjectText = string.format("%s (%s)", cardId, rarity)
	prompt.HoldDuration = 0
	-- The card sits at the belt's midpoint while the player stands at the
	-- dispenser: measured 29.4 studs apart, so a 26-stud reach made every
	-- offer visible and untakeable.
	prompt.MaxActivationDistance = 42
	prompt.RequiresLineOfSight = false
	-- Roblox shows one prompt per key by default, so the dispenser standing a
	-- few studs closer silently suppressed this one: the offer was visible,
	-- in range and impossible to take. The offer must always be reachable, and
	-- it takes a different key so the two never compete.
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Parent = model.PrimaryPart

	-- Presented at the middle of the belt, standing up and facing the player.
	--
	-- Not carried: measured, a ProximityPrompt on a fast unanchored part never
	-- fires Triggered, so a card riding the belt could be seen and never taken.
	-- It is placed instead, while the belt's treads keep running behind it.
	local middle = entry.conveyor.spawnPoint + entry.conveyor.direction * (entry.conveyor.spec.length / 2) + Vector3.new(0, 6.5, 0)
	local facing = Vector3.new(-entry.conveyor.direction.Z, 0, entry.conveyor.direction.X)
	model:PivotTo(CFrame.lookAt(middle, middle + facing))
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.AssemblyLinearVelocity = Vector3.zero
		end
	end
	model.Parent = entry.conveyor.model

	self.activeOffer[plotName] = {
		model = model,
		cardId = cardId,
		rarity = rarity,
		mutation = mutationId,
		onExpired = onExpired,
	}

	return {
		ok = true,
		cardId = cardId,
		rarity = rarity,
		mutation = mutationId,
		luck = luck,
		model = model,
		prompt = prompt,
	}
end

--- Remove the offer once it has been taken.
function ConveyorService:clearOffer(plotName: string)
	local offer = self.activeOffer[plotName]
	if offer then
		self.activeOffer[plotName] = nil
	end
end

--- One pull. Returns what happened; the caller decides how to present it.
function ConveyorService:pull(player: Player, plotName: string, ownedCards: { [string]: boolean }, onLanded: (string, string) -> ()): Pull
	local entry = self.byPlot[plotName]
	if entry == nil then
		return { ok = false, reason = "no_conveyor_for_plot" }
	end

	local now = os.clock()
	local last = self.lastPullAt[player.UserId] or 0
	if now - last < PULL_COOLDOWN then
		return { ok = false, reason = "cooldown", cooldownRemaining = PULL_COOLDOWN - (now - last) }
	end
	self.lastPullAt[player.UserId] = now

	local luck = LuckCatalog.luckFor(entry.luckLevel)
	local rarity = LuckCatalog.roll(luck, self.random)
	local cardId = chooseCard(rarity, ownedCards)
	if cardId == nil then
		return { ok = false, reason = "no_card_for_rarity", rarity = rarity }
	end

	local model = self:buildCard(cardId, rarity)
	entry.conveyor:place(model)
	-- Award on arrival, not on click: the belt ride is part of the transaction.
	entry.conveyor:collect(model, TRAVEL_TIMEOUT, function(_reachedEnd)
		onLanded(cardId, rarity)
	end)

	return { ok = true, cardId = cardId, rarity = rarity, luck = luck }
end

--- Buy the next luck tier. Returns cost and the new level, or why not.
function ConveyorService:upgradeLuck(plotName: string, currency: number)
	local level = self:luckLevel(plotName)
	local next = LuckCatalog.nextUpgrade(level)
	if next == nil then
		return { ok = false, reason = "max_level", level = level }
	end
	if currency < next.price then
		return { ok = false, reason = "insufficient_funds", price = next.price, level = level }
	end
	self:setLuckLevel(plotName, next.level)
	return {
		ok = true,
		level = next.level,
		price = next.price,
		name = next.name,
		luck = next.luck,
		odds = LuckCatalog.odds(next.luck),
	}
end

return ConveyorService
