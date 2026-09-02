--!strict
-- Pure reward math. Coins and XP are 1:1. Unit-tested in tests/rewards.spec.luau.

export type RewardConfig = {
	ZombieKill: number,
	Conversion: number,
	FirstBlood: number,
	SurvivedRound: number,
	LastSurvivor: number,
	WinMultiplier: number,
}

export type RewardEvent = "ZombieKill" | "Conversion" | "FirstBlood" | "SurvivedRound" | "LastSurvivor"

local Rewards = {}

-- Rewards scale down linearly below fullRewardCount so tiny lobbies can't be farmed.
function Rewards.lobbyScale(playerCount: number, minPlayers: number, fullRewardCount: number): number
	if playerCount >= fullRewardCount then
		return 1
	end
	if playerCount < minPlayers then
		return 0
	end
	return playerCount / fullRewardCount
end

function Rewards.payout(
	config: RewardConfig,
	event: RewardEvent,
	opts: { won: boolean, playerCount: number, minPlayers: number, fullRewardCount: number }
): number
	local base = config[event]
	assert(base ~= nil, "unknown reward event: " .. tostring(event))
	local amount = base * Rewards.lobbyScale(opts.playerCount, opts.minPlayers, opts.fullRewardCount)
	if opts.won then
		amount *= config.WinMultiplier
	end
	return math.floor(amount + 0.5)
end

return Rewards
