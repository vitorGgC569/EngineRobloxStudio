--!strict
-- Pure daily-login-streak logic (no Roblox services) so it is unit-testable. The server
-- passes in today's UTC day number and the player's stored {lastClaimDay, streak}; this
-- decides whether a reward is claimable and what the resulting state + payout are.
--
-- Streak rules:
--   • claiming on the calendar day right after your last claim continues the streak
--   • skipping a day (or more) resets the streak to 1
--   • claiming again the same day is a no-op (not claimable)
-- Rewards run on a repeating 7-day ladder that escalates, so day 7 is the payoff and the
-- cycle then repeats (with the streak count still climbing for leaderboards/flair).

local DailyReward = {}

export type State = { lastClaimDay: number, streak: number }
export type Reward = { coins: number, keys: number, xp: number }

-- A repeating 7-day ladder. Index by ((streak - 1) % 7) + 1.
local LADDER: { Reward } = {
	{ coins = 100, keys = 0, xp = 50 },
	{ coins = 150, keys = 0, xp = 75 },
	{ coins = 250, keys = 1, xp = 120 },
	{ coins = 400, keys = 0, xp = 180 },
	{ coins = 600, keys = 1, xp = 260 },
	{ coins = 800, keys = 2, xp = 360 },
	{ coins = 1500, keys = 3, xp = 600 },
}

DailyReward.Ladder = LADDER
DailyReward.CycleLength = #LADDER

-- UTC day number for a unix timestamp (whole days since epoch).
function DailyReward.dayNumber(unixSeconds: number): number
	return math.floor(unixSeconds / 86400)
end

-- The reward at a given streak position (1-based streak count).
function DailyReward.rewardFor(streak: number): Reward
	local index = ((math.max(1, streak) - 1) % #LADDER) + 1
	return LADDER[index]
end

-- Given stored state and today's day number, what happens if the player claims now.
--   claimable      : is a claim available today?
--   alreadyClaimed : did they already claim today?
--   streak         : the streak count AFTER claiming (equals current streak if not claimable)
--   reward         : the payout for this claim (nil if not claimable)
--   nextInSeconds  : ignored here; the client shows its own countdown
function DailyReward.evaluate(
	state: State,
	today: number
): { claimable: boolean, alreadyClaimed: boolean, streak: number, reward: Reward? }
	if state.lastClaimDay == today then
		return { claimable = false, alreadyClaimed = true, streak = state.streak, reward = nil }
	end
	local newStreak
	if state.lastClaimDay == today - 1 then
		newStreak = state.streak + 1
	else
		newStreak = 1 -- first ever claim, or a broken streak
	end
	return {
		claimable = true,
		alreadyClaimed = false,
		streak = newStreak,
		reward = DailyReward.rewardFor(newStreak),
	}
end

return DailyReward
