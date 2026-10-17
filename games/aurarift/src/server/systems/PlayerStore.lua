--[[
	PlayerStore — the one place a saved profile becomes a running player.

	Every service (summons, tower, upgrades) reads and writes through this
	module, and nothing else touches `Save`. That is deliberate: two systems
	that both hydrate a profile produce two truths, and the day they disagree
	is the day a player loses an account without a single error in the log.

	State accessors here are plain fields, never functions. A getter bound as
	if it were a field is a class of defect this repository has paid for
	before (`gameplay.systems` was a function, and every use threw).

	Big numbers
	-----------
	`state.wallet` is an Economy.Balance with `rift` as a big currency. The
	profile stores `wallet:snapshot()` (exact scientific strings) and restores
	it on load — the engine's own round-trip, not a second serialiser written
	here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage.Shared.Content)
local Format = require(ReplicatedStorage.Shared.Format)

local Net = Forge.Net
local Save = Forge.Save
local Debug = Forge.Debug
local Balance = Forge.Economy.Balance
local BigNumber = Forge.Economy.BigNumber
local IncomeEngine = Forge.Economy.IncomeEngine
local OfflineEarnings = Forge.Progression.OfflineEarnings

local PlayerStore = {}

local states = {}

local function dayNumber(timestamp)
	return math.floor(timestamp / 86400)
end

local function uniqueCount(collection)
	local total = 0
	for _, count in pairs(collection) do
		if count > 0 then
			total += 1
		end
	end
	return total
end

PlayerStore.uniqueCount = uniqueCount

-- ============================== derivation ==================================

--: Rebuilds power and the income engine from scratch. Nothing accumulates:
--: an accumulated number is right on the screen and wrong in the ledger.
local function recompute(state)
	local power = 0
	local incomeSum = 0
	for slot = 1, 3 do
		local cardId = state.equipped[slot]
		if type(cardId) == "string" and cardId ~= "" and (state.collection[cardId] or 0) > 0 then
			local dupes = state.collection[cardId] - 1
			power += Content.cardPower(cardId, dupes)
			incomeSum += Content.cardIncome(cardId, dupes)
		end
	end
	local essenceMultiplier = 1 + Content.essenceMultiplierPer * state.essence
	state.power = power
		* (1 + Content.powerPerLevel * (state.upgrades.power or 0))
		* essenceMultiplier
	state.income:removeContributor("cards")
	state.income:addContributor("cards", { kind = "add", value = incomeSum })
	state.income:setMultiplier("mul", essenceMultiplier * (1 + Content.incomePerLevel * (state.upgrades.income or 0)))
	state.income:setMultiplier("add", Content.collectionIncomeBonusPerUnique * uniqueCount(state.collection) * incomeSum)
	state.perSecond = state.income:total()
end

PlayerStore.recompute = recompute

-- =============================== interface ==================================

function PlayerStore.luckMultiplier(state)
	return 1 + Content.luckPerLevel * (state.upgrades.luck or 0)
end

function PlayerStore.rollCostFor(state, count)
	return Content.rollCostSum(state.rolls, count)
end

function PlayerStore.payRift(state, cost)
	if cost <= 0 then
		return true
	end
	local paid = state.wallet:debit({ rift = cost })
	return paid
end

function PlayerStore.creditRift(state, amount)
	state.wallet:credit({ rift = amount })
end

function PlayerStore.creditGems(state, amount)
	state.wallet:credit({ gems = amount })
end

function PlayerStore.riftNumber(state)
	return BigNumber.toNumber(state.wallet:get("rift"))
end

--: Returns (isNew, dupes). Announced rarities bump the divine counter here so
--: no caller can forget to.
function PlayerStore.addCard(state, cardId)
	local count = (state.collection[cardId] or 0) + 1
	state.collection[cardId] = count
	local card = Content.card(cardId)
	if card ~= nil and card.rarity >= Content.roll.announceRarity then
		state.divines += 1
	end
	recompute(state)
	return count == 1, count - 1
end

--: New cards fill the first open unlocked slot. A first summon that lands in
--: the collection but changes nothing on the HUD teaches the player that
--: summoning is decorative.
function PlayerStore.autoEquip(state, cardId)
	local slots = Content.equippedSlotsFor(state.bestFloor, state.life)
	for slot = 1, slots do
		if state.equipped[slot] == "" then
			state.equipped[slot] = cardId
			recompute(state)
			return slot
		end
	end
	return nil
end

function PlayerStore.notify(player, text, color)
	Net.fire(player, "Notify", { text = text, color = color })
end

function PlayerStore.announce(payload)
	Net.fireAll("Announce", payload)
end

-- ================================ payload ===================================

local function payloadFor(state)
	local rift = state.wallet:get("rift")
	local unique = uniqueCount(state.collection)

	local equipped = {}
	for slot = 1, 3 do
		local cardId = state.equipped[slot]
		equipped[slot] = if type(cardId) == "string" then cardId else ""
	end

	local collection = {}
	for cardId, count in pairs(state.collection) do
		table.insert(collection, { id = cardId, count = count })
	end

	local upgrades = {}
	local upgradeCosts = {}
	for _, upgrade in ipairs(Content.upgrades) do
		local level = state.upgrades[upgrade.id] or 0
		upgrades[upgrade.id] = level
		local maxed = level >= upgrade.maxLevel
		local cost = if maxed then 0 else Content.upgradeCost(upgrade.id, level)
		upgradeCosts[upgrade.id] = {
			level = level,
			maxed = maxed,
			cost = cost,
			costText = if maxed then "MAX" else Format.abbrev(cost),
		}
	end

	local today = dayNumber(os.time())
	local streak = state.daily.streak or 0
	local nextStreak = if state.daily.lastClaimDay == today - 1 then streak + 1 else 1
	local preview = Content.daily.milestones[((nextStreak - 1) % Content.daily.cycleLength) + 1]

	local battle = nil
	if state.battle ~= nil then
		battle = {
			floor = state.battle.floor,
			progress = state.battle.progress,
			timeLeft = state.battle.timeLeft,
			phase = state.battle.phase,
		}
	end

	local offline = nil
	if state.pendingOffline ~= nil then
		offline = {
			seconds = state.pendingOffline.seconds,
			amount = Format.big(state.pendingOffline.amount),
			capped = state.pendingOffline.capped,
		}
	end

	local ascendRequired = Content.ascendRequiredFloor(state.life)
	local free = Content.roll.freeFirstRoll and state.rolls == 0

	return {
		title = Content.title,
		rift = Format.big(rift),
		gems = state.wallet:get("gems"),
		power = state.power,
		powerText = Format.abbrev(state.power),
		rate = Format.abbrev(state.perSecond),
		rateRaw = state.perSecond,
		floor = state.bestFloor,
		life = state.life,
		essence = state.essence,
		essenceText = string.format("x%.2f", 1 + Content.essenceMultiplierPer * state.essence),
		rolls = state.rolls,
		divines = state.divines,
		unique = unique,
		total = Content.cardCount(),
		equipped = equipped,
		slots = Content.equippedSlotsFor(state.bestFloor, state.life),
		collection = collection,
		upgrades = upgrades,
		upgradeCosts = upgradeCosts,
		pity = state.pity,
		pityMax = Content.roll.pityThreshold,
		autoRoll = state.autoRoll,
		free = free,
		nextCostText = if free then "FREE" else Format.abbrev(Content.rollCost(state.rolls)),
		gemCost = Content.roll.gemRollCost,
		batches = {
			five = (state.upgrades.batch5 or 0) >= 1,
			twenty = (state.upgrades.batch20 or 0) >= 1,
		},
		daily = {
			canClaim = state.daily.lastClaimDay ~= today,
			streak = streak,
			day = ((nextStreak - 1) % Content.daily.cycleLength) + 1,
			reward = Content.dailyRewardText(preview or {}),
		},
		offline = offline,
		ascend = {
			required = ascendRequired,
			gain = Content.ascendEssenceGain(state.bestFloor, unique),
			can = state.bestFloor >= ascendRequired,
		},
		battle = battle,
	}
end

-- =============================== publishing =================================

local function publishAttributes(state)
	local player = state.player
	player:SetAttribute("Rift", Format.big(state.wallet:get("rift")))
	player:SetAttribute("Gems", state.wallet:get("gems"))
	player:SetAttribute("Power", math.floor(state.power))
	player:SetAttribute("Rate", Format.abbrev(state.perSecond))
	player:SetAttribute("Floor", state.bestFloor)
	player:SetAttribute("Uniques", uniqueCount(state.collection))
	player:SetAttribute("Rolls", state.rolls)
	player:SetAttribute("Life", state.life)
	player:SetAttribute("Essence", state.essence)
end

function PlayerStore.push(player)
	local state = states[player.UserId]
	if state == nil then
		return
	end
	publishAttributes(state)
	Net.fire(player, "StateSync", payloadFor(state))
end

function PlayerStore.forPlayer(player)
	return states[player.UserId]
end

function PlayerStore.forEach(fn)
	for _, state in pairs(states) do
		fn(state)
	end
end

-- =============================== persistence ================================

function PlayerStore.persist(state)
	local profile = state.profile
	profile.wallet = state.wallet:snapshot()
	profile.collection = state.collection
	profile.equipped = state.equipped
	profile.upgrades = state.upgrades
	profile.life = state.life
	profile.essence = state.essence
	profile.bestFloor = state.bestFloor
	profile.rolls = state.rolls
	profile.divines = state.divines
	profile.pity = state.pity
	profile.autoRoll = state.autoRoll
	profile.daily = state.daily
	profile.lastSeen = os.time()
end

function PlayerStore.write(state)
	if state == nil then
		return
	end
	PlayerStore.persist(state)
	Save.write(state.player)
end

function PlayerStore.writeFor(player)
	PlayerStore.write(states[player.UserId])
end

function PlayerStore.template()
	return {
		wallet = nil,
		collection = {},
		equipped = { "", "", "" },
		upgrades = {},
		life = 0,
		essence = 0,
		bestFloor = 0,
		rolls = 0,
		divines = 0,
		pity = 0,
		autoRoll = false,
		daily = { streak = 0, lastClaimDay = nil },
		lastSeen = 0,
	}
end

-- ================================ lifecycle =================================

--: Template backfill is not trusted for nested tables: two profiles sharing
--: one template table would be two accounts writing each other's collection.
local function normalize(profile)
	if type(profile.collection) ~= "table" then
		profile.collection = {}
	end
	if type(profile.equipped) ~= "table" then
		profile.equipped = { "", "", "" }
	end
	for slot = 1, 3 do
		if type(profile.equipped[slot]) ~= "string" then
			profile.equipped[slot] = ""
		end
	end
	if type(profile.upgrades) ~= "table" then
		profile.upgrades = {}
	end
	if type(profile.daily) ~= "table" then
		profile.daily = { streak = 0 }
	end
	return profile
end

local function loadState(player, profile)
	normalize(profile)

	local wallet = Balance.new({
		currencies = {
			rift = { start = 0, big = true },
			gems = { start = 0 },
		},
	})
	if profile.wallet ~= nil then
		wallet:restore(profile.wallet)
	else
		wallet:credit({ rift = Content.roll.startingRift, gems = Content.roll.startingGems })
	end

	local state = {
		player = player,
		profile = profile,
		wallet = wallet,
		income = IncomeEngine.new({ base = 0 }),
		collection = profile.collection,
		equipped = profile.equipped,
		upgrades = profile.upgrades,
		life = profile.life or 0,
		essence = profile.essence or 0,
		bestFloor = profile.bestFloor or 0,
		rolls = profile.rolls or 0,
		divines = profile.divines or 0,
		pity = profile.pity or 0,
		autoRoll = profile.autoRoll or false,
		daily = profile.daily,
		pendingOffline = nil,
		battle = nil,
		power = 0,
		perSecond = 0,
		autoNextAt = 0,
	}

	recompute(state)

	local away = os.time() - (profile.lastSeen or os.time())
	if away >= Content.offline.minSeconds and state.perSecond > 0 then
		local offlineLevel = state.upgrades.offline or 0
		local result = OfflineEarnings.compute(state.perSecond, away, {
			minSeconds = Content.offline.minSeconds,
			temporalCap = Content.offlineCapSeconds(offlineLevel),
			relativeCapMultiple = Content.offline.relativeCapMultiple,
			currentBalance = math.min(1e15, PlayerStore.riftNumber(state)),
		})
		if result.amount > 0 then
			state.pendingOffline = {
				seconds = result.secondsPaid,
				amount = result.amount,
				capped = result.capped,
			}
		end
	end

	states[player.UserId] = state
	Debug.count("players.loaded")
	PlayerStore.push(player)
end

function PlayerStore.install()
	Save.observe(function(player, profile)
		loadState(player, profile)
	end)

	Save.onSaving:Connect(function(player, profile)
		local state = states[player.UserId]
		if state ~= nil then
			PlayerStore.persist(state)
		else
			profile.lastSeen = os.time()
		end
	end)

	Save.onReleased:Connect(function(player)
		states[player.UserId] = nil
	end)
end

return PlayerStore
