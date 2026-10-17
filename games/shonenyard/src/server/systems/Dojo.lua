--!strict
--[[
	Dojo — one player's yard: the state, the rules, and nothing else.

	No Instances here. This module decides what a summon, a placement, a rank
	and an ascension *mean*, against plain tables, so it can be reasoned about,
	saved, and played through in a headless test with no world existing.

	What it composes, and what it does not re-implement
	--------------------------------------------------

	Almost nothing in this file is arithmetic. The engine already owns it:

	    Loop.Hatch              the summon loop, and the funnel it declares
	    Economy.Balance         a multi-currency wallet with atomic spending
	    Economy.IncomeEngine    cached aggregation of passive contributors
	    Progression.RebirthLoop prestige pricing, stripped of side effects
	    Tycoon.ThroughputLedger idempotent count of what is live

	The one rule this file follows above the others: if something here starts
	to look like a formula, it is probably already written somewhere in
	`forge/luau/Forge` and this is a second copy of it that will drift.

	Why power is recomputed rather than accumulated
	-----------------------------------------------

	A fighter's contribution depends on the station it stands in, the dojo's
	rank, and how many times the player has ascended -- three things that
	change at different times. Keeping a running total means every one of them
	has to remember to adjust it, and the bug that produces is a number that is
	right on the screen and wrong in the ledger, always in the player's favour.

	`IncomeEngine` caches the aggregation and invalidates it on change, which
	is the same performance with none of the drift.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local Hatch = Forge.Loop.Hatch
local Balance = Forge.Economy.Balance
local IncomeEngine = Forge.Economy.IncomeEngine
local RebirthLoop = Forge.Progression.RebirthLoop
local Telemetry = Forge.Telemetry

local Dojo = {}

export type Placement = { station: string, fighters: { string } }

export type State = {
	key: string,
	wallet: any,
	income: any,
	--: Every fighter this player has ever summoned, by id, with a count. The
	--: count matters: a second Blade Dancer is a duplicate the player can
	--: place in a second station, and a collection that forgot duplicates
	--: would make the tenth summon feel like the first.
	roster: { [string]: number },
	stations: { [string]: Placement },
	rank: number,
	life: number,
	joinedAt: number,
	summons: number,
}

--[[
	The one summon loop, shared by every player in this server.

	Shared because the funnel is: two players' first summons are two data
	points in one report, and a loop per player would produce one funnel per
	player, which is not a funnel.

	The pity counter inside it is still per player -- `Loop.Hatch` keeps a
	crate per subject for exactly that reason.
]]
local loop = Hatch.new({
	theme = { noun = "scroll", verb = "unseal", collection = "roster" },
	drops = Content.drops(),
	tier2At = Content.tierTwoSeconds,
})
Dojo.loop = loop

--: Prestige pricing, from the engine, against the curve `Content` declares.
local ascension = RebirthLoop.new({
	price = function(life: number): number
		return Content.ascendPrice(life)
	end,
})

--: Wall clock, injectable so a test can move time without waiting for it.
function Dojo.clock(): number
	return os.time()
end

--[[
	The draw comes from a named, seeded stream. Not `math.random`.

	The bootstrap seeds `Rng` from `Config.seed` for exactly this reason, and
	summoning ignored it -- so every draw in this game came out of Roblox's
	ambient generator. Two consequences, and the second is the one that costs:

	  * a run is not reproducible, so "the first summon returned a rare"
	    cannot be told apart from a weighting bug by running it again;
	  * a scenario that draws is a test whose outcome is a random variable,
	    and a suite with one of those in it is a suite people stop believing.

	Found by a live scenario: the first summon in a fresh Studio came back at
	funnel step 4, which is a 3.4% draw. Headlessly, fifty first draws were
	fifty commons. One of those two was not measuring what it thought.
]]
local draws = Forge.Core.Rng.stream("shonenyard.summon")

function Dojo.roll(): number
	return draws:number()
end

-- =============================================================== the player

function Dojo.new(key: string): State
	local wallet = Balance.new({ currencies = Content.currencies })
	local income = IncomeEngine.new({ base = Content.baseIncomePerSecond })

	local state: State = {
		key = key,
		wallet = wallet,
		income = income,
		roster = {},
		stations = {
			--: The starting station, given rather than sold. A tycoon whose
			--: first purchase is the thing that produces anything has a
			--: chicken-and-egg problem the player experiences as "nothing
			--: happens".
			post = { station = "post", fighters = {} },
		},
		rank = 1,
		life = 1,
		joinedAt = Dojo.clock(),
		summons = 0,
	}
	Telemetry.seen(key, state.joinedAt)
	Dojo.recompute(state)
	return state
end

-- ================================================================== summon

--[[
	Unseal a scroll. The whole loop, in one call.

	Returns the fighter, whether it was new to the roster, and the funnel step
	it moved the player to -- so a caller can show a first-time reveal without
	recomputing what just happened.
]]
function Dojo.summon(state: State, scrollId: string): (any, boolean, number, string?)
	local scroll = Content.scroll(scrollId)
	if scroll == nil then
		return nil, false, 0, "no such scroll"
	end

	--: The first one is free regardless of which scroll was asked for, because
	--: a player who arrives and cannot afford anything has been shown nothing.
	local free = loop:isFree(state.key)
	if not free and scroll.cost > 0 then
		if not state.wallet:canAfford({ [scroll.currency] = scroll.cost }) then
			return nil, false, 0, "not enough " .. scroll.currency
		end
		state.wallet:debit({ [scroll.currency] = scroll.cost })
	end

	local drop, step = loop:open(state.key, Dojo.roll)
	local fighter = Content.fighter(drop.id)
	if fighter == nil then
		return nil, false, step, "the drop table names a fighter that does not exist"
	end

	local had = state.roster[fighter.id] or 0
	state.roster[fighter.id] = had + 1
	state.summons += 1
	Dojo.recompute(state)

	--: A rare summon pays shards. This is the only faucet for the second
	--: currency, which is what keeps it from becoming a second economy.
	if fighter.rarity >= 3 then
		state.wallet:credit({ shards = fighter.rarity })
	end

	return fighter, had == 0, step, nil
end

-- ================================================================= stations

function Dojo.buyStation(state: State, stationId: string): (boolean, string?)
	local station = Content.station(stationId)
	if station == nil then
		return false, "no such station"
	end
	if state.stations[stationId] ~= nil then
		return false, "already built"
	end
	if state.rank < station.tier then
		return false, string.format("needs rank %d", station.tier)
	end
	if not state.wallet:canAfford({ ki = station.cost }) then
		return false, "not enough ki"
	end
	state.wallet:debit({ ki = station.cost })
	state.stations[stationId] = { station = stationId, fighters = {} }
	Dojo.recompute(state)
	return true, nil
end

--[[
	Put a fighter to train.

	Refuses rather than silently swapping when the station is full. A silent
	swap is how a player loses a mythic to a mis-tap and does not find out for
	twenty minutes.
]]
function Dojo.assign(state: State, stationId: string, fighterId: string): (boolean, string?)
	local placement = state.stations[stationId]
	if placement == nil then
		return false, "that station is not built"
	end
	local station = Content.station(stationId)
	if #placement.fighters >= station.slots then
		return false, "that station is full"
	end

	--: Counted rather than flagged: a player with three Blade Dancers may
	--: station three of them, and a boolean "owned" would let them station
	--: thirty.
	local owned = state.roster[fighterId] or 0
	local placed = 0
	for _, other in state.stations do
		for _, id in other.fighters do
			if id == fighterId then
				placed += 1
			end
		end
	end
	if placed >= owned then
		return false, "every one of those is already training"
	end

	table.insert(placement.fighters, fighterId)
	Dojo.recompute(state)
	return true, nil
end

-- =================================================================== income

--[[
	What this yard produces per second, and why.

	Rebuilt from the placements rather than adjusted in place. See the header:
	three independent things move this number, and a running total means all
	three have to remember.
]]
function Dojo.recompute(state: State)
	local income = state.income
	for id in state.stations do
		income:removeContributor("station:" .. id)
	end

	for id, placement in state.stations do
		local station = Content.station(id)
		local produced = 0
		for _, fighterId in placement.fighters do
			local fighter = Content.fighter(fighterId)
			if fighter ~= nil then
				produced += fighter.power
			end
		end
		if produced > 0 then
			income:addContributor("station:" .. id, {
				kind = "add", value = produced * station.multiplier,
			})
		end
	end

	--: Rank and ascension multiply everything, and they are `mul` rather than
	--: `add` so a new station never dilutes them.
	income:setMultiplier("mul",
		Content.incomeMultiplierPerRank ^ (state.rank - 1)
		* Content.ascend.powerMultiplierPerLife ^ (state.life - 1))
end

function Dojo.perSecond(state: State): number
	return state.income:total()
end

--: One tick of production. Called by the driver, not by the player.
function Dojo.tick(state: State, delta: number): number
	local earned = Dojo.perSecond(state) * delta
	if earned > 0 then
		state.wallet:credit({ ki = earned })
	end
	return earned
end

-- ==================================================================== ranks

function Dojo.nextRank(state: State): any
	return Content.ranks[state.rank + 1]
end

function Dojo.promote(state: State): (boolean, string?)
	local next_ = Dojo.nextRank(state)
	if next_ == nil then
		return false, "this dojo is already sovereign"
	end
	--: Cumulative thresholds: what is paid is the difference from the rank
	--: below, which is what `Progression` means by a tier cost.
	local paid = next_.cost - (Content.ranks[state.rank].cost or 0)
	if not state.wallet:canAfford({ ki = paid }) then
		return false, string.format("needs %d more ki", math.ceil(
			paid - state.wallet:get("ki")))
	end
	state.wallet:debit({ ki = paid })
	state.rank += 1
	Dojo.recompute(state)

	--: The rung 74% of players in the only real retention record never
	--: reached. Marked so the funnel can say whether this one does better.
	if state.rank >= 2 then
		loop:reachedTierTwo(state.key)
	end
	return true, nil
end

-- ================================================================== ascend

function Dojo.ascendPrice(state: State): number
	return ascension:quote(state.life)
end

function Dojo.canAscend(state: State): boolean
	return ascension:canRebirth(state.wallet:get("ki"), state.life)
end

--[[
	Ascend: keep the roster, lose the yard, come back stronger.

	The roster survives on purpose. Everything else in this genre resets and
	the collection does not, because the collection is the reason to come back
	and burning it is how a prestige loop becomes a reason to stop.
]]
function Dojo.ascend(state: State): (boolean, string?)
	if not Dojo.canAscend(state) then
		return false, string.format("ascension costs %d ki",
			Dojo.ascendPrice(state))
	end

	state.life += 1
	state.rank = 1
	state.stations = { post = { station = "post", fighters = {} } }
	state.wallet = Balance.new({ currencies = Content.currencies })
	state.wallet:credit({ shards = Content.ascend.shardsPerLife })
	state.income = IncomeEngine.new({ base = Content.baseIncomePerSecond })
	Dojo.recompute(state)
	return true, nil
end

-- ============================================================== collection

function Dojo.collected(state: State): number
	local total = 0
	for _ in state.roster do
		total += 1
	end
	return total
end

function Dojo.collectedOfRarity(state: State, rarity: number): number
	local total = 0
	for id in state.roster do
		local fighter = Content.fighter(id)
		if fighter ~= nil and fighter.rarity == rarity then
			total += 1
		end
	end
	return total
end

--: Which milestones this player has earned but not been paid for. Returned
--: rather than granted, so the caller owns the moment.
function Dojo.claimableMilestones(state: State, claimed: { [string]: boolean }): { any }
	local out = {}
	for _, milestone in Content.milestones do
		if claimed[milestone.id] then
			continue
		end
		local have = if milestone.rarity
			then Dojo.collectedOfRarity(state, milestone.rarity)
			else Dojo.collected(state)
		if have >= milestone.need then
			table.insert(out, milestone)
		end
	end
	return out
end

--: The player looked at what they have. The funnel step that separates a
--: player who has a collection from one who knows they do.
function Dojo.sawCollection(state: State)
	loop:sawCollection(state.key)
end

--: A fighter was put to work: the step after the first summon.
function Dojo.kept(state: State)
	loop:kept(state.key)
end

-- ================================================================= reading

function Dojo.snapshot(state: State): { [string]: any }
	local roster = {}
	for id, count in state.roster do
		local fighter = Content.fighter(id)
		roster[id] = {
			count = count,
			name = fighter and fighter.name or id,
			rarity = fighter and fighter.rarity or 0,
		}
	end
	local stations = {}
	for id, placement in state.stations do
		stations[id] = {
			fighters = table.clone(placement.fighters),
			slots = Content.station(id).slots,
		}
	end
	return {
		key = state.key,
		ki = math.floor(state.wallet:get("ki")),
		shards = math.floor(state.wallet:get("shards")),
		perSecond = Dojo.perSecond(state),
		rank = state.rank,
		rankName = Content.ranks[state.rank].name,
		nextRank = Dojo.nextRank(state),
		life = state.life,
		ascendPrice = Dojo.ascendPrice(state),
		summons = state.summons,
		collected = Dojo.collected(state),
		ofTotal = #Content.fighters,
		roster = roster,
		stations = stations,
	}
end

--: What the loop says is going wrong for this player, right now. The three
--: rules `Loop.Hatch` carries, checked live rather than found in a report.
function Dojo.findings(state: State): { any }
	return loop:check(state.key)
end

return Dojo
