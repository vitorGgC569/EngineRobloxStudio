local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local CardCatalog = require(ReplicatedStorage.Shared.CardCatalog)
local FloorCatalog = require(ReplicatedStorage.Shared.FloorCatalog)
local LuckCatalog = require(ReplicatedStorage.Shared.LuckCatalog)
local FarmCatalog = require(ReplicatedStorage.Shared.FarmCatalog)
local PlotService = require(script.Parent.Services.PlotService)
local PersistenceService = require(script.Parent.Services.PersistenceService)
local StoreService = require(script.Parent.Services.StoreService)
local ProgressionService = require(script.Parent.Services.ProgressionService)
local ConveyorService = require(script.Parent.Services.ConveyorService)
local FarmService = require(script.Parent.Services.FarmService)
local BoostService = require(script.Parent.Services.BoostService)
local MapService = require(script.Parent.Services.MapService)
local WorldKit = require(ServerScriptService.WorldKit)

local remotes = Instance.new("Folder")
remotes.Name = "Remotes"
remotes.Parent = ReplicatedStorage

local purchaseRemote = Instance.new("RemoteEvent")
purchaseRemote.Name = "PurchaseBasicPack"
purchaseRemote.Parent = remotes

local floorRemote = Instance.new("RemoteEvent")
floorRemote.Name = "UpgradeFloor"
floorRemote.Parent = remotes

local equipCardRemote = Instance.new("RemoteEvent")
equipCardRemote.Name = "EquipCard"
equipCardRemote.Parent = remotes

local plotService = PlotService.new(Config.PlotNames)
local persistenceService = PersistenceService.new("MinersRidgeTycoon_v1")
local progressionService = ProgressionService.new(Config, persistenceService, CardCatalog, FloorCatalog)
local storeService = StoreService.new(Config, persistenceService, CardCatalog)
local conveyorService = ConveyorService.new(WorldKit.Palette.BrickFarm)
local farmService = FarmService.new()
local boostService = BoostService.new()

--- The card a player is holding, waiting to be slotted.
local pendingCard = {}
--- Declared early so player setup can publish farm numbers on join.
local syncFarm
local mutationRandom = Random.new()
local _, purchasePrompt, floorPrompt, plotRigs = MapService.build()

local pullCardRemote = Instance.new("RemoteEvent")
pullCardRemote.Name = "PullCard"
pullCardRemote.Parent = remotes

local cardLandedRemote = Instance.new("RemoteEvent")
cardLandedRemote.Name = "CardLanded"
cardLandedRemote.Parent = remotes

local placeCardRemote = Instance.new("RemoteEvent")
placeCardRemote.Name = "PlaceCard"
placeCardRemote.Parent = remotes

local sellBoxesRemote = Instance.new("RemoteEvent")
sellBoxesRemote.Name = "SellBoxes"
sellBoxesRemote.Parent = remotes

local farmEvent = Instance.new("RemoteEvent")
farmEvent.Name = "FarmEvent"
farmEvent.Parent = remotes

--- One remote per player intent. Named events rather than one generic channel:
--- a malformed payload can only break the feature it belongs to.
local boostRemotes = {}
for _, name in ipairs({ "BuyPotion", "UsePotion", "RedeemCode", "ClaimDaily", "Rebirth", "UpgradeSlot", "BuyProduct" }) do
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = remotes
	boostRemotes[name] = remote
end

local boostEvent = Instance.new("RemoteEvent")
boostEvent.Name = "BoostEvent"
boostEvent.Parent = remotes

for plotName, rig in pairs(plotRigs) do
	conveyorService:register(plotName, rig.conveyor, 1)
end

local function defaults()
	return {
		currency = Config.StartingCurrency,
		inventory = {},
		cards = {Config.StarterCardId},
		activeCard = Config.StarterCardId,
		unlockedFloors = {1},
		activeFloor = 1,
		plot = nil,
	}
end

