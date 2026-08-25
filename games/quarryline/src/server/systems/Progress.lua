--!strict
--[[
	Progress — what a player keeps, and what it buys.

	A tycoon is four loops running at different speeds, and this owns all four:

	  seconds   the line pays, the balance rises
	  minutes   an upgrade is affordable, a decision gets made
	  sessions  a daily reward, a quest, a rebirth
	  weeks     achievements, and the reason to come back to a game you have
	            already finished

	The one that is always got wrong is the third. A player who leaves for a
	day must come back to something — but not to so much that leaving is the
	optimal play. `OfflineEarnings` caps it both ways: absolutely, so a week
	away does not buy the endgame, and relatively against the balance they
	already have, so it stays a welcome-back rather than a windfall.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local Save = Forge.Save
local Net = Forge.Net
local Clock = Forge.Core.Clock
local Boot = Forge.Core.Boot
local Telemetry = Forge.Telemetry

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Content = require(Shared:WaitForChild("Content"))
local Config = require(Shared:WaitForChild("Config"))

local UpgradeTree = require(ReplicatedStorage.Forge.Progression.UpgradeTree)
local OfflineEarnings = require(ReplicatedStorage.Forge.Progression.OfflineEarnings)
local RebirthLoop = require(ReplicatedStorage.Forge.Progression.RebirthLoop)
local DailyRewardCalendar = require(ReplicatedStorage.Forge.Progression.DailyRewardCalendar)
local TutorialFlow = require(ReplicatedStorage.Forge.Progression.TutorialFlow)
local Achievements = require(ReplicatedStorage.Forge.Progression.Achievements)

local Line = require(script.Parent.Line)

local Progress = {}

Progress.rebirth = nil :: any
Progress.calendar = nil :: any
Progress.tutorial = nil :: any

-- ================================== setup ===================================
function Progress.start()
	--[[
		Rebirth price, as a curve rather than a table.

		`life` is how many times they have done it. Geometric at 2.2 means the
		second rebirth costs a little over twice the first — steep enough that
		it is a decision, shallow enough that a player who liked the first one
		can see the second.
	]]
	Progress.rebirth = RebirthLoop.new({
		price = function(life: number): number
			return Content.rebirth.baseCost * (Content.rebirth.costGrowth ^ life)
		end,
	})

	--[[
		Seven days, rewarding the streak rather than the visit.

		The milestone on day seven is the whole mechanic: six small rewards are
		a habit, and the seventh is the reason the habit was worth forming.
	]]
	Progress.calendar = DailyRewardCalendar.new({
		cycleLength = 7,
		milestones = {
			[1] = { coins = 500 },
			[3] = { coins = 2500 },
			[5] = { coins = 8000 },
			[7] = { coins = 30000, crate = "gem" },
		},
		now = function()
			return Clock.now()
		end,
	})

	--[[
		The first four minutes.

		Each step is a thing to do, not a thing to read. A tutorial that says
		"welcome to the quarry" teaches nothing; one that will not advance
		until a drill exists teaches what a drill is.
	]]
	Progress.tutorial = TutorialFlow.new({
		{ id = "claim", label = "Step onto a plot to claim it" },
		{ id = "drill", label = "Buy a Drill" },
		{ id = "belt", label = "Buy a Conveyor so the ore can move" },
		{ id = "depot", label = "Buy a Depot to sell it" },
		{ id = "upgrade", label = "Spend your first coins on an upgrade" },
	}, function()
		return Clock.now()
	end)

	--[[
		Achievements over counters the game already keeps.

		Tiered, so one definition covers the whole ladder, and evaluated on
		login as well as on change — which is what makes an achievement added
		next month fire for the players who already earned it.
	]]
	Achievements.defineMany({
		hauler = { stat = "lifetimeCoins", label = "Hauler",
			tiers = { 10000, 250000, 5000000 } },
		builder = { stat = "machinesBuilt", label = "Builder",
			tiers = { 5, 25, 100 } },
		reborn = { stat = "life", label = "Reborn", tiers = { 1, 5, 10 } },
		devoted = { stat = "daysClaimed", label = "Devoted", tiers = { 3, 7, 30 } },
	})

	Debug.info("progression ready")
	Boot.signal("progress_ready")
end

-- ================================= the profile ==============================
--: What a new player starts with. Every field here is one the save schema
--: knows about, and nothing reads a field that is not in this table.
function Progress.template(): { [string]: any }
	return {
		coins = 0,
		lifetimeCoins = 0,
		machinesBuilt = 0,
		upgrades = {},
		life = 0,
		daysClaimed = 0,
		streak = 0,
		lastClaimDay = nil,
		lastSeen = 0,
		tutorialDone = false,
		achievements = {},
		premium = false,
	}
end

-- ================================== offline =================================
--[[
	Pay for the time they were away.

	Called once, on load, before anything else touches the balance — because
	the relative cap is measured against what they had when they left, and
	crediting anything first makes the cap larger than it should be.
]]
function Progress.payOffline(player: Player, profile: any): number
	if (profile.lastSeen or 0) <= 0 then
		profile.lastSeen = Clock.now()
		return 0
	end

	local away = Clock.now() - profile.lastSeen
	local plotId = nil
	local perSecond = 0
	--[[
		Their rate when they left, not now.

		The plot is empty at this instant — nothing has been rebuilt yet — so
		the rate has to come from the stored one. A game that computed it from
		the live plot would pay every returning player zero, which is the bug
		that looks like the feature working.
	]]
	perSecond = (profile.incomePerSecond or 0)

	local result = OfflineEarnings.compute(perSecond, away, {
		minSeconds = 60,
		temporalCap = Config.offlineCapHours * 3600,
		relativeCapMultiple = 3,
		currentBalance = profile.coins,
	})

	profile.lastSeen = Clock.now()
	if result.amount > 0 then
		Progress.credit(player, profile, result.amount, "offline")
		Telemetry.event("offline.paid", {
			seconds = result.secondsPaid,
			amount = result.amount,
		})
	end
	return result.amount
end

-- ================================== earning =================================
function Progress.credit(player: Player, profile: any, coins: number, reason: string)
	if coins <= 0 then
		return
	end
	profile.coins += coins
	profile.lifetimeCoins += coins

	local awarded = Achievements.evaluate(profile)
	for _, achievement in awarded do
		Net.fire(player, "Notify", {
			text = string.format("%s %d", achievement.label, achievement.tier),
		})
		Telemetry.event("achievement", { id = achievement.id, tier = achievement.tier })
	end

	if reason ~= "offline" then
		Telemetry.event("earn", { amount = coins, reason = reason })
	end
end

-- ================================= upgrading ================================
--[[
	Buy a level, if they can afford it and the tree allows it.

	Three answers, and each one is a different message: the node does not
	exist, its prerequisites are not met, or it costs more than they have.
	Collapsing them into "no" is how a player concludes the button is broken.
]]
function Progress.buyUpgrade(player: Player, profile: any, id: string): (boolean, string?)
	local state = profile.upgrades
	if not Content.upgrades[id] then
		return false, string.format("there is no upgrade called '%s'", id)
	end
	if not Line.tree:visible(state, id) then
		return false, "that needs an earlier upgrade first"
	end

	local cost = Line.tree:cost(state, id)
	if not Line.tree:canBuy(state, id, profile.coins) then
		if cost and profile.coins < cost then
			return false, string.format("that costs %d and you have %d", cost, profile.coins)
		end
		return false, "that is already at its maximum"
	end

	local delta = Line.tree:buy(state, id)
	UpgradeTree.apply(state, delta)
	profile.coins -= cost

	Telemetry.event("upgrade", { id = id, level = state[id], cost = cost })
	return true
end

-- ================================== rebirth =================================
--[[
	Trade everything for a permanent multiplier.

	The wipe is the point and it has to be complete: coins, upgrades, the plot.
	A rebirth that quietly keeps something is a rebirth whose price nobody can
	reason about, and the second one always feels wrong.
]]
function Progress.doRebirth(player: Player, profile: any): (boolean, string?)
	local state = { life = profile.life, balance = profile.coins }
	if not Progress.rebirth:canRebirth(state.balance, state.life) then
		local price = Progress.rebirth:quote(state.life)
		return false, string.format("rebirth costs %d and you have %d", price, profile.coins)
	end

	Progress.rebirth:execute(state)
	profile.life = state.life
	profile.coins = 0
	profile.upgrades = {}

	Achievements.evaluate(profile)
	Telemetry.event("rebirth", { life = profile.life })
	return true
end

--: The multiplier a player's lives are worth. Read by the payout pipeline.
function Progress.rebirthBonus(profile: any): number
	return 1 + (profile.life or 0) * Content.rebirth.bonusPerLife
end

-- =================================== daily ==================================
function Progress.claimDaily(player: Player, profile: any): (any?, string?)
	local state = { lastClaimDay = profile.lastClaimDay, streak = profile.streak or 0 }
	local result = Progress.calendar:claim(state)
	if not result or result.claimed == false then
		return nil, string.format("the next reward is in %s",
			Clock.format(Clock.untilNextDay()))
	end

	profile.lastClaimDay = state.lastClaimDay
	profile.streak = state.streak
	profile.daysClaimed = (profile.daysClaimed or 0) + 1

	local reward = result.reward or {}
	if reward.coins then
		Progress.credit(player, profile, reward.coins, "daily")
	end
	Telemetry.event("daily.claimed", { streak = profile.streak })
	return result
end

function Progress.describe(): { [string]: any }
	return {
		upgrades = (function()
			local ids = {}
			for id in Content.upgrades do
				table.insert(ids, id)
			end
			table.sort(ids)
			return ids
		end)(),
		achievements = Achievements.describe(),
		rebirthBase = Content.rebirth.baseCost,
		offlineCapHours = Config.offlineCapHours,
	}
end

return Progress
