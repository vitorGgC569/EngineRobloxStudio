--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Shared.Config)
local Content = require(ReplicatedStorage.Shared.Content)
local Rules = require(ServerScriptService.Server.Rules)

return function(Testing)
	Testing.scenario("offline earnings are bounded and never negative", function(t)
		local amount, seconds = Rules.offlinePayout(10, Config.offlineCapSeconds * 3)
		t:expect(seconds == Config.offlineCapSeconds, "offline time exceeded its configured ceiling")
		t:expect(amount == math.floor(10 * Config.offlineCapSeconds * Config.offlineEfficiency),
			"offline payout did not use the bounded interval")
		local negative = Rules.offlinePayout(-100, -500)
		t:expect(negative == 0, "negative rate/time created currency")
	end)

	Testing.scenario("vault upgrades increase capacity one slot at a time", function(t)
		t:expect(Rules.capacity(0, false) == 4, "new players do not start with four slots")
		t:expect(Rules.capacity(3, false) == 7, "vault levels do not map one-to-one to slots")
		t:expect(Rules.capacity(3, true) == 11, "extra-vault pass does not add exactly four slots")
	end)

	Testing.scenario("reactor is monotonic and speed cannot reduce movement", function(t)
		local previous = 0
		for level = 0, Content.upgrades.reactor.max do
			local multiplier = Rules.reactorMultiplier(level)
			t:expect(multiplier >= previous, "reactor upgrade reduced production")
			previous = multiplier
		end
		t:expect(Rules.walkSpeed(0) == Config.baseWalkSpeed, "level zero changes base walk speed")
		t:expect(Rules.walkSpeed(5) > Rules.walkSpeed(1), "speed upgrades are not monotonic")
	end)

	Testing.scenario("rarity ladder pays more and every specimen has a valid drop weight", function(t)
		local previousIncome = 0
		for _, specimen in Content.specimens do
			t:expect(specimen.weight > 0, specimen.id .. " cannot ever drop")
			t:expect(specimen.income >= previousIncome,
				specimen.id .. " pays less than an earlier rarity rung")
			t:expect(Content.rarities[specimen.rarity] ~= nil,
				specimen.id .. " references a missing rarity")
			previousIncome = specimen.income
		end
	end)

	Testing.scenario("meteor rarity is visible, unique and increasingly valuable", function(t)
		local seen = {}
		local previousScale = 0
		local previousBonus = 0
		local previousRarity = 0
		for _, meteor in Content.meteors do
			t:expect(not seen[meteor.id], meteor.id .. " is duplicated")
			seen[meteor.id] = true
			t:expect(meteor.weight > 0, meteor.id .. " has no spawn chance")
			t:expect(meteor.rarity > previousRarity, meteor.id .. " is out of rarity order")
			t:expect(meteor.scale > previousScale, meteor.id .. " is not visually larger than the previous tier")
			t:expect(meteor.burstMultiplier > previousBonus, meteor.id .. " does not improve decode value")
			t:expect(Content.rarities[meteor.rarity] ~= nil, meteor.id .. " references a missing rarity")
			t:expect(Content.meteor(meteor.id) == meteor, meteor.id .. " cannot be looked up by id")
			previousRarity = meteor.rarity
			previousScale = meteor.scale
			previousBonus = meteor.burstMultiplier
		end
		t:expect(#Content.meteors == 6, "the shipped world must expose six visually distinct meteor tiers")
	end)

	Testing.scenario("meteor weighted roll always returns a declared tier", function(t)
		local random = Random.new(77421)
		for _ = 1, 250 do
			local normal = Content.rollMeteor(random, 0)
			local shower = Content.rollMeteor(random, 1.4)
			t:expect(Content.meteor(normal.id) ~= nil, "normal roll returned an undeclared meteor")
			t:expect(Content.meteor(shower.id) ~= nil, "shower roll returned an undeclared meteor")
		end
	end)

	Testing.scenario("mutations are meaningful without changing the base table", function(t)
		for _, specimen in Content.specimens do
			local normal = Content.income(specimen.id, "")
			t:expect(Content.income(specimen.id, "radiant") == normal * 2,
				"radiant multiplier drifted")
			t:expect(Content.income(specimen.id, "void") == normal * 5,
				"void multiplier drifted")
		end
	end)

	Testing.scenario("upgrade prices rise and remain finite through max level", function(t)
		for id, spec in Content.upgrades do
			local previous = 0
			for level = 0, spec.max - 1 do
				local cost = Content.upgradeCost(id, level)
				t:expect(cost > previous, id .. " price did not increase")
				t:expect(cost < math.huge, id .. " price became non-finite")
				previous = cost
			end
		end
	end)
end