local function setupPlayer(player)
	local data = persistenceService:load(player, defaults())
	if not data then
		player:Kick("Your save could not be loaded safely. Please rejoin shortly.")
		return
	end
	progressionService:initialize(data)
	data.plot = plotService:assign(player)
	progressionService:applyFloorVisual(player, data)
	player:SetAttribute("PlotName", data.plot or "")
	progressionService:syncAttributes(player, data)

	if data.plot then
		farmService:ensure(data.plot, data.farm)
		-- Credit the time they were away before they see any number, so the
		-- first thing on screen is already correct.
		local away = data.lastSeenAt and (os.time() - data.lastSeenAt) or 0
		if away > 30 then
			local offline = farmService:applyOffline(data.plot, away)
			if offline.ok then
				player:SetAttribute("OfflineBoxes", offline.boxes)
				player:SetAttribute("OfflineSeconds", offline.countedSeconds)
			end
		end
		data.farm = farmService:serialize(data.plot)
		persistenceService:save(player)
		syncFarm(player, data.plot)
	end
end

local function cleanupPlayer(player)
	local data = persistenceService:get(player)
	if data and data.plot then
		data.farm = farmService:serialize(data.plot)
		data.lastSeenAt = os.time()
		farmService:release(data.plot)
	end
	pendingCard[player.UserId] = nil
	storeService:clearPlayer(player)
	plotService:release(player)
	persistenceService:clear(player)
end

local function isNearPrompt(player, prompt)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local promptPart = prompt.Parent
	return root ~= nil and promptPart:IsA("BasePart") and (root.Position - promptPart.Position).Magnitude <= prompt.MaxActivationDistance + 2
end

Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(cleanupPlayer)

purchasePrompt.Triggered:Connect(function(player)
	local success = storeService:purchaseBasicPack(player)
	if success then
		local data = persistenceService:get(player)
		progressionService:syncAttributes(player, data)
	end
end)

purchaseRemote.OnServerEvent:Connect(function(player, payload)
	-- The server ignores all client-supplied price and item fields.
	if payload ~= nil and type(payload) ~= "table" then
		return
	end
	if not isNearPrompt(player, purchasePrompt) then
		return
	end
	local success = storeService:purchaseBasicPack(player)
	if success then
		progressionService:syncAttributes(player, persistenceService:get(player))
	end
end)

floorPrompt.Triggered:Connect(function(player)
	progressionService:purchaseNextFloor(player)
end)

floorRemote.OnServerEvent:Connect(function(player)
	if not isNearPrompt(player, floorPrompt) then
		return
	end
	progressionService:purchaseNextFloor(player)
end)

equipCardRemote.OnServerEvent:Connect(function(player, cardId)
	progressionService:activateCard(player, cardId)
end)

-- --------------------------------------------------------------- card belt

--- Only the plot's owner may pull from its belt.
local function ownedPlotOf(player: Player): string?
	local data = persistenceService:get(player)
	local plotName = data and data.plot
	if plotName == nil or not plotService:isOwner(player, plotName) then
		return nil
	end
	return plotName
end

--- Spawn a card onto the belt for the player to judge.
---
--- The card is an offer, not a gift: it rides past carrying a "Take card"
--- prompt, and pressing it is what buys it. Letting it reach the end is a
--- deliberate pass.
local function spawnOffer(player: Player)
	local plotName = ownedPlotOf(player)
	if plotName == nil then
		return
	end
	local data = persistenceService:get(player)
	if data == nil then
		return
	end

	local owned = {}
	for _, cardId in ipairs(data.cards or {}) do
		owned[cardId] = true
	end

	local multipliers = boostService:multipliers(data)
	local effectiveLuck = LuckCatalog.luckFor(conveyorService:luckLevel(plotName)) * multipliers.luck * multipliers.mutation
	local mutation = FarmCatalog.rollMutation(effectiveLuck, mutationRandom)

	local offer = conveyorService:spawnOffer(player, plotName, owned, mutation, function(cardId, rarity)
		cardLandedRemote:FireClient(player, { action = "missed", cardId = cardId, rarity = rarity, mutation = mutation })
	end)

	if not offer.ok then
		cardLandedRemote:FireClient(player, { rejected = true, reason = offer.reason, cooldownRemaining = offer.cooldownRemaining })
		return
	end

	cardLandedRemote:FireClient(player, {
		action = "offered",
		cardId = offer.cardId,
		rarity = offer.rarity,
		mutation = offer.mutation,
		mutationMultiplier = FarmCatalog.mutationMultiplier(offer.mutation),
		income = FarmCatalog.slotIncome(offer.rarity, offer.mutation, 1),
	})

	offer.prompt.Triggered:Connect(function(taker)
		if taker ~= player then
			return
		end
		local model = offer.model
		if model.Parent == nil or model:GetAttribute("Taken") == true then
			return
		end
		model:SetAttribute("Taken", true)

		local currentData = persistenceService:get(player)
		if currentData == nil then
			return
		end

		local isNew = true
		for _, ownedId in ipairs(currentData.cards or {}) do
			if ownedId == offer.cardId then
				isNew = false
				break
			end
		end
		local refund = 0
		if isNew then
			table.insert(currentData.cards, offer.cardId)
		else
			refund = CardCatalog.duplicateValue(offer.cardId)
			currentData.currency = (currentData.currency or 0) + refund
		end
		currentData.activeCard = currentData.activeCard or offer.cardId

		pendingCard[player.UserId] = { cardId = offer.cardId, rarity = offer.rarity, mutation = offer.mutation }
		player:SetAttribute("HeldCard", offer.cardId)
		player:SetAttribute("HeldRarity", offer.rarity)
		player:SetAttribute("HeldMutation", offer.mutation)

		persistenceService:save(player)
		progressionService:syncAttributes(player, currentData)
		cardLandedRemote:FireClient(player, {
			action = "taken",
			cardId = offer.cardId,
			rarity = offer.rarity,
			mutation = offer.mutation,
			isNew = isNew,
			refund = refund,
			cardCount = #currentData.cards,
			collectionTotal = CardCatalog.total(),
		})
		conveyorService:clearOffer(plotName)
		model:Destroy()
	end)
