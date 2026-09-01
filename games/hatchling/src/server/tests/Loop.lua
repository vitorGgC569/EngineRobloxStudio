--!strict
--[[
	hatchling — the game, played by nobody.

	Written before the world was, which is the whole point. The previous game in
	this repository got its scenario suite after eight builds, and every one of
	those eight was validated by a person reading screenshots.

	What belongs here
	-----------------

	**Rules and the theme contract, not balance.** "A better egg leans rarer"
	survives every tuning pass; "egg 4 drops 19% Legendary" turns the next
	pacing change into a red build. The pacing numbers live in the harness
	simulation, where being wrong is information rather than a failure.

	The theme contract is the unusual one and the one worth guarding hardest:
	this game is going to be reskinned, and the entire promise of that is that a
	theme cannot change how the game plays. There is a scenario below that
	fails if it can.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Theme = require(ReplicatedStorage.Shared.Theme)
local Sim = require(ServerScriptService.Server.systems.Sim)

--: Deterministic, so a failure is reproducible rather than a thing that
--: happened once on somebody's machine.
local function seeded(seed: number): () -> number
	return function()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
end

local function pickFirst(tier: number): string
	return Theme.pets[tier][1].id
end

return function(Testing)
	-- ========================================================= the contract
	Testing.scenario("the theme covers every tier the machine has", function(t)
		local ok, why = Theme.check(Sim.TIERS, Sim.EGG_TIERS, Sim.ZONES)
		t:expect(ok, tostring(why))
		for tier = 1, Sim.TIERS do
			local list = Theme.pets[tier]
			t:expect(list ~= nil and #list > 0,
				string.format("rarity tier %d has no creature", tier))
		end
	end)

	Testing.scenario("no creature carries a number the machine owns", function(t)
		--[[
			The reskin promise, guarded.

			The moment a theme can say how strong its creature is, the second
			theme is a rebalance and the third is a rewrite. Power comes from
			the rarity tier and from nothing else, so two creatures on the same
			rung are exactly as strong whatever they are called.
		]]
		local byTier: { [number]: number } = {}
		for _, pet in Theme.roster() do
			local power = Sim.power({ id = pet.id, tier = pet.tier })
			if byTier[pet.tier] then
				t:expect(byTier[pet.tier] == power,
					string.format("two tier-%d creatures have different power",
						pet.tier))
			end
			byTier[pet.tier] = power
			for _, field in { "power", "weight", "cost", "value", "multiplier" } do
				t:expect((pet :: any)[field] == nil,
					string.format("theme entry '%s' carries a balance field '%s'",
						pet.id, field))
			end
		end
	end)

	-- ============================================================= the loop
	Testing.scenario("a crate pays more once a pet is out", function(t)
		local state = Sim.blank()
		local _, bare = Sim.breakCrate(state)
		t:expect(bare.coins > 0, "an empty bench earned nothing at all")

		state.pets.x = { id = "test", tier = Sim.TIERS }
		Sim.equip(state, "x")
		local _, armed = Sim.breakCrate(state)
		t:expect(armed.coins > bare.coins,
			"equipping the strongest pet in the game changed nothing")
	end)

	Testing.scenario("hatching spends, yields and remembers", function(t)
		local state = Sim.blank()
		state.coins = Sim.eggCost(1) * 4
		local before = state.coins
		local ok, drop = Sim.hatch(state, 1, pickFirst, 0.5, 0.99)
		t:expect(ok, "a hatch that could be afforded was refused")
		t:expect(state.coins == before - Sim.eggCost(1), "the egg was not paid for")
		t:expect(state.pets[drop.uid] ~= nil, "no pet arrived")
		t:expect(drop.isNew, "the first of a species was not marked new")
		t:expect(state.seen[drop.id], "the book did not record it")

		--: Auto-equipped while there is room. A first hatch a player has to go
		--: and find is a first hatch they do not feel.
		t:expect(#state.equipped == 1, "the first pet was not put out")

		local poor = Sim.blank()
		poor.coins = 0
		t:expect(not (Sim.hatch(poor, 1, pickFirst, 0.5, 0.99)),
			"hatching was allowed with nothing to pay with")
	end)

	Testing.scenario("a dearer egg leans rarer, and every egg can still surprise",
		function(t)
			--[[
				The shape, not the percentages. An early version scaled each
				rarity's own base weight rather than sliding the curve, and the
				most expensive egg in the game came out half Common -- a worse
				table than the third-cheapest, and nothing in the project could
				have told us.
			]]
			local roll = seeded(4242)
			local average = {}
			for egg = 1, Sim.EGG_TIERS do
				local total = 0
				for _ = 1, 4000 do
					total += Sim.rollTier(egg, roll())
				end
				average[egg] = total / 4000
			end
			for egg = 2, Sim.EGG_TIERS do
				t:expect(average[egg] > average[egg - 1],
					string.format("egg %d does not drop rarer than egg %d",
						egg, egg - 1))
			end

			--: And the lottery survives at the bottom: the cheapest egg must
			--: still be able to reach the top of the ladder.
			local weights = Sim.eggWeights(1)
			t:expect(weights[Sim.TIERS] > 0,
				"the starter egg cannot produce the rarest creature at all")
		end)

	Testing.scenario("a dry run ends", function(t)
		--: Pity is per egg tier. Rolling the worst possible result forever must
		--: eventually be interrupted, or the tail is where players quit.
		local state = Sim.blank()
		state.coins = 1e12
		local best = 0
		for _ = 1, Sim.PITY_AT + 2 do
			local _, drop = Sim.hatch(state, 1, pickFirst, 0.0, 0.99)
			best = math.max(best, drop.tier)
		end
		t:expect(best >= Sim.PITY_FLOOR,
			string.format("%d worst-case rolls never triggered pity", Sim.PITY_AT + 2))
	end)

	-- ============================================================ the bench
	Testing.scenario("the bench holds the best, and only what fits", function(t)
		local state = Sim.blank()
		for tier = 1, Sim.TIERS do
			state.pets["p" .. tier] = { id = "t" .. tier, tier = tier }
		end
		Sim.equipBest(state)
		t:expect(#state.equipped == state.slots,
			"equip-best did not fill the bench")
		--: The strongest in the game must be on it.
		local found = false
		for _, uid in state.equipped do
			if state.pets[uid].tier == Sim.TIERS then
				found = true
			end
		end
		t:expect(found, "the rarest pet owned was left in the box")

		local before = Sim.multiplier(state)
		t:expect(not Sim.equip(state, state.equipped[1]), "a pet was equipped twice")
		t:expect(Sim.multiplier(state) == before, "a refused equip still changed the multiplier")
	end)

	Testing.scenario("an equipped pet cannot be released by accident", function(t)
		--: Releasing what you are standing there using is the one destructive
		--: action in the game, and the one a player does by mistake.
		local state = Sim.blank()
		state.pets.only = { id = "x", tier = 3 }
		Sim.equip(state, "only")
		t:expect(not Sim.release(state, "only"), "an equipped pet was released")
		Sim.unequip(state, "only")
		local ok, detail = Sim.release(state, "only")
		t:expect(ok, "an unequipped pet could not be released")
		t:expect(detail.shards > 0, "releasing paid no shards")
	end)

	-- ============================================================ the ladder
	Testing.scenario("zones cost longer the further out they are", function(t)
		--[[
			The failure this catches is the one the simulation found: priced by
			hand, the toll cost 5.6 minutes at zone 2 and 0.8 at zone 6. A
			progression that accelerates has no late game.
		]]
		local last = 0
		for zone = 2, Sim.ZONES do
			local minutes = Sim.zoneToll(zone) / Sim.incomePerMinute(zone - 1)
			t:expect(minutes > last,
				string.format("zone %d is a shorter wait than zone %d", zone, zone - 1))
			last = minutes
		end
	end)

	Testing.scenario("a zone cannot be entered before it is opened", function(t)
		local state = Sim.blank()
		t:expect(not Sim.travel(state, Sim.ZONES), "walked straight into the last zone")
		state.coins = 0
		t:expect(not Sim.unlockZone(state), "a toll was waived")
		state.coins = Sim.zoneToll(2)
		t:expect(Sim.unlockZone(state), "an affordable toll was refused")
		t:expect(state.zone == 2, "paying the toll did not move the player")
	end)

	Testing.scenario("a rebirth keeps the book and gives back the rest", function(t)
		local state = Sim.blank()
		state.earned = Sim.rebirthCost(0)
		state.coins = 999
		state.seen.something = true
		state.shards = 40
		state.pets.a = { id = "a", tier = 2 }
		local ok = Sim.rebirth(state)
		t:expect(ok, "an earned rebirth was refused")
		t:expect(state.seen.something, "the collection was wiped")
		t:expect(state.shards == 40, "shards were wiped")
		t:expect(state.coins == Sim.blank().coins, "coins were not given back")
		t:expect(next(state.pets) == nil, "the pets survived a rebirth")
		t:expect(Sim.rebirthBonus(state.rebirths) > 1, "rebirth paid no bonus")
	end)

	Testing.scenario("a broken save is repaired rather than trusted", function(t)
		--: Equipped ids that no longer name a pet used to return nil from
		--: `multiplier` forever, which is a player whose crates silently stop
		--: paying and who has no way to find out why.
		local state = Sim.reconcile({
			coins = 5, equipped = { "gone", "gone2" }, pets = {}, slots = 3,
		})
		t:expect(#state.equipped == 0, "the bench kept ids with no pet behind them")
		t:expect(Sim.multiplier(state) == 1, "a repaired bench still multiplies")
		t:expect(Sim.reconcile(nil).coins == Sim.blank().coins,
			"reconciling nothing did not produce a fresh save")
	end)
end
