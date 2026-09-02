--!strict
-- Retention loops: daily login-streak rewards (Phase C). Owns the server side of the
-- daily reward — evaluates streak state on join, grants on claim, and pushes status to
-- the client. Quests/season live in their own slices but will hang off this service.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DailyReward = require(Shared.DailyReward)
local Quests = require(Shared.Quests)
local SeasonPass = require(Shared.SeasonPass)

local RetentionService = {}
RetentionService.__index = RetentionService

export type Deps = {
	remotes: any,
	dataService: any,
	-- Injectable clock so tests / Studio can control "today"; defaults to os.time.
	now: (() -> number)?,
	-- Whether the player owns the premium season track (VIP). Defaults to false.
	isPremium: ((player: Player) -> boolean)?,
}

function RetentionService.new(deps: Deps)
	local self = setmetatable({}, RetentionService)
	self._deps = deps
	self._now = deps.now or os.time
	return self
end

function RetentionService:_today(): number
	return DailyReward.dayNumber(self._now())
end

-- Push the player's current daily status (claimable? which reward? streak?) to the client.
function RetentionService:pushStatus(player: Player)
	local data = self._deps.dataService:get(player)
	if data == nil then
		return
	end
	local result = DailyReward.evaluate(data.daily, self:_today())
	self._deps.remotes.fireClient("DailyStatus", player, {
		claimable = result.claimable,
		streak = result.claimable and result.streak or data.daily.streak,
		reward = result.reward,
	})
end

function RetentionService:claim(player: Player)
	local data = self._deps.dataService:get(player)
	if data == nil then
		return
	end
	local result = DailyReward.evaluate(data.daily, self:_today())
	if not result.claimable or result.reward == nil then
		self:pushStatus(player) -- resend so the client UI reflects reality
		return
	end
	local reward = result.reward
	data.daily.streak = result.streak
	data.daily.lastClaimDay = self:_today()
	data.coins += reward.coins
	data.xp += reward.xp
	data.crateKeys += reward.keys
	self._deps.dataService:sync(player)
	self._deps.remotes.fireClient("DailyClaimed", player, {
		streak = result.streak,
		reward = reward,
	})
	self:pushStatus(player)
end

-- Quests ------------------------------------------------------------------------

function RetentionService:_periodFor(scope: string): number
	local today = self:_today()
	return scope == "weekly" and Quests.periodWeekly(today) or Quests.periodDaily(today)
end

-- Roll a scope over to the current period, clearing progress + claims if it changed.
function RetentionService:_ensurePeriod(data: any, scope: string)
	local store = data.quests[scope]
	local period = self:_periodFor(scope)
	if store.period ~= period then
		store.period = period
		store.progress = {}
		store.claimed = {}
	end
end

-- Build the resolved quest list the client renders (quest def + progress + claimable).
function RetentionService:_resolvedScope(player: Player, data: any, scope: string): { any }
	self:_ensurePeriod(data, scope)
	local store = data.quests[scope]
	local out = {}
	for _, quest in Quests.assignmentFor(scope, store.period, player.UserId) do
		local state = Quests.state(quest, store.progress[quest.id] or 0, store.claimed[quest.id] == true)
		table.insert(out, {
			id = quest.id,
			desc = quest.desc,
			target = quest.target,
			progress = state.progress,
			claimable = state.claimable,
			claimed = store.claimed[quest.id] == true,
			coins = quest.coins,
			keys = quest.keys,
			xp = quest.xp,
		})
	end
	return out
end

function RetentionService:pushQuests(player: Player)
	local data = self._deps.dataService:get(player)
	if data == nil then
		return
	end
	self._deps.remotes.fireClient("QuestStatus", player, {
		daily = self:_resolvedScope(player, data, "daily"),
		weekly = self:_resolvedScope(player, data, "weekly"),
	})
end

-- Increment quest progress for a metric event (convert/kill/win/survive/playRounds).
function RetentionService:recordEvent(player: Player, metric: string, amount: number)
	local data = self._deps.dataService:get(player)
	if data == nil then
		return
	end
	local changed = false
	for _, scope in { "daily", "weekly" } do
		self:_ensurePeriod(data, scope)
		local store = data.quests[scope]
		for _, quest in Quests.assignmentFor(scope, store.period, player.UserId) do
			if quest.metric == metric and (store.claimed[quest.id] ~= true) then
				local current = store.progress[quest.id] or 0
				if current < quest.target then
					store.progress[quest.id] = math.min(quest.target, current + amount)
					changed = true
				end
			end
		end
	end
	if changed then
		self:pushQuests(player)
	end

	-- Season XP from the same event.
	local seasonXp = SeasonPass.xpForEvent(metric) * amount
	if seasonXp > 0 then
		self:_ensureSeason(data)
		data.season.xp += seasonXp
		self:pushSeason(player)
	end
