local StoreService = {}
StoreService.__index = StoreService

function StoreService.new(config, persistence, cardCatalog)
	local self = setmetatable({}, StoreService)
	self.config = config
	self.persistence = persistence
	self.cardCatalog = cardCatalog
	self.processed = {}
	return self
end

function StoreService:purchaseBasicPack(player)
	local data = self.persistence:get(player)
	if data == nil or type(data.currency) ~= "number" or type(data.inventory) ~= "table" then
		return false, "invalid_player_state"
	end
	if self.processed[player.UserId] then
		return false, "already_purchased"
	end
	for _, itemId in ipairs(data.inventory) do
		if itemId == self.config.BasicPackId then
			self.processed[player.UserId] = true
			return false, "already_purchased"
		end
	end
	if data.currency < self.config.BasicPackPrice then
		return false, "insufficient_funds"
	end

	data.currency -= self.config.BasicPackPrice
	table.insert(data.inventory, self.config.BasicPackId)
	if self.cardCatalog and type(data.cards) == "table" then
		local cardId = self.cardCatalog.nextUnowned(data.cards)
		table.insert(data.cards, cardId)
		data.lastCardId = cardId
		data.activeCard = data.activeCard or cardId
	end
	self.processed[player.UserId] = true
	self.persistence:save(player)
	return true, "purchased"
end

function StoreService:clearPlayer(player)
	self.processed[player.UserId] = nil
end

return StoreService