end

local function pullCard(player: Player)
	local plotName = ownedPlotOf(player)
	if plotName == nil then
		return
	end
	local data = persistenceService:get(player)
	if data == nil then
		return
	end

	local owned = {}
	for _, cardId in ipairs(data.cards or {}) do
		owned[cardId] = true
	end

	local result = conveyorService:pull(player, plotName, owned, function(cardId, rarity)
		-- Granted when the card reaches the end of the belt, not when the
		-- button was pressed: the ride is part of the transaction.
		--
		-- Ownership is re-checked here rather than read from the snapshot taken
		-- at pull time. Two cards can be in flight at once, and both saw the
		-- same "not owned" answer -- measured, and it put tin_whistle in the
		-- collection twice.
		local isNew = true
		for _, ownedId in ipairs(data.cards or {}) do
			if ownedId == cardId then
				isNew = false
				break
			end
		end
		local refund = 0
		if isNew then
			table.insert(data.cards, cardId)
		else
			-- A duplicate still pays. Otherwise a pull can be worth nothing,
			-- and a belt that sometimes gives nothing teaches players to stop
			-- pulling.
			refund = CardCatalog.duplicateValue(cardId)
			data.currency = (data.currency or 0) + refund
		end
		data.activeCard = data.activeCard or cardId

		-- The card lands in the player's hands, not straight into the farm:
		-- slotting it is a separate decision, and which slot it goes in matters.
		local mutation = FarmCatalog.rollMutation(LuckCatalog.luckFor(conveyorService:luckLevel(plotName)), mutationRandom)
		pendingCard[player.UserId] = { cardId = cardId, rarity = rarity, mutation = mutation }
		player:SetAttribute("HeldCard", cardId)
		player:SetAttribute("HeldRarity", rarity)
		player:SetAttribute("HeldMutation", mutation)

		persistenceService:save(player)
		progressionService:syncAttributes(player, data)
		cardLandedRemote:FireClient(player, {
			cardId = cardId,
			rarity = rarity,
			mutation = mutation,
			mutationMultiplier = FarmCatalog.mutationMultiplier(mutation),
			isNew = isNew,
			refund = refund,
			cardCount = #data.cards,
			collectionTotal = CardCatalog.total(),
			income = FarmCatalog.slotIncome(rarity, mutation, 1),
		})
	end)

	if not result.ok then
		cardLandedRemote:FireClient(player, { rejected = true, reason = result.reason, cooldownRemaining = result.cooldownRemaining })
	end
end

local function upgradeLuck(player: Player)
	local plotName = ownedPlotOf(player)
	if plotName == nil then
		return
	end
	local data = persistenceService:get(player)
	if data == nil then
		return
	end

	local result = conveyorService:upgradeLuck(plotName, data.currency or 0)
	if result.ok then
		data.currency -= result.price
		data.luckLevel = result.level
		persistenceService:save(player)
		progressionService:syncAttributes(player, data)
		player:SetAttribute("LuckLevel", result.level)
		player:SetAttribute("LuckName", result.name)
		player:SetAttribute("Luck", result.luck)
	end
