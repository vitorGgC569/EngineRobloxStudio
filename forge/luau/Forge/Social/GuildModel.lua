--!strict
--[[
	GuildModel — persistent group with ranks, funds and upgrades.

	Guild data lives in one record mutated atomically by the server; this
	model owns the rules: rank-gated actions (invite/exile/upgrade),
	donations into shared funds, exponential upgrade cost. State in/out —
	no globals, no services.
]]

local GuildModel = {}

export type Rank = number

export type State = {
	name: string,
	funds: number,
	level: number,
	members: { [number]: Rank },
}

type Config = {
	maxMembers: number?,
	ranks: { [string]: Rank }?,
	upgradeBase: number?,
	upgradeGrowth: number?,
}

type Self = {
	maxMembers: number,
	leaderRank: Rank,
	officerRank: Rank,
	memberRank: Rank,
	upgradeBase: number,
	upgradeGrowth: number,
}

GuildModel.__index = GuildModel

function GuildModel.new(config: Config?): Self
	local cfg = config or {}
	local ranks = cfg.ranks or { Leader = 3, Officer = 2, Member = 1 }
	return setmetatable({
		maxMembers = cfg.maxMembers or 30,
		leaderRank = ranks.Leader or 3,
		officerRank = ranks.Officer or 2,
		memberRank = ranks.Member or 1,
		upgradeBase = cfg.upgradeBase or 5000,
		upgradeGrowth = cfg.upgradeGrowth or 2,
	}, GuildModel)
end

function GuildModel.create(name: string): State
	assert(#name >= 3 and #name <= 24, "guild name must be 3..24 chars")
	return { name = name, funds = 0, level = 1, members = {} }
end

local function rankOf(state: State, userId: number): Rank?
	return state.members[userId]
end

local function countMembers(state: State): number
	local n = 0
	for _ in state.members do
		n += 1
	end
	return n
end

-- Invite and exile already copied the member map. Donate and upgrade cloned
-- only the top table, so writing a member on the returned state rewrote the
-- guild the caller still held.
local function copyState(state: State): State
	local newState = table.clone(state) :: any
	newState.members = table.clone(state.members)
	return newState
end

function GuildModel.invite(self: Self, state: State, byUserId: number, newUserId: number): (State?, string?)
	local rank = rankOf(state, newUserId)
	if rank then
		return nil, "already_member"
	end
	if (rankOf(state, byUserId) or 0) < self.officerRank then
		return nil, "insufficient_rank"
	end
	if countMembers(state) >= self.maxMembers then
		return nil, "guild_full"
	end
	-- NaN is not equal to itself, so a member stored under 0/0 cannot be
	-- found on the next lookup. Reject that id before the map is copied.
	if type(newUserId) ~= "number" or newUserId ~= newUserId then
		return nil, "invalid_user"
	end
	local newState = copyState(state)
	newState.members[newUserId] = self.memberRank
	return newState, nil
end

function GuildModel.exile(self: Self, state: State, byUserId: number, targetId: number): (State?, string?)
	local actorRank = rankOf(state, byUserId) or 0
	local targetRank = rankOf(state, targetId)
	if not targetRank then
		return nil, "not_a_member"
	end
	if actorRank < self.officerRank or (targetRank >= actorRank and byUserId ~= targetId) then
		return nil, "insufficient_rank"
	end
	local newState = copyState(state)
	newState.members[targetId] = nil
	return newState, nil
end

function GuildModel.donate(self: Self, state: State, userId: number, amount: number): (State?, string?)
	if not rankOf(state, userId) then
		return nil, "not_a_member"
	end
	-- NaN is not <= 0, and math.huge is a positive number, so either one
	-- lands in the returned funds. A missing type, a NaN, a non-positive
	-- amount, or an amount that is not below math.huge is invalid.
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 or not (amount < math.huge) then
		return nil, "invalid_amount"
	end
	local newState = copyState(state)
	newState.funds = state.funds + amount
	return newState, nil
end

function GuildModel.upgradeCost(self: Self, state: State): number
	return math.floor(self.upgradeBase * self.upgradeGrowth ^ (state.level - 1))
end

function GuildModel.applyUpgrade(self: Self, state: State): (State?, string?)
	-- NaN is not < cost, and math.huge is not < cost either, so both buy
	-- the upgrade. A missing type, a NaN, or a balance that is not below
	-- math.huge is not payable.
	if type(state.funds) ~= "number" or state.funds ~= state.funds or not (state.funds < math.huge) then
		return nil, "insufficient_funds"
	end
	local cost = self:upgradeCost(state)
	if state.funds < cost then
		return nil, "insufficient_funds"
	end
	local newState = copyState(state)
	newState.funds = state.funds - cost
	newState.level = state.level + 1
	return newState, nil
end

return GuildModel
