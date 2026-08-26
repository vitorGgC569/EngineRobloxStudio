--!strict
-- Pure XP/level curve. Level N requires cumulative XP of 100 * N^1.6 (rounded),
-- a gentle early ramp that stretches at high levels. Unit-tested.

local LevelMath = {}

function LevelMath.xpForLevel(level: number): number
	if level <= 1 then
		return 0
	end
	return math.floor(100 * (level - 1) ^ 1.6 + 0.5)
end

function LevelMath.levelForXp(xp: number): number
	if xp < 0 then
		return 1
	end
	local level = 1
	while LevelMath.xpForLevel(level + 1) <= xp do
		level += 1
	end
	return level
end

function LevelMath.progress(xp: number): (number, number, number)
	-- returns (currentLevel, xpIntoLevel, xpNeededForNext)
	local level = LevelMath.levelForXp(xp)
	local base = LevelMath.xpForLevel(level)
	local next_ = LevelMath.xpForLevel(level + 1)
	return level, xp - base, next_ - base
end

-- The reward for REACHING a given level: coins scale with the level, and every 5th level
-- also grants a crate key. Level 1 is the starting level, so it pays nothing.
function LevelMath.rewardForLevel(level: number): { coins: number, keys: number }
	if level <= 1 then
		return { coins = 0, keys = 0 }
	end
	return { coins = 50 * level, keys = (level % 5 == 0) and 1 or 0 }
end

-- Total reward for crossing from oldXp to newXp (sums every level gained). Returns the
-- new level, how many levels were gained, and the aggregate payout.
function LevelMath.levelUpRewards(
	oldXp: number,
	newXp: number
): { newLevel: number, levelsGained: number, coins: number, keys: number }
	local oldLevel = LevelMath.levelForXp(oldXp)
	local newLevel = LevelMath.levelForXp(newXp)
	local coins, keys = 0, 0
	for level = oldLevel + 1, newLevel do
		local reward = LevelMath.rewardForLevel(level)
		coins += reward.coins
		keys += reward.keys
	end
	return { newLevel = newLevel, levelsGained = math.max(0, newLevel - oldLevel), coins = coins, keys = keys }
end

return LevelMath