end

-- ------------------------------------------------------------------- farm

--- Push the farm's live numbers onto the player so the HUD and any test can
--- read one authority instead of recomputing the economy.
function syncFarm(player: Player, plotName: string)
	local summary = farmService:summary(plotName)
	player:SetAttribute("Slots", summary.unlockedSlots)
	player:SetAttribute("FilledSlots", summary.filledSlots)
	player:SetAttribute("ActiveSlots", summary.activeSlots)
	player:SetAttribute("FreeSlots", summary.freeSlots)
	player:SetAttribute("Boxes", summary.boxes)
	player:SetAttribute("PendingValue", summary.pendingValue)
	player:SetAttribute("BoxesPerSecond", summary.boxesPerSecond)
	player:SetAttribute("CashPerSecond", summary.cashPerSecond)
	-- The HUD reads these; publishing them here keeps one authority for what a
	-- farm is worth rather than letting the client recompute the economy.
	local data = persistenceService:get(player)
	if data then
		player:SetAttribute("CardCollection", table.concat(data.cards or {}, ","))
	end
	return summary
end

--- Place the most recently pulled card into a slot.
local function placeCard(player: Player, slotIndex: number?)
	local plotName = ownedPlotOf(player)
	if plotName == nil then
		return
	end
	local data = persistenceService:get(player)
	if data == nil then
		return
	end

	local pending = pendingCard[player.UserId]
	if pending == nil then
		farmEvent:FireClient(player, { action = "place", ok = false, reason = "no_card_in_hand" })
		return
	end

	local result = farmService:place(plotName, pending.cardId, pending.rarity, pending.mutation, slotIndex)
	if result.ok then
		pendingCard[player.UserId] = nil
		-- Clear the held-card attributes too, or the HUD keeps showing a card
		-- the player no longer has in hand.
		player:SetAttribute("HeldCard", nil)
		player:SetAttribute("HeldRarity", nil)
		player:SetAttribute("HeldMutation", nil)
		data.farm = farmService:serialize(plotName)
		persistenceService:save(player)
		syncFarm(player, plotName)
	end
	farmEvent:FireClient(player, { action = "place", ok = result.ok, reason = result.reason, slot = result.slot,
		cardId = pending.cardId, rarity = pending.rarity, mutation = pending.mutation,
		activationSeconds = result.activationSeconds, income = result.income })
end

local function sellBoxes(player: Player)
	local plotName = ownedPlotOf(player)
	if plotName == nil then
		return
	end
	local data = persistenceService:get(player)
	if data == nil then
		return
	end

	local result = farmService:sellAll(plotName)
	if result.ok then
		local multipliers = boostService:multipliers(data)
		local paid = math.floor(result.cash * multipliers.cash)
		result.cash = paid
		data.currency = (data.currency or 0) + paid
		-- Lifetime earnings drive rebirth, so they count what was actually paid.
		boostService:recordEarnings(data, paid)
		data.farm = farmService:serialize(plotName)
		persistenceService:save(player)
		progressionService:syncAttributes(player, data)
		syncFarm(player, plotName)
	end
	farmEvent:FireClient(player, { action = "sell", ok = result.ok, cash = result.cash, boxes = result.boxes })
end

local function unlockSlot(player: Player)
	local plotName = ownedPlotOf(player)
	if plotName == nil then
		return
	end
	local data = persistenceService:get(player)
	if data == nil then
		return
	end

	local result = farmService:unlockSlot(plotName, data.currency or 0)
	if result.ok then
		data.currency -= result.price
		data.farm = farmService:serialize(plotName)
		persistenceService:save(player)
		progressionService:syncAttributes(player, data)
		syncFarm(player, plotName)
	end
	farmEvent:FireClient(player, { action = "unlock_slot", ok = result.ok, reason = result.reason, slot = result.slot, price = result.price })
end

for plotName, rig in pairs(plotRigs) do
	rig.pullPrompt.Triggered:Connect(spawnOffer)
	rig.luckPrompt.Triggered:Connect(upgradeLuck)
	rig.sellPrompt.Triggered:Connect(sellBoxes)

	for _, slotModel in ipairs(rig.slotsFolder:GetChildren()) do
		local index = slotModel:GetAttribute("SlotIndex")
		local prompt = slotModel:FindFirstChild("Pad") and slotModel.Pad:FindFirstChild("SlotPrompt")
		if prompt and index then
			prompt.Triggered:Connect(function(player)
				local plot = ownedPlotOf(player)
				if plot ~= plotName then
					return
				end
				local slot = farmService:slot(plotName, index)
				if slot and not slot.unlocked then
					unlockSlot(player)
				else
					placeCard(player, index)
				end
			end)
		end
	end
