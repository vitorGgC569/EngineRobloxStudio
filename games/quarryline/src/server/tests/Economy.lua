--!strict
--[[
	Live scenarios for quarryline's economy.

	These run inside the running game against the real plots, the real grid and
	the real payout pipeline. Nothing is stubbed: an assertion that a plot with
	no depot earns nothing is an assertion that `GridPlacement`, the role
	counting, the bottleneck rule and every stage of the pipeline still agree.

	What is worth asserting
	-----------------------

	Rules, not numbers. "The chain runs at its narrowest link" is a rule and
	will be true next month; "a drill and a belt make 34" is a balance value,
	and asserting it turns every tuning pass into a red build.

	The exception is where the number *is* the rule — a cap that does not cap,
	an offline payout past its ceiling, a code redeemed twice. Those are not
	balance, they are correctness wearing a number.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Clock = Forge.Core.Clock
local GlobalEffects = Forge.LiveOps.GlobalEffects

local Systems = script.Parent.Parent:WaitForChild("systems")
local Plots = require(Systems.Plots)
local Line = require(Systems.Line)
local Progress = require(Systems.Progress)

local OfflineEarnings = require(ReplicatedStorage.Forge.Progression.OfflineEarnings)

--[[
	A function, because that is what the runner calls.

	`Testing.runAndPublish(folder)` does `require(module)(Testing)` on every
	child, so a scenario file hands its cases to the surface it is given rather
	than reaching for a global one. Registering at module scope and returning
	`true` looks equivalent and is not: the runner then calls a boolean.
]]
return function(Testing)

--: A plot nobody owns, so a scenario can build on it without evicting a
--: player. Released again at the end of each case.
local function spareplot(): string?
	for id in Plots.models do
		if not Plots.allocator:ownerOf(id) then
			return id
		end
	end
	return nil
end

Testing.scenario("the chain runs at its narrowest link", function(t)
	local id = spareplot()
	t:expect(id ~= nil, "no free plot to test on")
	Line.attach(id)

	--[[
		Placed straight through `Plots.built` rather than through `place`,
		because `place` checks ownership and this plot deliberately has no
		owner. The thing under test is the throughput rule, not the permission.
	]]
	Plots.built[id] = {
		["drill:0:0"] = { machineId = "drill" },
		["drill:8:0"] = { machineId = "drill" },
		["belt:0:8"] = { machineId = "belt" },
	}

	local produced, detail = Line.throughput(id, {})
	t:expect(produced == 0, "a chain with no depot must produce nothing, got " .. produced)
	t:expect(detail.stages.sell == 0, "the sell stage is the empty one")

	--[[
		A depot alone does not complete anything.

		This asserted that it did, and failed -- correctly. The chain is
		source, carry, refine, sell, and the plot above has no smelter, so the
		refine stage is still zero and the narrowest link is still zero. That is
		the documented rule working, and the assertion was simply wrong about
		what the rule says.

		Stated properly it is a better test than the one it replaces, because it
		pins down *which* link is missing rather than just that some link is.
	]]
	Plots.built[id]["depot:0:16"] = { machineId = "depot" }
	local stillShort, shortDetail = Line.throughput(id, {})
	t:expect(stillShort == 0, "a chain with no smelter must still produce nothing")
	t:expect(shortDetail.bottleneck == "refine",
		"the missing smelter must be named as the bottleneck, got " .. shortDetail.bottleneck)

	Plots.built[id]["smelter:0:24"] = { machineId = "smelter" }
	local complete = Line.throughput(id, {})
	t:expect(complete > 0, "all four roles present must complete the chain")

	Plots.built[id] = {}
	Line.detach(id)
end)

Testing.scenario("the bottleneck is named, and it is the smallest stage", function(t)
	local id = spareplot()
	t:expect(id ~= nil, "no free plot")
	Line.attach(id)

	-- Six drills, one belt, one smelter, one depot: the belt is deliberately
	-- the narrow one, which is the shape a new player builds by accident.
	Plots.built[id] = {}
	for index = 1, 6 do
		Plots.built[id]["drill:" .. index] = { machineId = "drill" }
	end
	Plots.built[id]["belt:1"] = { machineId = "belt" }
	Plots.built[id]["smelter:1"] = { machineId = "smelter" }
	Plots.built[id]["depot:1"] = { machineId = "depot" }

	local produced, detail = Line.throughput(id, {})
	local smallest = math.huge
	for _, rate in detail.stages do
		smallest = math.min(smallest, rate)
	end
	t:expect(produced == smallest, "throughput must equal the smallest stage")
	t:expect(detail.stages[detail.bottleneck] == smallest,
		"the named bottleneck must be the smallest one")

	Plots.built[id] = {}
	Line.detach(id)
end)

Testing.scenario("a server event multiplies the payout and then stops", function(t)
	local id = spareplot()
	t:expect(id ~= nil, "no free plot")
	Line.attach(id)

	Plots.built[id] = {
		["drill:1"] = { machineId = "drill" },
		["belt:1"] = { machineId = "belt" },
		["smelter:1"] = { machineId = "smelter" },
		["depot:1"] = { machineId = "depot" },
	}

	local profile = { upgrades = {}, premium = false }
	local plain = Line.tick(id, profile)
	t:expect(plain > 0, "the plot must earn with a full chain")

	GlobalEffects.apply("double_coins", 30, "scenario")
	local doubled = Line.tick(id, profile)
	t:expect(doubled > plain, "an active event must raise the payout")

	GlobalEffects.remove("double_coins")
	local after = Line.tick(id, profile)
	t:expect(after == plain, "removing the event must return the payout exactly")

	Plots.built[id] = {}
	Line.detach(id)
end)

Testing.scenario("the payout explains itself", function(t)
	local id = spareplot()
	t:expect(id ~= nil, "no free plot")
	Line.attach(id)
	Plots.built[id] = {
		["drill:1"] = { machineId = "drill" },
		["belt:1"] = { machineId = "belt" },
		["smelter:1"] = { machineId = "smelter" },
		["depot:1"] = { machineId = "depot" },
	}

	Line.tick(id, { upgrades = {}, premium = false })
	local lines = Line.explain(id)
	t:expect(#lines >= 2, "an explanation must have a bottleneck and a total")
	t:expect(string.find(lines[1], "bottleneck") ~= nil,
		"the first line names the bottleneck: " .. lines[1])

	Plots.built[id] = {}
	Line.detach(id)
end)

Testing.scenario("offline pay is capped both ways", function(t)
	--[[
		The two caps do different jobs and both matter.

		The absolute one stops a week away from buying the endgame. The
		relative one stops a player with nothing from returning to a fortune,
		which is what makes leaving the optimal play.
	]]
	local week = 7 * 86400
	local result = OfflineEarnings.compute(100, week, {
		minSeconds = 60,
		temporalCap = 8 * 3600,
		relativeCapMultiple = 3,
		currentBalance = 1000,
	})

	t:expect(result.secondsPaid <= 8 * 3600,
		"a week away must be capped to the temporal ceiling")
	t:expect(result.amount <= 3000,
		"the payout must not exceed three times the balance, got " .. result.amount)

	local brief = OfflineEarnings.compute(100, 10, { minSeconds = 60 })
	t:expect(brief.amount == 0, "ten seconds away is not being away")
end)

Testing.scenario("a rebirth wipes everything it says it wipes", function(t)
	local profile = {
		coins = 10000000,
		lifetimeCoins = 10000000,
		life = 0,
		upgrades = { bore = 5, belts = 3 },
		achievements = {},
	}

	local before = Progress.rebirthBonus(profile)
	local ok = Progress.doRebirth(nil :: any, profile)
	t:expect(ok, "a player past the price must be able to rebirth")
	t:expect(profile.coins == 0, "coins must be wiped")
	t:expect(next(profile.upgrades) == nil, "upgrades must be wiped")
	t:expect(profile.life == 1, "the life must advance")
	t:expect(Progress.rebirthBonus(profile) > before,
		"the whole point is that the next run is faster")

	--[[
		Lifetime coins survive on purpose.

		It is the counter achievements are measured against, and a player who
		loses their lifetime total on rebirth loses every badge they earned —
		which is the opposite of what rebirth is supposed to feel like.
	]]
	t:expect(profile.lifetimeCoins == 10000000, "lifetime earnings are not wiped")
end)

Testing.scenario("the day rolls over in UTC, for everybody at once", function(t)
	local morning = Clock.dailySeed("shop", 86400 * 100 + 60)
	local evening = Clock.dailySeed("shop", 86400 * 100 + 80000)
	local tomorrow = Clock.dailySeed("shop", 86400 * 101 + 60)

	t:expect(morning == evening, "the seed must not change during a day")
	t:expect(morning ~= tomorrow, "it must change at the boundary")
	t:expect(Clock.untilNextDay() > 0, "there is always time until the next day")
end)

end
