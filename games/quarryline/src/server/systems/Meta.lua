--!strict
--[[
	Meta — everything around the game rather than in it.

	Live events, promo codes, crates, purchases and where the numbers go. None
	of it is the tycoon; all of it is what makes a tycoon a live game rather
	than a toy.

	The rule this file exists to obey
	--------------------------------

	Anything that grants a player something must be **exactly once**. A crate
	that opens twice, a code redeemed twice, a purchase granted twice — each is
	silent, each inflates the economy, and none of them throws. So every grant
	here goes through something that remembers: `ReceiptLedger` for purchases,
	the profile's own redeemed set for codes, and `TransactionJournal` for
	anything that leaves one place before arriving somewhere else.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local Clock = Forge.Core.Clock
local Telemetry = Forge.Telemetry
local Monetization = Forge.Monetization
local GlobalEffects = Forge.LiveOps.GlobalEffects
local LiveOps = Forge.LiveOps

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Content = require(Shared:WaitForChild("Content"))

local CrateRoll = require(ReplicatedStorage.Forge.Progression.CrateRoll)
local PromoCodes = require(ReplicatedStorage.Forge.LiveOps.PromoCodes)

local Meta = {}

Meta.crate = nil :: any
Meta.codes = nil :: any
--[[
	What each code pays.

	`PromoCodes` deliberately holds only the *entitlement* — which reward id a
	code unlocks, and whether it needs an asset or a group. What the reward
	actually is stays here, in the game, because a library that knew what a
	coin was would be a library with an opinion about the game.
]]
local CODE_REWARDS = {
	welcome = { coins = 5000 },
	firstore = { coins = 1000 },
}

-- ================================== events ==================================
--[[
	What can be true for the whole server.

	Defined here and switched on somewhere else, deliberately: the definition
	is content and belongs in a file, the activation is an operational decision
	made at eleven at night. Anything requiring a code change to run will not
	be run.
]]
local function defineEvents()
	GlobalEffects.defineMany({
		double_coins = { coin = 2 },
		rush_hour = { coin = 1.5, ore = 1.5 },
		founders_weekend = { coin = 3 },
	})

	--[[
		`luck` adds rather than multiplies.

		Two "+5 luck" effects should be +10, not +25. It is the one axis in
		this game where the multiplicative default is wrong, and saying so is
		one line rather than a special case in every reader.
	]]
	GlobalEffects.addsUp("luck")

	-- Retire whatever has run out, every few seconds. A deadline is checked,
	-- never scheduled: a `task.delay` per effect is a promise a lagging server
	-- breaks silently.
	GlobalEffects.start(5)
end

-- ================================== crates ==================================
local function defineCrates()
	local drops = {}
	local rarity = 0
	for id, crate in Content.crates do
		rarity += 1
		table.insert(drops, { id = id, weight = crate.weight, rarity = rarity })
	end

	--[[
		Pity, because a weighted table is cruel over a small sample.

		The maths says one relic in thirty-three. The player who opens sixty
		without one does not experience probability, they experience a game
		that is lying to them. A guaranteed rare after the threshold costs
		almost nothing in expectation and removes the worst experience the
		table can produce.
	]]
	Meta.crate = CrateRoll.new({
		drops = drops,
		pityThreshold = 25,
		minRarityForPity = 3,
	})
end

--[[
	Open one crate.

	The roll is seeded from the day and the player, so two servers asked the
	same question give the same answer and a player who rejoins to reroll gets
	the same crate. That is not anti-cheat — it is the difference between a
	reward and a slot machine.
]]
function Meta.openCrate(player: Player, profile: any): (string?, number)
	local random = Clock.dailyRandom(string.format("crate:%d:%d",
		player.UserId, profile.cratesOpened or 0))
	-- `roll` answers with the whole drop, not just its id: the rarity comes
	-- back with it, which is what a reveal animation needs to know how loud
	-- to be.
	local drop = Meta.crate:roll(function()
		return random:NextNumber()
	end)
	if not drop then
		return nil, 0
	end

	profile.cratesOpened = (profile.cratesOpened or 0) + 1
	local coins = Content.crates[drop.id] and Content.crates[drop.id].coins or 0
	Telemetry.event("crate.opened", { id = drop.id, rarity = drop.rarity, coins = coins })
	return drop.id, coins
end

-- =================================== codes ==================================
local function defineCodes()
	Meta.codes = PromoCodes.new({
		QUARRY = { rewardId = "welcome" },
		FIRSTORE = { rewardId = "firstore" },
	})
end

--[[
	Redeem, once per player and never again.

	The redeemed set lives on the profile rather than in memory, because "once"
	has to survive a rejoin — and a server restart is exactly when somebody
	tries the code again.
]]
function Meta.redeem(player: Player, profile: any, code: string): (boolean, string)
	local redeemed = profile.redeemed
	if typeof(redeemed) ~= "table" then
		redeemed = {}
		profile.redeemed = redeemed
	end

	local key = string.upper(code)
	if redeemed[key] then
		return false, "you have already used that code"
	end

	--[[
		`redeem` takes the player's own redeemed set and decides.

		Passing the profile's table in rather than keeping a copy means "once"
		is stored where everything else about this player is stored, and
		survives a rejoin for the same reason their coins do.
	]]
	local state: { [string]: boolean } = {}
	for used in redeemed do
		state[used] = true
	end

	local ok, result = Meta.codes:redeem(key, state, {
		userId = player.UserId,
		ownsAsset = function()
			return false
		end,
		inGroup = function()
			return false
		end,
	})
	if not ok then
		return false, ({
			unknown_code = "that code does not work",
			already_redeemed = "you have already used that code",
			asset_required = "that code is for a pass you do not own",
			group_required = "that code is for group members",
		})[result] or "that code does not work"
	end

	local reward = CODE_REWARDS[result]
	if not reward then
		return false, "that code has no reward attached"
	end

	redeemed[key] = Clock.now()
	profile.coins += reward.coins
	profile.lifetimeCoins += reward.coins
	Telemetry.event("code.redeemed", { code = key })
	return true, string.format("Redeemed %s", key)
end

-- ================================== start ===================================
function Meta.start()
	defineEvents()
	defineCrates()
	defineCodes()

	--[[
		Where the numbers go, and what makes them go there.

		Two calls, and the difference between them cost provingground every
		event it ever raised: `dataStoreSink` chooses the destination and
		`start` is what drains the buffer into it. Without the second there is
		no periodic flush, no session events and no shutdown flush.
	]]
	Telemetry.dataStoreSink()
	Telemetry.start()

	Monetization.start()

	Debug.probe("meta", function()
		return {
			effects = GlobalEffects.describe(),
			crates = Meta.describe(),
			telemetry = Telemetry.describe(),
			liveOps = LiveOps.describe and LiveOps.describe() or nil,
		}
	end)

	Debug.info("meta ready (events, crates, codes, telemetry)")
end

function Meta.describe(): { [string]: any }
	return {
		crates = (function()
			local ids = {}
			for id in Content.crates do
				table.insert(ids, id)
			end
			table.sort(ids)
			return ids
		end)(),
		effects = GlobalEffects.list(),
	}
end

return Meta