end

-- Publish farm numbers on a heartbeat, not only when something is clicked.
--
-- Production is continuous, so attributes read between events were stale:
-- measured a farm reporting activeSlots 0 and $/s 0 while it was actually
-- producing, which is indistinguishable from a broken farm.
task.spawn(function()
	while true do
		task.wait(1)
		for _, player in ipairs(Players:GetPlayers()) do
			local data = persistenceService:get(player)
			if data and data.plot then
				-- Potions expire on the clock, so the production rate is
				-- refreshed each tick rather than only when one is drunk.
				local multipliers = boostService:multipliers(data)
				farmService:setProductionMultiplier(data.plot, multipliers.production)
				farmService:tickFarm(data.plot)
				syncFarm(player, data.plot)
			end
		end
	end
end)

placeCardRemote.OnServerEvent:Connect(function(player, slotIndex)
	if slotIndex ~= nil and type(slotIndex) ~= "number" then
		return
	end
	placeCard(player, slotIndex)
end)

sellBoxesRemote.OnServerEvent:Connect(sellBoxes)

pullCardRemote.OnServerEvent:Connect(function(player)
	-- The server re-checks proximity; the client's word is never enough.
	local plotName = ownedPlotOf(player)
	local rig = plotName and plotRigs[plotName]
	if rig and isNearPrompt(player, rig.pullPrompt) then
		spawnOffer(player)
	end
end)

-- Seed the luck attributes so the HUD has something to show on join.
Players.PlayerAdded:Connect(function(player)
	player:SetAttribute("LuckLevel", 1)
	player:SetAttribute("LuckName", LuckCatalog.upgradeFor(1).name)
	player:SetAttribute("Luck", LuckCatalog.luckFor(1))
end)

-- ------------------------------------------------------- boosts and screens

local PotionCatalog = require(ReplicatedStorage.Shared.PotionCatalog)

--- Publish everything the screens read. Serialised as short strings because
--- attributes cannot hold tables, and a screen that has to ask the server for
--- each row would flicker.
local function syncBoosts(player: Player)
	local data = persistenceService:get(player)
	if data == nil then
		return
	end

	local held = {}
	for id, count in pairs(data.potions or {}) do
		if count > 0 then
			table.insert(held, string.format("%s:%d", id, count))
		end
	end
	table.sort(held)
	player:SetAttribute("PotionsHeld", table.concat(held, ","))

	local active = {}
	for _, entry in ipairs(boostService:activePotions(data)) do
		table.insert(active, string.format("%s:%d", entry.potionId, math.max(0, entry.remainingSeconds)))
	end
	table.sort(active)
	player:SetAttribute("PotionsActive", table.concat(active, ","))

	local multipliers = boostService:multipliers(data)
	player:SetAttribute("CashMultiplier", multipliers.cash)
	player:SetAttribute("Luck", multipliers.luck * LuckCatalog.luckFor(data.luckLevel or 1))
	player:SetAttribute("RebirthLevel", multipliers.rebirthLevel)
	player:SetAttribute("LifetimeCash", data.lifetimeCash or 0)

	local daily = boostService:dailyStatus(data)
	player:SetAttribute("DailyAvailable", daily.available)
	player:SetAttribute("DailyStreak", daily.streak or 0)
end

local function announce(player: Player, payload)
	boostEvent:FireClient(player, payload)
	syncBoosts(player)
	local data = persistenceService:get(player)
	if data then
		persistenceService:save(player)
		progressionService:syncAttributes(player, data)
	end
end

boostRemotes.BuyPotion.OnServerEvent:Connect(function(player, potionId)
	if type(potionId) ~= "string" then
		return
	end
	local data = persistenceService:get(player)
	if data == nil then
		return
	end
	announce(player, { action = "buy_potion", result = boostService:buyPotion(data, potionId) })
end)

boostRemotes.UsePotion.OnServerEvent:Connect(function(player, potionId)
	if type(potionId) ~= "string" then
		return
	end
	local data = persistenceService:get(player)
	if data == nil then
		return
	end
	announce(player, { action = "use_potion", result = boostService:usePotion(data, potionId) })
end)

