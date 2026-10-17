--[[
	UpgradeService — what Rift buys, and the two claim buttons.

	Every mutation here follows the same four steps in the same order:
	mutate the state, recompute the derived numbers, write the save, push the
	interface. A push before a recompute shows a power value one purchase
	stale; a write before a push persists a state the player never saw.

	Prices come from Content by id. The client sends an id and nothing else --
	a price read off the wire is a price an exploiter edits.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage.Shared.Content)
local Format = require(ReplicatedStorage.Shared.Format)
local PlayerStore = require(script.Parent.PlayerStore)

local Net = Forge.Net
local Telemetry = Forge.Telemetry
local Balance = Forge.Economy.Balance
local DailyRewardCalendar = Forge.Progression.DailyRewardCalendar

local UpgradeService = {}

--[[
	One calendar for the whole server. `now` defaults to `os.time`, and the
	state it reads and returns is the same plain table that lives in the save
	file -- so a claim survives a restart between the click and the write.
]]
local calendar = DailyRewardCalendar.new({
	milestones = Content.daily.milestones,
	cycleLength = Content.daily.cycleLength,
})

local started = false

-- ============================== upgrading ==================================

local function onUpgrade(player, payload)
	local state = PlayerStore.forPlayer(player)
	if state == nil then
		return
	end

	--: The id is the only thing the wire carries; the price is looked up.
	local upgrade = Content.upgrade(payload.id)
	if upgrade == nil then
		return
	end

	local level = state.upgrades[payload.id] or 0
	if level >= upgrade.maxLevel then
		PlayerStore.notify(player, "Already maxed")
		return
	end

	local cost = Content.upgradeCost(payload.id, level)
	if not PlayerStore.payRift(state, cost) then
		PlayerStore.notify(player, "Not enough Rift")
		return
	end

	state.upgrades[payload.id] = level + 1
	if payload.id == "autoroll" then
		--: Buying Auto Summon turns it on. The toggle only exists after the
		--: purchase, so the feature switching itself on is the only way it
		--: can ever have been on.
		state.autoRoll = true
	end
	PlayerStore.recompute(state)
	PlayerStore.write(state)
	PlayerStore.push(player)
	Telemetry.event("upgrade", { id = payload.id, level = level + 1 })
end

-- =============================== ascension =================================

local function onAscend(player)
	local state = PlayerStore.forPlayer(player)
	if state == nil then
		return
	end

	local required = Content.ascendRequiredFloor(state.life)
	if state.bestFloor < required then
		PlayerStore.notify(player, "Reach floor " .. required .. " to ascend")
		return
	end

	--: Stop any fight first: a battle left mid-flight would be paid out after
	--: the reset, against a power the player no longer owns.
	state.battle = nil

	local gain = Content.ascendEssenceGain(state.bestFloor, PlayerStore.uniqueCount(state.collection))
	state.life += 1
	state.essence += gain

	--[[
		The reset. Upgrades and Rift go; collection, equipped, bestFloor,
		rolls, pity, divines and the daily streak stay. Gems are premium and
		survive by rebuilding the wallet around them -- "rift to zero" must not
		mean "wallet to zero".
	]]
	state.upgrades = {}
	state.autoRoll = false
	local gems = state.wallet:get("gems")
	state.wallet = Balance.new({
		currencies = {
			rift = { start = 0, big = true },
			gems = { start = 0 },
		},
	})
	state.wallet:credit({ gems = gems })

	PlayerStore.recompute(state)
	PlayerStore.write(state)
	PlayerStore.push(player)
	PlayerStore.notify(player, "Ascended. +" .. gain .. " Essence (x" .. string.format("%.2f", 1 + Content.essenceMultiplierPer * state.essence) .. " income)")
	PlayerStore.announce({
		name = player.DisplayName,
		userId = player.UserId,
		ascend = true,
		life = state.life,
		essenceGain = gain,
	})
	Telemetry.event("ascend", { life = state.life, gain = gain })
end

-- ================================ claims ===================================

local function onClaimDaily(player)
	local state = PlayerStore.forPlayer(player)
	if state == nil then
		return
	end

	local newState, reward, info = calendar:claim(state.daily)
	if not info.granted then
		PlayerStore.notify(player, "Already claimed today")
		return
	end

	state.daily = newState
	reward = reward or {}
	PlayerStore.creditRift(state, reward.rift or 0)
	PlayerStore.creditGems(state, reward.gems or 0)
	PlayerStore.write(state)
	PlayerStore.push(player)
	PlayerStore.notify(player, "Daily reward: " .. Content.dailyRewardText(reward))
end

local function onClaimOffline(player)
	local state = PlayerStore.forPlayer(player)
	if state == nil or state.pendingOffline == nil then
		return
	end

	PlayerStore.creditRift(state, state.pendingOffline.amount)
	local text = Format.big(state.pendingOffline.amount)
	state.pendingOffline = nil
	PlayerStore.write(state)
	PlayerStore.push(player)
	PlayerStore.notify(player, "Dream Training paid " .. text .. " Rift")
end

-- ================================ lifecycle ================================

function UpgradeService.start()
	if started then
		return
	end
	started = true

	Net.on("Upgrade", onUpgrade)
	Net.on("Ascend", onAscend)
	Net.on("ClaimDaily", onClaimDaily)
	Net.on("ClaimOffline", onClaimOffline)
end

return UpgradeService
