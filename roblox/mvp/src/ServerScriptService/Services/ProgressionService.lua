local ProgressionService = {}
ProgressionService.__index = ProgressionService

local function ensureArray(value)
	return type(value) == "table" and value or {}
end

local function makePart(parent, name, size, position, color, material, transparency, canCollide)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = canCollide ~= false
	part.CanQuery = true
	part.CastShadow = true
	part.Size = size
	part.Position = position
	part.Color = color
	part.Material = material or Enum.Material.Metal
	part.Transparency = transparency or 0
	part.Parent = parent
	return part
end

function ProgressionService.new(config, persistence, cardCatalog, floorCatalog)
	local self = setmetatable({}, ProgressionService)
	self.config = config
	self.persistence = persistence
	self.cardCatalog = cardCatalog
	self.floorCatalog = floorCatalog
	return self
end

function ProgressionService:initialize(data)
	data.cards = ensureArray(data.cards)
	if #data.cards == 0 then
		table.insert(data.cards, self.config.StarterCardId)
	end
	data.activeCard = data.activeCard or data.cards[1]
	data.unlockedFloors = ensureArray(data.unlockedFloors)
	if #data.unlockedFloors == 0 then
		table.insert(data.unlockedFloors, 1)
	end
	data.activeFloor = math.clamp(tonumber(data.activeFloor) or 1, 1, self.config.MaxFloor)
	return data
end

function ProgressionService:syncAttributes(player, data)
	local floor = self.floorCatalog.get(data.activeFloor) or self.floorCatalog.get(1)
	local activeCard = self.cardCatalog.get(data.activeCard or "")
	local oreYieldMultiplier = 1
	local buildCostMultiplier = 1
	local objectiveReveal = false
	local floorIncomeMultiplier = floor.incomeMultiplier
	if activeCard then
		if activeCard.id == "mossback_badger_engineer" then
			buildCostMultiplier = 0.95
		elseif activeCard.id == "copper_lynx_prospector" then
			oreYieldMultiplier = 1.12
		elseif activeCard.id == "storm_raven_surveyor" then
			objectiveReveal = true
		elseif activeCard.id == "ridge_warden" then
			floorIncomeMultiplier = floorIncomeMultiplier * 1.2
		end
	end
	player:SetAttribute("Currency", data.currency or 0)
	player:SetAttribute("CardCount", #data.cards)
	player:SetAttribute("CardCollection", table.concat(data.cards, ","))
	player:SetAttribute("ActiveCard", data.activeCard or "")
	player:SetAttribute("FloorLevel", data.activeFloor)
	player:SetAttribute("FloorName", floor.name)
	player:SetAttribute("FloorMultiplier", floorIncomeMultiplier)
	player:SetAttribute("CardPower", activeCard and activeCard.power or 0)
	player:SetAttribute("CardEffect", activeCard and activeCard.effect or "")
	player:SetAttribute("CardRarity", activeCard and activeCard.rarity or "Common")
	player:SetAttribute("CardEffectStyle", activeCard and activeCard.effectStyle or "lantern")
	player:SetAttribute("OreYieldMultiplier", oreYieldMultiplier)
	player:SetAttribute("BuildCostMultiplier", buildCostMultiplier)
	player:SetAttribute("ObjectiveReveal", objectiveReveal)
	player:SetAttribute("FloorIncomeMultiplier", floorIncomeMultiplier)
end

function ProgressionService:applyFloorVisual(player, data)
	local map = workspace:FindFirstChild("Map")
	local plotName = data.plot
	local plot = map and plotName and map:FindFirstChild(plotName)
	local foundation = plot and plot:FindFirstChild("Foundation")
	if not foundation then
		return
	end

	local decks = plot:FindFirstChild("FloorDecks") or Instance.new("Folder")
	decks.Name = "FloorDecks"
	decks.Parent = plot
	for level = 2, data.activeFloor do
		if decks:FindFirstChild("FloorDeck_" .. level) == nil then
			local floor = self.floorCatalog.get(level)
			local deck = Instance.new("Model")
			deck.Name = "FloorDeck_" .. level
			deck:SetAttribute("FloorLevel", level)
			deck:SetAttribute("FloorName", floor.name)
			deck.Parent = decks
			local y = foundation.Position.Y + 1 + ((level - 1) * 6.5)
			makePart(deck, "Platform", Vector3.new(30, 0.6, 24), Vector3.new(foundation.Position.X, y, foundation.Position.Z), floor.color, Enum.Material.Metal)
			for _, x in ipairs({-13, 13}) do
				makePart(deck, "Support", Vector3.new(0.8, y - foundation.Position.Y, 0.8), Vector3.new(foundation.Position.X + x, (y + foundation.Position.Y) * 0.5, foundation.Position.Z), Color3.fromRGB(39, 51, 64), Enum.Material.Metal)
			end
			makePart(deck, "FrontRail", Vector3.new(30, 1.2, 0.35), Vector3.new(foundation.Position.X, y + 0.9, foundation.Position.Z + 11.6), floor.color, Enum.Material.Neon, 0.08, false)
			makePart(deck, "BackRail", Vector3.new(30, 1.2, 0.35), Vector3.new(foundation.Position.X, y + 0.9, foundation.Position.Z - 11.6), floor.color, Enum.Material.Neon, 0.08, false)
			makePart(deck, "StairRun", Vector3.new(5, 0.35, 7), Vector3.new(foundation.Position.X, y - 1.6, foundation.Position.Z + 14), floor.color, Enum.Material.Slate)
		end
	end
end

function ProgressionService:purchaseNextFloor(player)
	local data = self.persistence:get(player)
	if data == nil then
		return false, "invalid_player_state"
	end
	local current = tonumber(data.activeFloor) or 1
	local nextFloor = self.floorCatalog.next(current)
	if nextFloor == nil or current >= self.config.MaxFloor then
		return false, "max_floor_reached"
	end
	if type(data.currency) ~= "number" or data.currency < nextFloor.price then
		return false, "insufficient_funds"
	end
	data.currency -= nextFloor.price
	data.activeFloor = nextFloor.level
	data.unlockedFloors = ensureArray(data.unlockedFloors)
	if not table.find(data.unlockedFloors, nextFloor.level) then
		table.insert(data.unlockedFloors, nextFloor.level)
	end
	self.persistence:save(player)
	self:syncAttributes(player, data)
	self:applyFloorVisual(player, data)
	return true, "floor_purchased"
end

function ProgressionService:activateCard(player, cardId)
	local data = self.persistence:get(player)
	if data == nil or type(cardId) ~= "string" or self.cardCatalog.get(cardId) == nil then
		return false, "invalid_card"
	end
	if not table.find(data.cards, cardId) then
		return false, "card_not_owned"
	end
	data.activeCard = cardId
	self.persistence:save(player)
	self:syncAttributes(player, data)
	return true, "card_activated"
end

return ProgressionService