boostRemotes.RedeemCode.OnServerEvent:Connect(function(player, code)
	-- Codes are matched here, never on the client: the list is the reward.
	if type(code) ~= "string" or #code > 40 then
		return
	end
	local data = persistenceService:get(player)
	if data == nil then
		return
	end
	announce(player, { action = "redeem", result = boostService:redeem(data, code) })
end)

boostRemotes.ClaimDaily.OnServerEvent:Connect(function(player)
	local data = persistenceService:get(player)
	if data == nil then
		return
	end
	announce(player, { action = "daily", result = boostService:claimDaily(data) })
end)

boostRemotes.Rebirth.OnServerEvent:Connect(function(player)
	local data = persistenceService:get(player)
	if data == nil or data.plot == nil then
		return
	end
	local result = boostService:rebirth(data)
	if result.ok then
		-- The farm is part of what rebirth trades away, so it is rebuilt empty
		-- rather than left holding the previous run's cards.
		farmService:release(data.plot)
		farmService:ensure(data.plot, nil)
		conveyorService:setLuckLevel(data.plot, 1)
		data.farm = farmService:serialize(data.plot)
		syncFarm(player, data.plot)
	end
	announce(player, { action = "rebirth", result = result })
end)

boostRemotes.UpgradeSlot.OnServerEvent:Connect(function(player, slotIndex)
	if type(slotIndex) ~= "number" then
		return
	end
	local data = persistenceService:get(player)
	if data == nil or data.plot == nil then
		return
	end
	local slot = farmService:slot(data.plot, slotIndex)
	if slot == nil or slot.cardId == nil then
		boostEvent:FireClient(player, { action = "upgrade_slot", result = { ok = false, reason = "slot_empty" } })
		return
	end

	-- Cost scales with the level already bought, so stacking upgrades on one
	-- strong card is a real decision rather than an obvious one.
	local price = math.floor(400 * (1.8 ^ (slot.upgradeLevel - 1)))
	if (data.currency or 0) < price then
		boostEvent:FireClient(player, { action = "upgrade_slot", result = { ok = false, reason = "insufficient_funds", price = price } })
		return
	end
	data.currency -= price
	slot.upgradeLevel += 1
	data.farm = farmService:serialize(data.plot)
	syncFarm(player, data.plot)
	announce(player, { action = "upgrade_slot", result = { ok = true, slot = slotIndex, level = slot.upgradeLevel, price = price } })
end)

boostRemotes.BuyProduct.OnServerEvent:Connect(function(player, productId)
	if type(productId) ~= "string" then
		return
	end
	local RewardCatalog = require(ReplicatedStorage.Shared.RewardCatalog)
	if not RewardCatalog.isConfigured(productId) then
		-- Refusing loudly is the honest answer: the product does not exist yet.
		boostEvent:FireClient(player, { action = "buy_product", result = { ok = false, reason = "product_not_configured", productId = productId } })
		return
	end
	local product = RewardCatalog.ProductById[productId]
	game:GetService("MarketplaceService"):PromptProductPurchase(player, product.productId)
end)

Players.PlayerAdded:Connect(function(player)
	task.defer(syncBoosts, player)
end)

-- Potions expire on the clock, so the HUD has to be told without being asked.
task.spawn(function()
	while true do
		task.wait(5)
		for _, player in ipairs(Players:GetPlayers()) do
			syncBoosts(player)
		end
	end
end)

-- Preserve the final farm snapshot before releasing ownership at shutdown.
task.spawn(function()
    while true do
        task.wait(30)
        for _, player in Players:GetPlayers() do
            task.spawn(function()
                local data = persistenceService:get(player)
                if data and data.plot then
                    data.farm = farmService:serialize(data.plot)
                    data.lastSeenAt = os.time()
                end
                if data and not persistenceService:save(player) then
                    if persistenceService:get(player) == nil then
                        player:Kick("Your save session was interrupted. Please rejoin.")
                    end
                end
            end)
        end
    end
end)

game:BindToClose(function()
    for _, player in Players:GetPlayers() do
        local data = persistenceService:get(player)
        if data and data.plot then
            data.farm = farmService:serialize(data.plot)
            data.lastSeenAt = os.time()
        end
    end
    persistenceService:close()
end)
