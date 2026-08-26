--!strict
--[[
	Line — what a plot produces, and what stops it producing more.

	The idea the whole game turns on
	--------------------------------

	A plot is a chain: drills make ore, belts carry it, smelters refine it,
	depots sell it. The chain runs at the rate of its **narrowest link**, and
	that single rule is the entire design. Six drills and one belt is six
	drills' worth of noise and one belt's worth of income, and the player can
	see which one is the problem by looking at the plot.

	No system needs to teach that. It falls out of taking the minimum.

	Where each number comes from
	----------------------------

	  `Content`                 what a machine produces at level one
	  `UpgradeTree`             how many levels the player has bought
	  `ModifierPipeline`        the fold, in order, with an audit trail
	  `GlobalEffects`           whatever is true for the whole server today
	  `IncomeEngine`            the contributors, so a HUD can show the parts
	  `BigNumber`               the balance, once it stops fitting in a double

	The pipeline is the interesting one. A payout that is "base times upgrades
	times event times gamepass, capped" is four multiplications somebody wrote
	in an order, and the order changes the answer. Declaring the stages means
	the order is a decision rather than an accident, and the audit trail means
	a player asking "why did I get 340" can be answered.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local Clock = Forge.Core.Clock
local Boot = Forge.Core.Boot
local GlobalEffects = Forge.LiveOps.GlobalEffects

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Content = require(Shared:WaitForChild("Content"))

local Pipeline = require(ReplicatedStorage.Forge.Progression.ModifierPipeline)
local UpgradeTree = require(ReplicatedStorage.Forge.Progression.UpgradeTree)
local ThroughputLedger = require(ReplicatedStorage.Forge.Tycoon.ThroughputLedger)
local DropperChain = require(ReplicatedStorage.Forge.Tycoon.DropperChain)
local IncomeEngine = require(ReplicatedStorage.Forge.Economy.IncomeEngine)

local Plots = require(script.Parent.Plots)

local Line = {}

Line.tree = nil :: any
Line.chain = nil :: any
--: Per plot: the ledger of what is standing there, and the income model.
Line.ledgers = {} :: { [string]: any }
Line.engines = {} :: { [string]: any }
--: The last full payout per plot, kept so a HUD can render the breakdown
--: without recomputing it and getting a different answer.
Line.lastPayout = {} :: { [string]: any }

-- ================================== stages ==================================
--[[
	The order a payout is folded in.

	Read it top to bottom and it is the sentence the game means: what the
	machines make, multiplied by what the player bought, multiplied by what is
	true for everybody today, multiplied by what they paid for, and then
	limited so a stack of events cannot break the economy.

	The cap is last on purpose. A cap applied before a multiplier is not a cap.
]]
local STAGES = {
	{ "upgrades", "multiply" },
	{ "event", "multiply" },
	{ "premium", "multiply" },
	{ "ceiling", "cap" },
}

function Line.start()
	Line.tree = UpgradeTree.new({ nodes = Content.upgradeNodes() })

	--[[
		How many machines a plot may hold.

		`DropperChain` exists for exactly this: a limit that grows with the
		player's level and with whatever they have bought. Without a limit a
		plot fills with drills until the server is the bottleneck, which is a
		performance problem wearing a gameplay costume.
	]]
	Line.chain = DropperChain.new({
		baseLimit = 8,
		perLevelBonus = 2,
		premiumBonus = 6,
	})

	Pipeline.define("payout", STAGES)

	Pipeline.provide("payout", "upgrades", function(context)
		--[[
			Every upgrade that touches price, as one multiplier.

			Read from the tree rather than stored on the profile, because a
			stored multiplier is a number that drifts from the levels that
			produced it the first time anything grants a level directly.
		]]
		local levels = context.levels or {}
		local total = 1
		for id, effect in Content.upgradeEffects do
			if effect.stat == "priceMultiplier" then
				total *= 1 + (levels[id] or 0) * effect.perLevel
			end
		end
		return { amount = total, label = "contracts" }
	end)

	Pipeline.provide("payout", "event", function()
		return { amount = GlobalEffects.aggregate("coin"), label = "server event" }
	end)

	Pipeline.provide("payout", "premium", function(context)
		return { amount = context.premium and 2 or 1, label = "supporter" }
	end)

	Pipeline.provide("payout", "ceiling", function()
		--[[
			The most a single tick may pay.

			Not a balance lever — a blast radius. It is here so that a bug in
			any provider above costs one tick rather than the economy, and it
			is set far above anything reachable so it never fires in play.
		]]
		return { amount = 5e7, label = "tick ceiling" }
	end)

	Debug.info("production stages defined")
	Boot.signal("line_ready")
end

-- ================================== plots ===================================
function Line.attach(plotId: string)
	Line.ledgers[plotId] = ThroughputLedger.new()
	--[[
		`IncomeEngine` holds the contributors so a HUD can show *which* part of
		the plot earns what. The pipeline computes the number; the engine
		remembers the shape of it.
	]]
	Line.engines[plotId] = IncomeEngine.new({ base = 0 })
end

function Line.detach(plotId: string)
	Line.ledgers[plotId] = nil
	Line.engines[plotId] = nil
	Line.lastPayout[plotId] = nil
end

--[[
	May this plot hold another machine?

	Asked before anything is built, and answered from the chain rather than
	from a constant, so a player who has invested in capacity sees the reward
	for it immediately.
]]
function Line.mayBuild(plotId: string, level: number, premium: boolean?): (boolean, string?)
	local ledger = Line.ledgers[plotId]
	if not ledger then
		return false, "that plot is not running"
	end
	local live = ledger:count()

	--[[
		`life` counts rebirths from zero; `DropperChain` counts tiers from one.

		Passing the profile's `life` straight through meant every player who had
		never rebirthed -- which is every new player -- hit
		`assert(level >= 1, "level starts at 1")` inside the engine. The Build
		handler threw on its capacity check, every single time, for everyone.

		It stayed hidden because `Net.on` catches a handler error and reports it
		with `warn`, so it never appeared in the error stream anyone was
		watching, and the player saw a button that did nothing at all.

		The conversion belongs here: this game decides what a life is, the
		engine decides what a tier is, and the boundary is the only place that
		knows both.
	]]
	if not Line.chain:canProduce(live, level + 1, premium) then
		return false, string.format(
			"this plot holds %d machines; upgrade capacity to fit more",
			Line.chain:limit(level + 1, premium))
	end
	return true
end

function Line.record(plotId: string, machineId: string)
	local ledger = Line.ledgers[plotId]
	if ledger then
		ledger:add(machineId)
	end
end

-- ================================ throughput ================================
--[[
	What this plot makes in one tick.

	The narrowest link, and nothing else. Each stage's capacity is its machine
	count times its per-machine rate times whatever upgrades apply to it, and
	the chain runs at the smallest of the four.

	Returned with the parts, because "you are making 40" is a number and "your
	belts are the bottleneck at 40 while your drills could do 90" is the game.
]]
function Line.throughput(plotId: string, levels: { [string]: number }): (number, { [string]: any })
	local counts = Plots.byRole(plotId)
	local machines = Content.machines

	local function rateFor(role: string, machineId: string, stat: string): number
		local effect = 1
		for id, spec in Content.upgradeEffects do
			if spec.stat == stat then
				effect += (levels[id] or 0) * spec.perLevel
			end
		end
		return counts[role] * machines[machineId].output * effect
	end

	local stages = {
		source = rateFor("source", "drill", "oreRate"),
		carry = rateFor("carry", "belt", "carryRate"),
		refine = rateFor("refine", "smelter", "refineRate"),
		sell = rateFor("sell", "depot", "sellRate"),
	}

	--[[
		A missing link stops the chain, rather than being skipped.

		A plot with drills and no depot earns nothing, which is correct and is
		the thing that teaches a new player what a depot is for. Treating a
		zero as "no limit" would silently pay them anyway.
	]]
	local narrowest = math.huge
	local bottleneck = "source"
	for role, rate in stages do
		if rate < narrowest then
			narrowest = rate
			bottleneck = role
		end
	end
	if narrowest == math.huge then
		narrowest = 0
	end

	return narrowest, { stages = stages, bottleneck = bottleneck, counts = counts }
end

--[[
	Pay a plot for one tick.

	The whole fold in one place: throughput through the pipeline, the result
	and its audit trail kept for the HUD. Returns the coins so the caller can
	credit whatever holds the balance.
]]
function Line.tick(plotId: string, profile: any): number
	local levels = profile.upgrades or {}
	local produced, detail = Line.throughput(plotId, levels)
	if produced <= 0 then
		Line.lastPayout[plotId] = { coins = 0, detail = detail, steps = {} }
		Plots.setActive(plotId, false)
		return 0
	end

	local coins, steps = Pipeline.resolve("payout", produced, {
		levels = levels,
		premium = profile.premium == true,
	})

	local engine = Line.engines[plotId]
	if engine then
		engine:addContributor("line", { kind = "add", value = coins })
	end

	Line.lastPayout[plotId] = {
		coins = coins,
		detail = detail,
		steps = steps,
		at = Clock.now(),
	}
	Plots.setActive(plotId, true)
	return coins
end

--: The last payout, in sentences. For a HUD tooltip and for a support ticket.
function Line.explain(plotId: string): { string }
	local last = Line.lastPayout[plotId]
	if not last then
		return { "this plot has not produced yet" }
	end

	local lines = {
		string.format("%s is the bottleneck at %.0f a tick",
			last.detail.bottleneck, last.detail.stages[last.detail.bottleneck] or 0),
	}
	for _, step in last.steps do
		if step.mode == "multiply" and step.amount ~= 1 then
			lines[#lines + 1] = string.format("  x%.2f from %s", step.amount, step.label)
		elseif step.mode == "cap" and step.after < step.before then
			lines[#lines + 1] = string.format("  capped at %.0f", step.amount)
		end
	end
	lines[#lines + 1] = string.format("  = %.0f coins", last.coins)
	return lines
end

function Line.describe(): { [string]: any }
	local running = 0
	local earning = 0
	for plotId in Line.ledgers do
		running += 1
		local last = Line.lastPayout[plotId]
		if last and last.coins > 0 then
			earning += 1
		end
	end
	return {
		plotsRunning = running,
		plotsEarning = earning,
		tickSeconds = Config.tickSeconds,
		stages = STAGES,
		pipeline = Pipeline.describe(),
	}
end

return Line
