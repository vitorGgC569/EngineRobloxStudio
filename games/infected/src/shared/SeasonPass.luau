--!strict
-- Pure season-pass logic (no Roblox services, unit-testable). A time-boxed track that
-- resets every SeasonLengthDays, distinct from the permanent account level: players earn
-- season XP from the same events, climb tiers, and claim per-tier rewards on a free track
-- (everyone) and a premium track (VIP gamepass owners). Which season you're in is derived
-- from the day number, so only progress + claim state persist.

local SeasonPass = {}

export type Reward = { coins: number, keys: number, pzTokens: number }
export type TierReward = { tier: number, free: Reward, premium: Reward }

SeasonPass.SeasonLengthDays = 28
SeasonPass.XpPerTier = 1000
SeasonPass.MaxTier = 30

local XP_PER_EVENT: { [string]: number } = {
	convert = 50,
	kill = 15,
	win = 200,
	survive = 80,
	playRounds = 40,
}

function SeasonPass.seasonId(dayNumber: number): number
	return math.floor(dayNumber / SeasonPass.SeasonLengthDays)
end

function SeasonPass.xpForEvent(metric: string): number
	return XP_PER_EVENT[metric] or 0
end

-- Tier reached at a given season XP total (1-based, capped at MaxTier).
function SeasonPass.tierForXp(xp: number): number
	if xp < SeasonPass.XpPerTier then
		return 0
	end
	return math.min(SeasonPass.MaxTier, math.floor(xp / SeasonPass.XpPerTier))
end

-- XP into the current tier and the span of a tier, for a progress bar.
function SeasonPass.progress(xp: number): (number, number, number)
	local tier = SeasonPass.tierForXp(xp)
	local into = xp - tier * SeasonPass.XpPerTier
	return tier, math.min(into, SeasonPass.XpPerTier), SeasonPass.XpPerTier
end

-- The free + premium reward at a tier. Escalates, with key/token milestones.
function SeasonPass.rewardAt(tier: number): TierReward
	return {
		tier = tier,
		free = {
			coins = 100 + tier * 10,
			keys = (tier % 5 == 0) and 1 or 0,
			pzTokens = 0,
		},
		premium = {
			coins = 250 + tier * 20,
			keys = (tier % 3 == 0) and 1 or 0,
			pzTokens = (tier % 10 == 0) and 1 or 0,
		},
	}
end

return SeasonPass
