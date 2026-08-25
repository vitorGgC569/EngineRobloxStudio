--!strict
--[[
	SeasonPass — tiered pass progress with free/premium tracks.

	Tiers cost escalating season XP; each tier grants a free reward and
	(optionally owned) a premium one. Claiming is idempotent per track
	and persisted as claimed sets, so reconnects cannot double-grant.
]]

local SeasonPass = {}

export type TierReward = { free: string?, premium: string? }

type Self = {
	xpPerTier: (tier: number) -> number,
	tiers: { TierReward },
}

SeasonPass.__index = SeasonPass

local function defaultXp(tier: number): number
	return 1000 * tier
end

function SeasonPass.new(config: { tiers: { TierReward }, xpPerTier: ((number) -> number)? }): Self
	assert(#config.tiers > 0, "need at least one tier")
	return setmetatable({
		tiers = config.tiers,
		xpPerTier = config.xpPerTier or defaultXp,
	}, SeasonPass)
end

-- state: { xp, tier, claimedFree={[n]=true}, claimedPremium={[n]=true}, premiumOwned }
function SeasonPass.addXp(self: Self, state: any, amount: number): ()
	assert(amount >= 0, "xp cannot be negative")
	state.xp += amount
	while state.tier < #self.tiers and state.xp >= self.xpPerTier(state.tier + 1) do
		state.xp -= self.xpPerTier(state.tier + 1)
		state.tier += 1
	end
end

function SeasonPass.claim(self: Self, state: any, tier: number, premium: boolean): (string?, string?)
	local def = self.tiers[tier]
	if not def then
		return nil, "unknown_tier"
	end
	if tier > state.tier then
		return nil, "tier_locked"
	end
	local field = if premium then "claimedPremium" else "claimedFree"
	local reward = if premium then def.premium else def.free
	if not reward then
		return nil, "no_reward"
	end
	if state[field][tier] then
		return nil, "already_claimed"
	end
	if premium and not state.premiumOwned then
		return nil, "premium_required"
	end
	state[field][tier] = true
	return reward, nil
end

return SeasonPass
