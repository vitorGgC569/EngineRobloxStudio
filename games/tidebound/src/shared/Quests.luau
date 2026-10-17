--!strict
--[[
	Quests — three daily errands and a streak.

	The roll is a pure function of `(userId, dayKey, level, unlocked zones)`.
	No stored randomness, no server handshake: two servers on opposite sides
	of the world hand the same player the same three quests, because the
	inputs are the same.

	Quest state is per-day: `profile.quests.day` holds the key, and a profile
	whose key is stale is re-rolled on load. Nothing needs a timer.
]]

local Config = require(script.Parent.Config)
local FishCatalog = require(script.Parent.FishCatalog)

local Quests = {}

--: Streak: consecutive days with at least the login recorded. The bonus is a
--: multiplier on every quest reward, capped so a long break is a bump, not a
--: wall.
Quests.streakBonusCap = 0.5
function Quests.streakMultiplier(streak: number): number
	return 1 + math.min((streak - 1) * 0.05, Quests.streakBonusCap)
end

--: The seven-day login calendar, cycled. Day index is (streak - 1) % 7.
Quests.loginRewards = {
	{ coins = 250, bait = nil, qty = 0 },
	{ coins = 400, bait = "worm", qty = 5 },
	{ coins = 650, bait = nil, qty = 0 },
	{ coins = 900, bait = "shrimp", qty = 5 },
	{ coins = 1400, bait = nil, qty = 0 },
	{ coins = 2100, bait = "squid", qty = 5 },
	{ coins = 3200, bait = "glow", qty = 3 },
}

function Quests.loginReward(streak: number): any
	local index = (math.max(streak, 1) - 1) % #Quests.loginRewards + 1
	return Quests.loginRewards[index]
end

-- ============================== deterministic rng ===========================
local function makeRng(seed: number): () -> number
	local state = seed % 4294967296
	return function(): number
		state = (state * 1664525 + 1013904223) % 4294967296
		return state / 4294967296
	end
end

local function seedFrom(userId: number, dayKey: string): number
	local seed = userId % 1000003
	for index = 1, #dayKey do
		seed = (seed * 31 + string.byte(dayKey, index)) % 4294967296
	end
	return seed
end

