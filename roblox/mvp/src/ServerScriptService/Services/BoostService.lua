--!strict
-- Potions, rebirth, codes and daily rewards.
--
-- One place that answers "what multipliers does this player have right now",
-- because that number touches income, luck, mutation odds and activation time
-- at once. Computing it in four places is how an economy quietly drifts.
--
-- Nothing here trusts the client. Codes are matched server-side, potion
-- expiries are compared against the server clock, and a rebirth is checked
-- against lifetime earnings the server tracked itself.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PotionCatalog = require(ReplicatedStorage.Shared.PotionCatalog)
local RebirthCatalog = require(ReplicatedStorage.Shared.RebirthCatalog)
local RewardCatalog = require(ReplicatedStorage.Shared.RewardCatalog)

local BoostService = {}
BoostService.__index = BoostService

function BoostService.new()
	return setmetatable({}, BoostService)
end

local function ensure(data)
	data.potions = data.potions or {}
	data.activePotions = data.activePotions or {}
	data.redeemedCodes = data.redeemedCodes or {}
	data.rebirthLevel = data.rebirthLevel or 0
	data.lifetimeCash = data.lifetimeCash or 0
	data.purchasedMultipliers = data.purchasedMultipliers or { cash = 1, luck = 1 }
	return data
end

--- Everything that scales the game for this player, in one table.
function BoostService:multipliers(data)
	ensure(data)
	local now = os.time()
	local potions = PotionCatalog.multipliers(data.activePotions, now)
	local rebirth = RebirthCatalog.bonuses(data.rebirthLevel)
	local purchased = data.purchasedMultipliers

	return {
		cash = potions.cash * rebirth.cashMultiplier * (purchased.cash or 1),
		luck = potions.luck * (1 + rebirth.luckBonus) * (purchased.luck or 1),
		mutation = potions.mutation,
		production = potions.production,
		time = potions.time,
		slotBonus = rebirth.slotBonus,
		rebirthLevel = data.rebirthLevel,
	}
end

-- ---------------------------------------------------------------- potions

function BoostService:grantPotion(data, potionId: string, count: number?)
	ensure(data)
	if PotionCatalog.get(potionId) == nil then
		return { ok = false, reason = "no_such_potion" }
	end
	local amount = math.max(1, count or 1)
	data.potions[potionId] = (data.potions[potionId] or 0) + amount
	return { ok = true, potionId = potionId, held = data.potions[potionId] }
end

function BoostService:buyPotion(data, potionId: string)
	ensure(data)
	local potion = PotionCatalog.get(potionId)
	if potion == nil then
		return { ok = false, reason = "no_such_potion" }
	end
	if (data.currency or 0) < potion.price then
		return { ok = false, reason = "insufficient_funds", price = potion.price }
	end
	data.currency -= potion.price
	data.potions[potionId] = (data.potions[potionId] or 0) + 1
	return { ok = true, potionId = potionId, price = potion.price, held = data.potions[potionId] }
end

--- Drink one. Re-drinking a live potion extends it rather than stacking it,
--- so the multiplier ceiling stays where the economy was tuned for.
function BoostService:usePotion(data, potionId: string)
	ensure(data)
	local potion = PotionCatalog.get(potionId)
	if potion == nil then
		return { ok = false, reason = "no_such_potion" }
	end
	if (data.potions[potionId] or 0) <= 0 then
		return { ok = false, reason = "none_held" }
	end

	local now = os.time()
	data.activePotions = PotionCatalog.prune(data.activePotions, now)
	local current = data.activePotions[potionId]
	local base = if current and current > now then current else now
	data.activePotions[potionId] = base + potion.durationSeconds
	data.potions[potionId] -= 1

	return {
		ok = true,
		potionId = potionId,
		expiresAt = data.activePotions[potionId],
		remainingSeconds = data.activePotions[potionId] - now,
		held = data.potions[potionId],
	}
end

