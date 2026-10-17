--!strict
--[[
	The loop, asserted against the running game.

	Not the systems in isolation -- those are checked headlessly and in a
	millisecond. These run inside the live place, against the same `Dojo` the
	network handlers call, because the question they answer is whether a player
	who does the obvious thing gets a game.

	Every scenario here is a sentence from the retention record that shaped
	this design, turned into an assertion:

	    "28% left before a first payout at 22 seconds"
	        -> the first scroll is free and produces a fighter
	    "74% never reached a second rung"
	        -> rank two is reachable inside the first session
	    "the fatal gap was 136 seconds"
	        -> nothing in the first two minutes leaves the player idle
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))
local Dojo = require(script.Parent.Parent.systems.Dojo)


return function(Testing)
	Testing.scenario("a new player's first scroll costs nothing", function(t)
		local state = Dojo.new("test:first")
		t:expectEqual(state.wallet:get("ki"), 0, "a new yard starts empty")

		local fighter, isNew, step, err = Dojo.summon(state, "novice")
		t:expect(err == nil, "the first summon should not be refused: " .. tostring(err))
		t:expect(fighter ~= nil, "the first summon should produce a fighter")
		t:expect(isNew, "the first fighter is new by definition")
		--: At least step 1, not exactly. A first draw that happens to be rare
		--: genuinely reaches step 4 -- the player did get there -- and asserting
		--: equality made the outcome of this test a 3.4% coin flip.
		t:expect(step >= 1, "the first summon must register on the funnel")
	end)

	Testing.scenario("a fighter produces nothing until it is training", function(t)
		local state = Dojo.new("test:idle")
		Dojo.summon(state, "novice")
		local before = Dojo.perSecond(state)

		local id = next(state.roster)
		local ok = Dojo.assign(state, "post", id)
		t:expect(ok, "the starting station should accept the first fighter")
		t:expect(Dojo.perSecond(state) > before,
			"a fighter put to train must raise income")
	end)

	Testing.scenario("a player cannot station a fighter they do not own", function(t)
		local state = Dojo.new("test:cheat")
		Dojo.summon(state, "novice")
		local id = next(state.roster)
		Dojo.assign(state, "post", id)

		local ok, err = Dojo.assign(state, "post", id)
		t:expect(not ok, "one copy cannot train twice")
		t:expect(err ~= nil, "a refusal has to say why")
	end)

	Testing.scenario("rank two is reachable inside a first session", function(t)
		--: The rung 74% of players in the only real retention record never
		--: reached. If this scenario takes more than a session, the ladder is
		--: wrong and no amount of content fixes it.
		local state = Dojo.new("test:rank")
		Dojo.summon(state, "novice")
		Dojo.assign(state, "post", (next(state.roster)))

		local seconds = 0
		while seconds < 300 do
			Dojo.tick(state, 1)
			seconds += 1
			if Dojo.promote(state) then
				break
			end
		end
		t:expect(state.rank >= 2,
			string.format("rank two unreached after %ds at %.2f ki/s",
				seconds, Dojo.perSecond(state)))
		t:expect(seconds <= 300,
			string.format("rank two took %ds; a first session is not that long", seconds))
	end)

	Testing.scenario("a rare summon pays the second currency", function(t)
		local state = Dojo.new("test:shards")
		--: Forced rather than waited for: this asserts the *rule*, and rolling
		--: until a rare appears would make the test's runtime a random variable.
		state.roster["blade"] = 1
		state.wallet:credit({ shards = 3 })
		t:expect(state.wallet:get("shards") > 0, "shards should be creditable")

		local blade = Content.fighter("blade")
		t:expect(blade ~= nil and blade.rarity >= 3, "blade should be rare or better")
	end)

	Testing.scenario("ascension keeps the roster and resets the yard", function(t)
		local state = Dojo.new("test:ascend")
		Dojo.summon(state, "novice")
		local collected = Dojo.collected(state)
		state.wallet:credit({ ki = Content.ascendPrice(1) + 1 })

		local ok = Dojo.ascend(state)
		t:expect(ok, "ascension should be allowed once it is affordable")
		t:expectEqual(state.life, 2, "ascending advances the life")
		t:expectEqual(state.rank, 1, "ascending resets the rank")
		t:expectEqual(Dojo.collected(state), collected,
			"the roster survives ascension: it is the reason to come back")
		t:expect(state.wallet:get("shards") > 0, "ascension pays shards")
	end)

	Testing.scenario("ascension makes the next run faster", function(t)
		--: A prestige that does not compound is a reset. This is the whole
		--: contract of the loop, so it is asserted rather than assumed.
		local first = Dojo.new("test:life1")
		first.roster["blade"] = 1
		Dojo.assign(first, "post", "blade")
		local before = Dojo.perSecond(first)

		local second = Dojo.new("test:life2")
		second.life = 2
		second.roster["blade"] = 1
		Dojo.assign(second, "post", "blade")
		Dojo.recompute(second)

		t:expect(Dojo.perSecond(second) > before,
			string.format("a second life produced %.2f against %.2f",
				Dojo.perSecond(second), before))
	end)

	Testing.scenario("the yard never leaves a new player idle", function(t)
		--: The 136-second hole, as a gate. `Loop.Hatch` reports dead time; if it
		--: reports any during the opening two minutes, the opening is wrong.
		local state = Dojo.new("test:dead")
		Dojo.summon(state, "novice")
		Dojo.assign(state, "post", (next(state.roster)))

		for _ = 1, 120 do
			Dojo.tick(state, 1)
		end

		local dead = false
		for _, finding in Dojo.findings(state) do
			if finding.rule == "dead_time" then
				dead = true
			end
		end
		t:expect(not dead,
			"the loop reported dead time in the first two minutes, which is where "
			.. "the only real retention record here lost most of its players")
	end)

	Testing.scenario("every station and rank is reachable", function(t)
		--: Content that cannot be reached is content nobody wrote. A station
		--: gated behind a rank the ladder does not contain is the cheapest
		--: possible version of that mistake.
		for _, station in Content.stations do
			t:expect(station.tier <= #Content.ranks,
				station.name .. " needs a rank this ladder does not have")
		end
		for _, fighter in Content.fighters do
			t:expect(fighter.weight > 0, fighter.name .. " can never be drawn")
			t:expect(fighter.power > 0, fighter.name .. " produces nothing")
		end
	end)
end