end

function RetentionService:claimQuest(player: Player, scope: string, questId: string)
	local data = self._deps.dataService:get(player)
	if data == nil then
		return
	end
	self:_ensurePeriod(data, scope)
	local store = data.quests[scope]
	-- The quest must be one currently assigned to this player.
	local quest = nil
	for _, q in Quests.assignmentFor(scope, store.period, player.UserId) do
		if q.id == questId then
			quest = q
			break
		end
	end
	if quest == nil then
		return
	end
	local state = Quests.state(quest, store.progress[quest.id] or 0, store.claimed[quest.id] == true)
	if not state.claimable then
		return
	end
	store.claimed[quest.id] = true
	data.coins += quest.coins
	data.xp += quest.xp
	data.crateKeys += quest.keys
	self._deps.dataService:sync(player)
	self:pushQuests(player)
end

-- Season pass -------------------------------------------------------------------

function RetentionService:_ensureSeason(data: any)
	local id = SeasonPass.seasonId(self:_today())
	if data.season.id ~= id then
		data.season.id = id
		data.season.xp = 0
		data.season.claimedFree = {}
		data.season.claimedPremium = {}
	end
end

function RetentionService:_isPremium(player: Player): boolean
	return self._deps.isPremium ~= nil and self._deps.isPremium(player) == true
end

function RetentionService:pushSeason(player: Player)
	local data = self._deps.dataService:get(player)
	if data == nil then
		return
	end
	self:_ensureSeason(data)
	local tier, into, span = SeasonPass.progress(data.season.xp)
	local premium = self:_isPremium(player)
	local tiers = {}
	for t = 1, SeasonPass.MaxTier do
		local reward = SeasonPass.rewardAt(t)
		local key = tostring(t)
		table.insert(tiers, {
			tier = t,
			reached = tier >= t,
			free = reward.free,
			premium = reward.premium,
			freeClaimed = data.season.claimedFree[key] == true,
			premiumClaimed = data.season.claimedPremium[key] == true,
			freeClaimable = tier >= t and data.season.claimedFree[key] ~= true,
			premiumClaimable = tier >= t and premium and data.season.claimedPremium[key] ~= true,
		})
	end
	self._deps.remotes.fireClient("SeasonStatus", player, {
		id = data.season.id,
		tier = tier,
		into = into,
		span = span,
		premium = premium,
		maxTier = SeasonPass.MaxTier,
		tiers = tiers,
	})
end

function RetentionService:claimSeasonTier(player: Player, tier: number, track: string)
	local data = self._deps.dataService:get(player)
	if data == nil then
		return
	end
	self:_ensureSeason(data)
	local reached = SeasonPass.tierForXp(data.season.xp)
	if tier < 1 or tier > SeasonPass.MaxTier or reached < tier then
		return
	end
	local reward = SeasonPass.rewardAt(tier)
	local key = tostring(tier)
	local payout
	if track == "premium" then
		if not self:_isPremium(player) or data.season.claimedPremium[key] == true then
			return
		end
		data.season.claimedPremium[key] = true
		payout = reward.premium
	else
		if data.season.claimedFree[key] == true then
			return
		end
		data.season.claimedFree[key] = true
		payout = reward.free
	end
	data.coins += payout.coins
	data.crateKeys += payout.keys
	data.pzTokens += payout.pzTokens
	self._deps.dataService:sync(player)
	self:pushSeason(player)
end

function RetentionService:markTutorialSeen(player: Player)
	local data = self._deps.dataService:get(player)
	if data and not data.seenTutorial then
		data.seenTutorial = true
		self._deps.dataService:sync(player)
	end
end

-- Called by DataService once a player's profile is ready.
function RetentionService:onPlayerReady(player: Player)
	self:pushStatus(player)
	self:pushQuests(player)
	self:pushSeason(player)
end

function RetentionService:start()
	self._deps.remotes.onValidated("ClaimDaily", function(player)
		self:claim(player)
	end)
	self._deps.remotes.onValidated("ClaimQuest", function(player, payload)
		self:claimQuest(player, payload.scope, payload.questId)
	end)
	self._deps.remotes.onValidated("MarkTutorialSeen", function(player)
		self:markTutorialSeen(player)
	end)
	self._deps.remotes.onValidated("ClaimSeasonTier", function(player, payload)
		self:claimSeasonTier(player, payload.tier, payload.track)
	end)
	-- Any players already in (Studio start / hot reload) get their status pushed.
	for _, player in Players:GetPlayers() do
		if self._deps.dataService:get(player) ~= nil then
			self:pushStatus(player)
			self:pushQuests(player)
		end
	end
end

return RetentionService