-- ================================= templates ================================
local TEMPLATES = {
	{
		kind = "zone", weight = 10, minLevel = 1,
		build = function(rng: () -> number, level: number, unlocked: { string })
			local zoneId = unlocked[math.floor(rng() * #unlocked) + 1]
			local zone = Config.zone(zoneId)
			local target = 8 + math.floor(rng() * 7)
			return {
				kind = "zone", zoneId = zoneId, target = target,
				label = string.format("Catch %d fish in %s", target, zone.name),
			}
		end,
	},
	{
		kind = "rarity", weight = 8, minLevel = 3,
		build = function(rng: () -> number, level: number)
			local target = 4 + math.floor(rng() * 5)
			local minRarity = if level >= 25 then "rare" else "uncommon"
			return {
				kind = "rarity", minRarity = minRarity, target = target,
				label = string.format("Catch %d %s fish or better", target, minRarity),
			}
		end,
	},
	{
		kind = "big", weight = 7, minLevel = 2,
		build = function(rng: () -> number, level: number)
			local scales = { 8, 15, 30, 60, 120, 250 }
			local band = math.clamp(math.floor(level / 9) + 1, 1, #scales)
			local target = scales[band]
			return {
				kind = "big", minKg = target, target = 1,
				label = string.format("Land a fish over %d kg", target),
			}
		end,
	},
	{
		kind = "weather", weight = 6, minLevel = 4,
		build = function(rng: () -> number)
			local target = 4 + math.floor(rng() * 4)
			return {
				kind = "weather", weather = "rain", target = target,
				label = string.format("Catch %d fish during rain", target),
			}
		end,
	},
	{
		kind = "perfect", weight = 6, minLevel = 3,
		build = function(rng: () -> number)
			local target = 3 + math.floor(rng() * 4)
			return {
				kind = "perfect", target = target,
				label = string.format("Land %d clean catches (85%%+ line)", target),
			}
		end,
	},
	{
		kind = "sell", weight = 7, minLevel = 1,
		build = function(rng: () -> number, level: number)
			local target = math.floor((900 + level * 220) * (0.8 + rng() * 0.5))
			target = math.floor(target / 50 + 0.5) * 50
			return {
				kind = "sell", target = target,
				label = string.format("Sell %s in catches", "$" .. tostring(target)),
			}
		end,
	},
	{
		kind = "variety", weight = 5, minLevel = 5,
		build = function(rng: () -> number)
			local target = 5 + math.floor(rng() * 4)
			return {
				kind = "variety", target = target,
				label = string.format("Catch %d different species", target),
			}
		end,
	},
	{
		kind = "mutation", weight = 3, minLevel = 8,
		build = function(rng: () -> number)
			local target = 1 + math.floor(rng() * 2)
			return {
				kind = "mutation", target = target,
				label = string.format("Catch %d mutated fish", target),
			}
		end,
	},
}

--[[
	Roll the day's three quests.

	Weighted, without replacement: two quests to sell fish in the same day is
	not variety, it is one quest listed twice.
]]
function Quests.roll(userId: number, dayKey: string, level: number, unlockedZones: { string }): { any }
	local rng = makeRng(seedFrom(userId, dayKey))
	local pool = {}
	for _, template in TEMPLATES do
		if level >= template.minLevel then
			table.insert(pool, template)
		end
	end
	local picked = {}
	local out = {}
	for _ = 1, 3 do
		if #pool == 0 then
			break
		end
		local total = 0
		for _, template in pool do
			total += template.weight
		end
		local point = rng() * total
		local running = 0
		local index = #pool
		for i, template in pool do
			running += template.weight
			if point <= running then
				index = i
				break
			end
		end
		local template = table.remove(pool, index)
		table.insert(picked, template)
	end

	for _, template in picked do
		local quest = template.build(rng, level, unlockedZones)
		--: Rewards scale with the target and the player's level, so a day-3
		--: quest pays like a day-3 quest.
		local scale = 1 + level / 10
		quest.id = string.format("%s_%d", quest.kind, #out + 1)
		quest.rewardCoins = math.floor((140 + quest.target * 45) * scale)
		quest.rewardXp = math.floor(70 * scale + quest.target * 12)
		quest.progress = 0
		quest.seen = {}
		quest.claimed = false
		table.insert(out, quest)
	end
	return out
end

-- ================================ progress ==================================
local RARITY_ORDER: { [string]: number } = {}
for _, tier in FishCatalog.rarities do
	RARITY_ORDER[tier.id] = tier.order
end

--[[
	Feed one catch or sale into a quest. Returns the quest's new progress, or
	nil when this event is not the quest's business.

	Kept beside the templates deliberately: a new quest kind that forgets to
	teach this function about itself simply never advances, which is visible
	in the first test run rather than in a review.
]]
function Quests.apply(quest: any, event: any): number?
	local progress = quest.progress or 0

	if quest.kind == "zone" then
		if event.kind == "catch" and event.zoneId == quest.zoneId then
			return math.min(progress + 1, quest.target)
		end
	elseif quest.kind == "rarity" then
		if event.kind == "catch" then
			local ordinal = RARITY_ORDER[event.rarity] or 0
			if ordinal >= (RARITY_ORDER[quest.minRarity] or 0) then
				return math.min(progress + 1, quest.target)
			end
		end
	elseif quest.kind == "big" then
		if event.kind == "catch" and event.weightKg >= quest.minKg then
			return 1
		end
	elseif quest.kind == "weather" then
		if event.kind == "catch" and event.weather == quest.weather then
			return math.min(progress + 1, quest.target)
		end
	elseif quest.kind == "perfect" then
		if event.kind == "catch" and event.integrity and event.integrity >= 0.85 then
			return math.min(progress + 1, quest.target)
		end
	elseif quest.kind == "sell" then
		if event.kind == "sell" then
			return math.min(progress + event.coins, quest.target)
		end
	elseif quest.kind == "variety" then
		if event.kind == "catch" then
			quest.seen = quest.seen or {}
			local key = tostring(event.speciesId)
			if not quest.seen[key] then
				quest.seen[key] = true
				return math.min(progress + 1, quest.target)
			end
		end
	elseif quest.kind == "mutation" then
		if event.kind == "catch" and event.mutation and event.mutation ~= "normal" then
			return math.min(progress + 1, quest.target)
		end
	end
	return nil
end

return Quests