function BoostService:activePotions(data)
	ensure(data)
	local now = os.time()
	data.activePotions = PotionCatalog.prune(data.activePotions, now)
	local active = {}
	for id, expiresAt in pairs(data.activePotions) do
		table.insert(active, { potionId = id, remainingSeconds = expiresAt - now })
	end
	return active
end

-- ---------------------------------------------------------------- rebirth

--- Trade the run for a permanent multiplier.
---
--- Cards are kept and everything else resets. Losing the collection would make
--- rebirth feel like a punishment, and the collection is the thing players
--- actually attach to.
function BoostService:rebirth(data)
	ensure(data)
	local allowed, tier = RebirthCatalog.canRebirth(data.rebirthLevel, data.lifetimeCash)
	if tier == nil then
		return { ok = false, reason = "max_rebirth" }
	end
	if not allowed then
		return {
			ok = false,
			reason = "requirement_not_met",
			required = tier.requirement,
			lifetimeCash = data.lifetimeCash,
		}
	end

	data.rebirthLevel += 1
	data.currency = 0
	data.farm = nil
	data.luckLevel = 1

	local bonuses = RebirthCatalog.bonuses(data.rebirthLevel)
	return {
		ok = true,
		level = data.rebirthLevel,
		name = tier.name,
		cashMultiplier = bonuses.cashMultiplier,
		luckBonus = bonuses.luckBonus,
		slotBonus = bonuses.slotBonus,
	}
end

-- ------------------------------------------------------------------ codes

function BoostService:redeem(data, rawCode: string)
	ensure(data)
	local code = string.upper(string.gsub(tostring(rawCode), "%s", ""))
	local entry = RewardCatalog.CodeByText[code]
	if entry == nil then
		return { ok = false, reason = "invalid_code" }
	end
	if data.redeemedCodes[code] then
		return { ok = false, reason = "already_redeemed" }
	end

	data.redeemedCodes[code] = os.time()
	local applied = self:applyReward(data, entry.reward, entry.amount)
	return { ok = true, code = code, label = entry.label, reward = entry.reward, amount = entry.amount, applied = applied }
end

--- Apply a reward string like "cash" or "potion:luck".
function BoostService:applyReward(data, reward: string, amount: number)
	ensure(data)
	local kind, argument = string.match(reward, "^(%w+):?(.*)$")
	if kind == "cash" then
		data.currency = (data.currency or 0) + amount
		return { kind = "cash", amount = amount }
	elseif kind == "potion" and argument ~= "" then
		self:grantPotion(data, argument, amount)
		return { kind = "potion", potionId = argument, amount = amount }
	end
	return { kind = "unknown", reward = reward }
end

-- ------------------------------------------------------------------ daily

--- Which daily reward is owed, if any. Streaks reset after a missed day.
function BoostService:dailyStatus(data)
	ensure(data)
	local now = os.time()
	local day = math.floor(now / 86400)
	local lastDay = data.lastDailyDay or -1

	if lastDay == day then
		return { available = false, streak = data.dailyStreak or 1, nextInSeconds = ((day + 1) * 86400) - now }
	end

	local streak = if lastDay == day - 1 then math.min((data.dailyStreak or 0) + 1, 7) else 1
	return { available = true, streak = streak, reward = RewardCatalog.Daily[streak] }
end

function BoostService:claimDaily(data)
	ensure(data)
	local status = self:dailyStatus(data)
	if not status.available then
		return { ok = false, reason = "already_claimed", nextInSeconds = status.nextInSeconds }
	end

	local reward = status.reward
	data.lastDailyDay = math.floor(os.time() / 86400)
	data.dailyStreak = status.streak
	local applied = self:applyReward(data, reward.reward, reward.amount)

	return { ok = true, streak = status.streak, label = reward.label, applied = applied }
end

--- Record earnings so rebirth has something to measure against.
function BoostService:recordEarnings(data, amount: number)
	ensure(data)
	data.lifetimeCash = (data.lifetimeCash or 0) + math.max(0, amount)
	return data.lifetimeCash
end

return BoostService
