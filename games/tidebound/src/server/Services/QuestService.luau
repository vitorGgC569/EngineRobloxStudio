--!strict
--[[
	QuestService — the three daily errands.

	The day's quests are a pure function of (player, date, level, zones), so
	this service mostly owns *timing*: when to re-roll, when to tell the
	client, and when a claim is allowed. Progress itself is `Quests.apply`,
	which is shared code exercised by tests.

	Selling counts through the same `record` entry point as catching, so a
	"sell $4,000" quest hears about sales without EconomyService knowing
	quests exist beyond that one call.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Net = Forge.Net
local Debug = Forge.Debug
local Save = Forge.Save

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local Items = require(Shared.Items)
local Quests = require(Shared.Quests)

local DataService = require(script.Parent.DataService)

local QuestService = {}

local function unlockedZones(profile: any): { string }
	local out = {}
	for _, zone in Config.zones do
		if profile.zones[zone.id] then
			table.insert(out, zone.id)
		end
	end
	if #out == 0 then
		table.insert(out, "shallows")
	end
	return out
end

--: Roll today's list if it is stale, and refresh the login streak. Called on
--: load and before any claim, so a player who leaves the tab open across
--: midnight is looking at the right day.
function QuestService.ensure(player: Player): any?
	local profile = DataService.profile(player)
	if not profile then
		return nil
	end
	local quests = profile.quests
	DataService.rollLogin(player)
	local today = Format.dayKey()
	if quests.day ~= today or #quests.list == 0 then
		quests.day = today
		local level = Config.levelForXp(profile.xp or 0)
		quests.list = Quests.roll(player.UserId, today, level, unlockedZones(profile))
		Debug.count("quests.rolled")
	end
	return quests
end

function QuestService.sync(player: Player)
	local quests = QuestService.ensure(player)
	if not quests then
		return
	end
	Net.fire(player, "QuestSync", {
		day = quests.day,
		streak = quests.streak,
		dailyClaimed = quests.dailyClaimed,
		login = Quests.loginReward(quests.streak),
		multiplier = Quests.streakMultiplier(quests.streak),
		list = quests.list,
	})
end

--: Feed one gameplay event through every open quest. Returns true when
--: anything moved, which is the cue to sync.
function QuestService.record(player: Player, event: any): boolean
	local quests = QuestService.ensure(player)
	if not quests then
		return false
	end
	local moved = false
	for _, quest in quests.list do
		if not quest.claimed then
			local next_ = Quests.apply(quest, event)
			if next_ and next_ ~= quest.progress then
				local wasComplete = (quest.progress or 0) >= quest.target
				quest.progress = next_
				moved = true
				if not wasComplete and next_ >= quest.target then
					Net.fire(player, "Notify", { text = string.format("Quest ready: %s", quest.label), tone = "good" })
					Debug.count("quests.completed")
				end
			end
		end
	end
	if moved then
		QuestService.sync(player)
		DataService.push(player)
	end
	return moved
end

-- ================================= claims ===================================
local function claimQuest(player: Player, id: string)
	local quests = QuestService.ensure(player)
	if not quests then
		return
	end
	for _, quest in quests.list do
		if quest.id == id then
			if quest.claimed then
				return
			end
			if (quest.progress or 0) < quest.target then
				Net.fire(player, "Notify", { text = "Not done yet." })
				return
			end
			quest.claimed = true
			local multiplier = Quests.streakMultiplier(quests.streak)
			local coins = math.floor(quest.rewardCoins * multiplier)
			DataService.addCoins(player, coins)
			DataService.addXp(player, quest.rewardXp)
			Debug.count("quests.claimed")
			Net.fire(player, "Notify", { text = string.format("Quest paid: +$%d", coins), tone = "good" })
			QuestService.sync(player)
			DataService.push(player, true)
			return
		end
	end
end

local function claimDaily(player: Player)
	local quests = QuestService.ensure(player)
	if not quests then
		return
	end
	if quests.dailyClaimed then
		Net.fire(player, "Notify", { text = "Already claimed today. Come back tomorrow." })
		return
	end
	local profile = DataService.profile(player)
	local reward = Quests.loginReward(quests.streak)
	quests.dailyClaimed = true
	DataService.addCoins(player, reward.coins)
	local text = string.format("Day %d: +$%d", quests.streak, reward.coins)
	if reward.bait and reward.qty > 0 and profile then
		local bait = reward.bait
		local owned = profile.baits.owned
		owned[bait] = math.min((owned[bait] or 0) + reward.qty, 99)
		local baitInfo = Items.baitById[bait]
		text ..= string.format(" and %dx %s", reward.qty, baitInfo and baitInfo.name or bait)
	end
	Debug.count("daily.claims")
	Net.fire(player, "Notify", { text = text, tone = "good" })
	QuestService.sync(player)
	DataService.push(player, true)
end

-- ================================== start ===================================
function QuestService.start()
	Save.observe(function(player: Player)
		QuestService.ensure(player)
		QuestService.sync(player)
		DataService.push(player)
	end)

	Net.on("ClaimQuest", function(player: Player, payload: any)
		if type(payload.questId) == "string" then
			claimQuest(player, payload.questId)
		end
	end)

	Net.on("ClaimDaily", function(player: Player)
		claimDaily(player)
	end)

	Debug.info("quests armed")
end

return QuestService
