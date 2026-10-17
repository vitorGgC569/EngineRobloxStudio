--!strict
--[[
	Saltmere — the tide, played against Sim.

	No player and no plot. Every scenario starts from Sim.newProfile and only
	moves that table through Sim, so a pass is the rule and not a copy of a
	tunable.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Sim = require(Shared:WaitForChild("Sim"))

-- A pure loop. Generous because a stingy yield still has to reach the lighthouse.
local TIDES = 1000

local function starterId(): string
	return Config.pans[1].id
end

local function upgradeLevel(profile: any, id: string): number
	local value = profile.upgrades[id]
	return if type(value) == "number" then value else 0
end

local function hasRole(profile: any, role: string): boolean
	for _, member in profile.crew do
		if type(member) == "table" and member.role == role then
			return true
		end
	end
	return false
end

local function floodFill(profile: any): any
	local filled, result = Sim.integrate(profile, 100000, "flood")
	if result.ok then
		return filled
	end
	return profile
end

local function markHarvest(profile: any): any
	local opened, result = Sim.onPhase(profile, "harvest")
	if result.ok then
		return opened
	end
	return profile
end

local function collectReady(profile: any): any
	for _, pan in Config.pans do
		local state = profile.pans[pan.id]
		if type(state) == "table" and state.owned == true and state.ready == true then
			local after, result = Sim.collect(profile, pan.id, "harvest")
			if result.ok then
				profile = after
			end
		end
	end
	return profile
end

local function harvestOnce(profile: any): any
	return collectReady(markHarvest(floodFill(profile)))
end

local function sellCoarse(profile: any): any
	local held = profile.salt.coarse
	if type(held) ~= "number" or held < 1 then
		return profile
	end
	local amount = math.min(math.floor(held), 10000)
	local after, result = Sim.sell(profile, "coarse", amount)
	if result.ok then
		return after
	end
	return profile
end

-- Fill, rake, sell, then enter flood so the next quote is not still pressured.
local function workTide(profile: any): any
	local harvested = harvestOnce(profile)
	local sold = sellCoarse(harvested)
	local reset, result = Sim.onPhase(sold, "flood")
	if result.ok then
		return reset
	end
	return sold
end

local function earn(profile: any): any
	local paid = workTide(profile)
	if type(paid.cash) == "number" and paid.cash > profile.cash then
		return paid
	end
	return profile
end

local function buy(profile: any, upgradeId: string): any
	for _ = 1, TIDES do
		local after, result = Sim.buyUpgrade(profile, upgradeId)
		if result.ok or result.reason ~= "not_enough_cash" then
			return if result.ok then after else profile
		end
		local paid = earn(profile)
		if type(paid.cash) ~= "number" or paid.cash <= profile.cash then
			return profile
		end
		profile = paid
	end
	return profile
end

local function claimWhenPaid(profile: any, panId: string): (any, any, number)
	for _ = 1, TIDES do
		local cash = profile.cash
		local after, result = Sim.claim(profile, panId)
		if result.ok or result.reason ~= "not_enough_cash" then
			return after, result, cash
		end
		local paid = earn(profile)
		if type(paid.cash) ~= "number" or paid.cash <= cash then
			return after, result, cash
		end
		profile = paid
	end
	local cash = profile.cash
	local after, result = Sim.claim(profile, panId)
	return after, result, cash
end

local function raisePan(profile: any, panId: string): any
	for _ = 1, TIDES do
		local after, result = Sim.upgradePan(profile, panId)
		if result.ok then
			return after
		end
		if result.reason ~= "not_enough_cash" then
			return profile
		end
		local paid = earn(profile)
		if type(paid.cash) ~= "number" or paid.cash <= profile.cash then
			return profile
		end
		profile = paid
	end
	return profile
end

local function stockCoarse(profile: any, minimum: number): any
	for _ = 1, TIDES do
		local held = profile.salt.coarse
		if type(held) == "number" and held >= minimum then
			return profile
		end
		local before = if type(held) == "number" then held else 0
		profile = harvestOnce(profile)
		local after = profile.salt.coarse
		if type(after) ~= "number" or after <= before then
			return profile
		end
	end
	return profile
end

local function prestigeProbe(profile: any): any
	local _, result = Sim.prestige(Sim.clone(profile))
	return result
end

-- Collect until the lifetime gate is no longer the refusal. Cash is not touched.
local function rakeUntilPrestige(profile: any): any
	for _ = 1, TIDES do
		local result = prestigeProbe(profile)
		if result.reason ~= "need_lifetime" then
			return profile
		end
		local before = profile.lifetime
		profile = harvestOnce(profile)
		if type(profile.lifetime) ~= "number" or profile.lifetime <= before then
			return profile
		end
	end
	return profile
end

return function(Testing)
	Testing.scenario("a new profile owns only the first pan and has the starting cash", function(t)
		local profile = Sim.newProfile()
		local starter = starterId()
		local owned = 0
		for _, pan in Config.pans do
			local state = profile.pans[pan.id]
			t:expect(type(state) == "table", "profile is missing " .. pan.id)
			if type(state) == "table" and state.owned == true then
				owned += 1
				t:expect(pan.id == starter, "a new profile owns " .. pan.id)
			elseif pan.id == starter then
				t:expect(false, "the first pan is not owned")
			end
		end
		t:expect(owned == 1, "a new profile should own exactly one pan")
		t:expect(profile.cash == Config.startCash, "starting cash does not follow config")
	end)

	Testing.scenario("claiming a pan you cannot afford does not own it and does not spend", function(t)
		local profile = Sim.newProfile()
		local target = nil
		for _, pan in Config.pans do
			local state = profile.pans[pan.id]
			if type(state) == "table" and state.owned ~= true and pan.claimCost > profile.cash then
				if target == nil or pan.claimCost < target.claimCost then
					target = pan
				end
			end
		end
		t:expect(target ~= nil, "starting cash affords every unowned pan")
		if target == nil then
			return
		end

		local cash = profile.cash
		local after, result = Sim.claim(profile, target.id)
		t:expect(result.ok ~= true, "a claim the wallet cannot cover was accepted")
		t:expect(result.reason == "not_enough_cash",
			"refusal reason was " .. tostring(result.reason))
		t:expect(after == profile, "a failed claim replaced the profile")
		t:expect(after.cash == cash, "a refused claim spent cash")
		t:expect(after.pans[target.id].owned ~= true, "a refused claim granted the pan")
	end)

	Testing.scenario("claiming an affordable pan spends cash and owns it", function(t)
		local profile = Sim.newProfile()
		local panId = nil
		local claimCost = math.huge
		for _, pan in Config.pans do
			local state = profile.pans[pan.id]
			if type(state) == "table"
				and state.owned ~= true
				and type(pan.claimCost) == "number"
				and pan.claimCost > 0
				and pan.claimCost < claimCost
			then
				panId = pan.id
				claimCost = pan.claimCost
			end
		end
		t:expect(panId ~= nil, "there is no priced pan left to claim")
		if panId == nil then
			return
		end

		local after, result, cash = claimWhenPaid(profile, panId)
		t:expect(result.ok == true, "an affordable claim was refused: " .. tostring(result.reason))
		t:expect(after.pans[panId].owned == true, "the claim did not grant the pan")
		t:expect(after.cash < cash, "the claim did not spend cash")
		t:expect(after.cash == cash - claimCost, "cash drop was not the pan's claim price")
	end)

	Testing.scenario("a ready pan can be raked outside harvest", function(t)
		local panId = starterId()
		for _, phase in { "flood", "settle", "spoil" } do
			local profile = markHarvest(floodFill(Sim.newProfile()))
			local state = profile.pans[panId]
			t:expect(state.ready == true, phase .. " fixture was not ready")
			local salt = profile.salt.coarse
			local after, result = Sim.collect(profile, panId, phase)
			t:expect(result.ok == true, phase .. " collect was refused: " .. tostring(result.reason))
			t:expect(after.salt.coarse > salt, phase .. " collect granted no salt")
			t:expect(after.pans[panId].brine == 0, phase .. " brine stayed")
			t:expect(after.pans[panId].ready ~= true, phase .. " pan stayed ready")
		end
	end)

	Testing.scenario("a ready pan collected during harvest moves coarse salt and clears brine", function(t)
		local panId = starterId()
		local profile = markHarvest(floodFill(Sim.newProfile()))
		local state = profile.pans[panId]
		t:expect(state.ready == true, "the pan was not ready")
		t:expect(state.brine > 0, "the pan had no brine")
		local salt = profile.salt.coarse
		local after, result = Sim.collect(profile, panId, "harvest")
		t:expect(result.ok == true, "harvest collect was refused: " .. tostring(result.reason))
		t:expect(after.salt.coarse > salt, "coarse salt did not increase")
		t:expect(after.pans[panId].brine == 0, "brine was not cleared")
		t:expect(after.pans[panId].ready ~= true, "the pan stayed ready after collection")
	end)

	Testing.scenario(
		"collecting the same ready pan twice does not grant twice (second call not_ready or not_harvest after brine cleared — assert salt did not increase the second time)",
		function(t)
			local panId = starterId()
			local profile = markHarvest(floodFill(Sim.newProfile()))
			local first, firstResult = Sim.collect(profile, panId, "harvest")
			t:expect(firstResult.ok == true, "the first collect was refused: " .. tostring(firstResult.reason))
			local salt = first.salt.coarse
			local again, second = Sim.collect(first, panId, "harvest")
			t:expect(second.ok ~= true, "the second collect was accepted")
			t:expect(second.reason == "not_ready" or second.reason == "not_harvest",
				"second collect failed as " .. tostring(second.reason))
			t:expect(again.salt.coarse == salt, "the second collect granted salt again")
		end
	)

	Testing.scenario("refining fine without the grader bench and without a grader fails and keeps the coarse", function(t)
		local minimum = math.max(1, Config.refine.coarsePerFine)
		local profile = stockCoarse(Sim.newProfile(), minimum)
		t:expect(upgradeLevel(profile, "grader_bench") < 1, "the fixture already owns the bench")
		t:expect(hasRole(profile, "grader") ~= true, "the fixture already has a grader")
		t:expect(profile.salt.coarse >= minimum, "there was no coarse to keep")
		local coarse = profile.salt.coarse
		local fine = profile.salt.fine
		local after, result = Sim.refine(profile, "fine", 1)
		t:expect(result.ok ~= true, "refine succeeded with no bench and no grader")
		t:expect(result.reason == "missing_upgrade",
			"refusal reason was " .. tostring(result.reason))
		t:expect(after == profile, "a failed refine replaced the profile")
		t:expect(after.salt.coarse == coarse, "coarse was not kept")
		t:expect(after.salt.fine == fine, "fine was created without a bench")
	end)

	Testing.scenario("refining fine with the bench consumes coarse and creates fine", function(t)
		local profile = buy(Sim.newProfile(), "grader_bench")
		t:expect(upgradeLevel(profile, "grader_bench") >= 1, "the grader bench was not bought")
		t:expect(hasRole(profile, "grader") ~= true, "a grader was hired beside the bench")
		local minimum = math.max(1, Config.refine.coarsePerFine)
		profile = stockCoarse(profile, minimum)
		t:expect(profile.salt.coarse >= minimum, "not enough coarse to refine")
		local coarse = profile.salt.coarse
		local fine = profile.salt.fine
		local after, result = Sim.refine(profile, "fine", 1)
		t:expect(result.ok == true, "refine with the bench was refused: " .. tostring(result.reason))
		t:expect(after.salt.coarse < coarse, "coarse was not consumed")
		t:expect(after.salt.fine > fine, "fine was not created")
	end)

	Testing.scenario("selling coarse debits salt and credits cash using Sim.price", function(t)
		local profile = stockCoarse(Sim.newProfile(), 1)
		local held = profile.salt.coarse
		t:expect(type(held) == "number" and held >= 1, "no coarse salt to sell")
		if type(held) ~= "number" or held < 1 then
			return
		end
		local amount = math.min(math.floor(held), 5)
		-- Quote before the sale. The credit is that unit price times the amount,
		-- so a later Config price does not stale this check.
		local unit = Sim.price(profile, "coarse")
		t:expect(type(unit) == "number" and unit > 0, "Sim.price did not quote a unit price")
		if type(unit) ~= "number" then
			return
		end
		local cash = profile.cash
		local after, result = Sim.sell(profile, "coarse", amount)
		t:expect(result.ok == true, "the sale was refused: " .. tostring(result.reason))
		t:expect(after.salt.coarse == held - amount, "coarse was not debited by the amount sold")
		t:expect(after.cash - cash == unit * amount, "cash credit was not price times amount")
	end)

	Testing.scenario("selling more than you hold fails and leaves cash unchanged", function(t)
		local profile = stockCoarse(Sim.newProfile(), 1)
		local held = profile.salt.coarse
		local cash = profile.cash
		t:expect(type(held) == "number" and held >= 1, "no coarse salt on hand")
		if type(held) ~= "number" then
			return
		end
		local ask = math.floor(held) + 1
		t:expect(ask <= 10000, "held salt is already at the amount cap")
		if ask > 10000 then
			return
		end
		local after, result = Sim.sell(profile, "coarse", ask)
		t:expect(result.ok ~= true, "selling more than held was accepted")
		t:expect(after == profile, "a failed sale replaced the profile")
		t:expect(after.cash == cash, "cash changed on a failed sale")
		t:expect(after.salt.coarse == held, "salt changed on a failed sale")
	end)

	Testing.scenario("prestige without a lighthouse fails and leaves the profile cash unchanged", function(t)
		local profile = Sim.newProfile()
		local starting = profile.cash
		profile = sellCoarse(harvestOnce(profile))
		t:expect(profile.cash > starting, "the fixture could not move cash, so a reset would be invisible")
		t:expect(upgradeLevel(profile, "lighthouse") < 1, "the fixture already has a lighthouse")
		local cash = profile.cash
		local rank = profile.prestige
		profile = rakeUntilPrestige(profile)
		t:expect(profile.cash == cash, "raking to the lifetime gate changed cash")
		local after, result = Sim.prestige(profile)
		t:expect(result.ok ~= true, "prestige succeeded without a lighthouse")
		t:expect(result.reason == "need_lighthouse",
			"refusal reason was " .. tostring(result.reason))
		t:expect(after == profile, "a failed prestige replaced the profile")
		t:expect(after.cash == cash, "prestige without a lighthouse changed cash")
		t:expect(after.prestige == rank, "prestige rank changed")
	end)

	Testing.scenario(
		"prestige with a lighthouse and enough lifetime resets pans except pan_1, keeps the lighthouse, and increments prestige",
		function(t)
			local starter = starterId()
			local extra = Config.pans[2]
			t:expect(extra ~= nil, "config has no second pan to unclaim")
			if extra == nil then
				return
			end

			local profile = Sim.newProfile()
			profile = buy(profile, "rake")
			t:expect(upgradeLevel(profile, "rake") >= 1, "the rake was not bought")
			profile = buy(profile, "lighthouse")
			local light = upgradeLevel(profile, "lighthouse")
			t:expect(light >= 1, "the lighthouse was not bought")

			local claimed, claimResult = claimWhenPaid(profile, extra.id)
			t:expect(claimResult.ok == true, "the extra pan was not claimed: " .. tostring(claimResult.reason))
			profile = claimed
			t:expect(profile.pans[extra.id].owned == true, "the extra pan is not owned before prestige")

			local levelBefore = profile.pans[starter].level
			profile = raisePan(profile, starter)
			t:expect(profile.pans[starter].level > levelBefore, "the starter pan level did not rise")

			profile = rakeUntilPrestige(profile)
			local probe = prestigeProbe(profile)
			t:expect(probe.ok == true, "prestige was not reachable: " .. tostring(probe.reason))
			if probe.ok ~= true then
				return
			end

			local rank = profile.prestige
			local after, result = Sim.prestige(profile)
			t:expect(result.ok == true, "prestige was refused: " .. tostring(result.reason))
			t:expect(after.prestige == rank + 1, "prestige did not increment")
			t:expect(after.pans[starter].owned == true, "pan_1 was unclaimed")
			t:expect(upgradeLevel(after, "lighthouse") == light, "the lighthouse was not kept")
			t:expect(upgradeLevel(after, "rake") == 0, "an upgrade other than the lighthouse survived")
			for _, pan in Config.pans do
				local state = after.pans[pan.id]
				t:expect(type(state) == "table", "prestige dropped " .. pan.id)
				if type(state) == "table" then
					if pan.id == starter then
						t:expect(state.owned == true, pan.id .. " did not stay claimed")
					else
						t:expect(state.owned ~= true, pan.id .. " stayed claimed")
					end
					t:expect(state.level == 1, pan.id .. " level was not reset")
					t:expect(state.brine == 0, pan.id .. " brine was not reset")
					t:expect(state.ready ~= true, pan.id .. " stayed ready")
				end
			end
		end
	)

	Testing.scenario("integrate during flood increases brine and integrate during harvest does not", function(t)
		local panId = starterId()
		-- Two fresh profiles. A flood that fills to the cap must not be the pan
		-- we then integrate in harvest, or a missing phase check still looks idle.
		local floodStart = Sim.newProfile()
		local harvestStart = Sim.newProfile()
		local floodBefore = floodStart.pans[panId].brine
		local harvestBefore = harvestStart.pans[panId].brine
		local flooded, floodResult = Sim.integrate(floodStart, 100000, "flood")
		t:expect(floodResult.ok == true, "flood integrate was refused")
		t:expect(flooded.pans[panId].brine > floodBefore, "flood did not add brine")

		local harvested, harvestResult = Sim.integrate(harvestStart, 100000, "harvest")
		t:expect(harvestResult.ok == true, "harvest integrate was refused")
		t:expect(harvested.pans[panId].brine == harvestBefore, "harvest integrate added brine")
	end)

	Testing.scenario(
		"onPhase harvest marks a full-enough pan ready and onPhase spoil reduces brine of an uncollected ready pan",
		function(t)
			local panId = starterId()
			local profile = floodFill(Sim.newProfile())
			local filled = profile.pans[panId]
			t:expect(filled.brine > 0, "the pan did not fill")
			t:expect(filled.ready ~= true, "the pan was ready before harvest")
			t:expect(#profile.crew == 0, "a crew member would rake this pan on spoil")

			local opened, openResult = Sim.onPhase(profile, "harvest")
			t:expect(openResult.ok == true, "harvest boundary was refused")
			t:expect(opened.pans[panId].ready == true, "a full pan was not marked ready")
			local brine = opened.pans[panId].brine
			local salt = opened.salt.coarse

			local spoiled, spoilResult = Sim.onPhase(opened, "spoil")
			t:expect(spoilResult.ok == true, "spoil boundary was refused")
			t:expect(spoiled.pans[panId].ready ~= true, "the pan stayed ready after spoil")
			t:expect(spoiled.pans[panId].brine < brine, "spoil did not reduce brine")
			t:expect(spoiled.salt.coarse == salt, "an uncollected pan paid salt on spoil")
		end
	)
end
