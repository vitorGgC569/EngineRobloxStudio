--!strict
--[[
	carvewood — the game, played by nobody.

	These run inside the live game during bootstrap and publish a report that
	`forge gametest` reads. That is the whole point: every other check in this
	project reads source, and source cannot tell you whether planting a seed
	produces a tree.

	Why this file exists at all
	---------------------------

	The loop was verified twice before this: once in the pure-rules harness,
	which cannot see an Instance, and once by a person driving prompts by hand
	and reading screenshots. The first misses everything about the world; the
	second costs a minute per question and a picture per answer, and it is the
	reason a spawn pad sat inside a shop for two builds without anybody
	noticing.

	What is worth asserting here
	----------------------------

	**Rules and wiring, not balance.** "A felled tree yields logs" stays true
	next month; "a Pine yields 2" turns every tuning pass into a red build.

	**Things the harness cannot reach.** The pure simulation already proves the
	economy. What only a running game can prove is that the remote is
	registered, the world redraws, the shop stands where the customer walks,
	and nothing is standing inside anything else.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Trees = require(ReplicatedStorage.Shared.Trees)
local Wire = require(ReplicatedStorage.Shared.Wire)

local systems = ServerScriptService.Server.systems
local Yard = require(systems.Yard)
local Grove = require(systems.Grove)
local Shop = require(systems.Shop)
local Carving = require(systems.Carving)
local Customers = require(systems.Customers)

--: A yard with everything unlocked, for scenarios that need to reach the far
--: end of the ladder without playing to it.
local function stocked(): Yard.State
	local state = Yard.reconcile(nil)
	state.cash = 500000
	state.seeds = { pine = 50, oak = 50, starheart = 5 }
	return state
end

return function(Testing)
	-- ============================================================ the world
	Testing.scenario("the world exists before any player does", function(t)
		--[[
			The failure this catches is the one that produced the first
			screenshot of this game: a character in freefall against an empty
			sky with a working HUD drawn over it. The yards used to be built
			inside `arrive`, behind a profile load that takes up to twelve
			seconds, and a player joins faster than that.
		]]
		local grove = Workspace:FindFirstChild("Grove")
		t:expect(grove ~= nil, "the Grove folder was never built")
		if not grove then
			return
		end
		local yards, spawns = 0, 0
		for _, child in grove:GetChildren() do
			if child:IsA("Folder") and string.match(child.Name, "^Yard") then
				yards += 1
			end
			if child:IsA("SpawnLocation") then
				spawns += 1
			end
		end
		t:expect(yards == 6, string.format("expected 6 standing yards, found %d", yards))
		t:expect(spawns >= 1, "the plaza has no fallback spawn")
	end)

	Testing.scenario("nothing is standing inside anything else", function(t)
		--[[
			Two builds shipped with a spawn pad inside a shop and a scenery tree
			growing through a shelf. Both were found by looking at a picture;
			both are arithmetic.

			Only the things a player interacts with are checked. Decorative
			overlap is a matter of taste and this is not a taste test.
		]]
		local grove = Workspace:FindFirstChild("Grove")
		if not grove then
			t:expect(false, "no Grove to inspect")
			return
		end
		local overlaps = {}
		for _, yard in grove:GetChildren() do
			if not yard:IsA("Folder") then
				continue
			end
			local spawn = yard:FindFirstChild("Spawn")
			if not (spawn and spawn:IsA("BasePart")) then
				continue
			end
			--: Characters are excluded. A player standing on their own spawn
			--: pad is the pad working, and counting eighteen limbs as
			--: overlaps buries the one finding that matters.
			local ignore: { Instance } = { spawn }
			for _, player in Players:GetPlayers() do
				if player.Character then
					table.insert(ignore, player.Character)
				end
			end
			local params = OverlapParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = ignore
			for _, hit in Workspace:GetPartBoundsInBox(spawn.CFrame,
					spawn.Size + Vector3.new(2, 8, 2), params) do
				--: The ground under a spawn pad is not an overlap.
				if hit.Name ~= "Ground" and hit.Name ~= "Base"
						and hit.Name ~= "Kerb" and hit.Name ~= "Plaza"
						and not string.match(hit.Name, "^Spoke")
						and not string.match(hit.Name, "^Ring") then
					table.insert(overlaps, yard.Name .. ".Spawn <- " .. hit.Name)
				end
			end
		end
		t:expect(#overlaps == 0,
			"something is inside a spawn pad: " .. table.concat(overlaps, ", "))
	end)

	Testing.scenario("every remote the client calls is registered", function(t)
		--[[
			Firing into an unregistered remote raises nothing anywhere. The
			client hangs until it times out, which looks exactly like a broken
			button and is the hardest failure in this codebase to see.
		]]
		local missing = {}
		for name, spec in Wire.definitions do
			if spec.dir ~= "c2s" then
				continue
			end
			if not Forge.Net.handles(name) then
				table.insert(missing, name)
			end
		end
		t:expect(#missing == 0,
			"declared but nothing listens: " .. table.concat(missing, ", "))
	end, { timeout = 10 })

	-- ============================================================= the loop
	Testing.scenario("a seed becomes a tree, and the tree becomes logs", function(t)
		local state = stocked()
		local ok = Yard.plant(state, 1, "pine")
		t:expect(ok, "planting a held seed was refused")
		t:expect(state.seeds.pine == 49, "planting did not spend the seed")

		--: Rewound rather than waited for. Twenty seconds is a fifth of the
		--: suite's whole budget and proves nothing the arithmetic does not.
		state.plots[1].plantedAt -= 9999
		t:expect(Yard.ready(state.plots[1]), "a rewound tree is not ready")

		local swings, felled = 0, false
		while swings < 40 and not felled do
			local hit, detail = Yard.strike(state, 1)
			t:expect(hit, "a swing at a grown tree was refused")
			swings += 1
			felled = detail.felled == true
		end
		t:expect(felled, "the tree never fell")
		t:expect(swings > 1, "one swing felled it -- the axe is not biting")
		local logs = Yard.counts(state)
		t:expect(logs > 0, "felling produced no logs")
		t:expect(state.plots[1].species == nil, "the plot still holds a tree")
	end)

	Testing.scenario("the bench turns a log into a graded piece", function(t)
		local state = stocked()
		state.logs.oak = 3
		local session = Carving.begin("oak", state.axe, math.random, 0)

		--: Struck exactly on the zone's centre each time, so the grade is the
		--: best the rules allow. A scenario that swings randomly asserts
		--: nothing repeatable.
		for _ = 1, Carving.STROKES do
			local when = session.centre * Carving.SWEEP / 2
			Carving.strike(session, session.startedAt + when)
		end
		t:expect(session.done, "three strokes did not finish the piece")
		local grade = Carving.grade(session)
		t:expect(grade == "flawless" or grade == "master",
			"perfect timing graded '" .. grade .. "'")

		local ok = Yard.carveInto(state, "oak", grade)
		t:expect(ok, "carving the log was refused")
		t:expect(#state.carvings == 1, "no piece reached the pack")
		t:expect(Yard.fairPrice("oak", grade) > Yard.fairPrice("oak", "rough"),
			"a better grade is not worth more")
	end)

	Testing.scenario("a piece on a shelf is a piece a customer can value", function(t)
		local state = stocked()
		state.carvings = { { species = "oak", quality = "fine" } }
		local ok, detail = Yard.stock(state, 1, 1, Yard.fairPrice("oak", "fine"))
		t:expect(ok, "stocking the first shelf was refused: " .. tostring(detail))
		t:expect(state.shop.stands[1] ~= nil, "the shelf is still empty")
		t:expect(#state.carvings == 0, "the piece is on the shelf and in the pack")

		local buyer = { budget = 99999, taste = 2, generosity = 1.3, patience = 12 }
		local verdict = Yard.decide(buyer, state.shop.stands[1], state.shop)
		t:expect(verdict == "buy",
			"a generous matched customer would not pay the fair price")

		local tight = { budget = 99999, taste = 2, generosity = 0.85, patience = 12 }
		t:expect(Yard.decide(tight, state.shop.stands[1], state.shop) == "haggle",
			"a tight customer neither bought nor haggled")

		local greedy = { species = "oak", quality = "fine",
			price = Yard.fairPrice("oak", "fine") * 3 }
		t:expect(Yard.decide(buyer, greedy, state.shop) == "leave",
			"nobody walks away from triple the fair price")
	end)

	Testing.scenario("an empty shop draws nobody and a stocked one draws somebody",
		function(t)
			--[[
				Footfall is the only thing telling a player to stock their
				shelves. If an empty shop still drew a crowd the mechanic would
				be decoration.
			]]
			local state = stocked()
			t:expect(Customers.interval(state) == math.huge,
				"customers arrive at a shop with nothing in it")
			state.shop.stands[1] = { species = "pine", quality = "fine", price = 8 }
			local busy = Customers.interval(state)
			t:expect(busy < math.huge, "a stocked shop still draws nobody")

			state.shop.upgrades.signage = 5
			t:expect(Customers.interval(state) < busy,
				"the signage upgrade does not bring anyone in")
		end)

	-- ========================================================= the ladder
	Testing.scenario("the shop stacks floors and the shelves follow", function(t)
		local state = stocked()
		local first = Yard.standCount(state.shop)
		t:expect(first == 2, string.format("a new shop opens with %d shelves, not 2", first))

		Yard.buyUpgrade(state, "counter")
		t:expect(Yard.standCount(state.shop) > first, "the counter upgrade added no shelf")

		--: `floors` roots on `counter`, so it must have been unreachable a
		--: moment ago and reachable now.
		local ok = Yard.buyUpgrade(state, "floors")
		t:expect(ok, "a floor could not be bought after the counter")
		t:expect(Yard.floors(state.shop) == 2, "the second floor did not land")

		local offsets = Shop.standOffsets(Yard.standsPerFloor(state.shop))
		t:expect(#offsets == Yard.standsPerFloor(state.shop),
			"the grid returned a different number of shelf positions than the rules expect")
	end)

	Testing.scenario("rolling reaches every rarity and never stalls", function(t)
		--[[
			The pity counter lives in the profile rather than on the roller, so
			a roller rebuilt per call would restart everyone's luck forever.
			Six hundred packs is enough to see the top of the ladder if the
			table is wired correctly and to notice if it is not.
		]]
		local state = stocked()
		local seed = 20260901
		local seen = {}
		for _ = 1, 600 do
			local ok, drop = Yard.rollSeed(state, function()
				seed = (seed * 1103515245 + 12345) % 2147483648
				return seed / 2147483648
			end)
			t:expect(ok, "a roll was refused with half a million in the bank")
			seen[drop.tier] = (seen[drop.tier] or 0) + 1
		end
		t:expect(seen[1] ~= nil, "600 packs produced no Common")
		t:expect(seen[7] ~= nil or seen[6] ~= nil,
			"600 packs never reached Mythic or Celestial")
		t:expect(state.essence > 0, "rolling banked no essence")
	end)

	Testing.scenario("nobody can plant a seed they do not hold", function(t)
		--: The seed stock replaced a cash-bought level, and this is the rule
		--: that replaced it. Without it a Celestial costs nothing.
		local state = Yard.reconcile(nil)
		state.seeds = {}
		local ok, why = Yard.plant(state, 1, "starheart")
		t:expect(not ok, "planting a seed the player does not have was allowed")
		t:expect(type(why) == "string" and #why > 0, "the refusal gave no reason")
	end)

	Testing.scenario("an old profile keeps what it paid for", function(t)
		--[[
			`state.level` was the whole progression before seeds were rolled.
			A migration that drops it silently resets everybody who played the
			previous build, and nothing else in this project would notice.
		]]
		local old = {
			cash = 900, level = 4, slots = 4, axe = 2, crew = 1,
			plots = { {}, {}, {}, {} }, logs = {}, carved = { oak = 3 },
			chopped = 40, sold = 5, lastSeen = 0,
		}
		local state = Yard.reconcile(old)
		t:expect(state.cash == 900, "the migration lost the player's cash")
		t:expect(Yard.seedCount(state) > 0, "a level-4 profile migrated to no seeds")
		t:expect(#state.carvings == 3, "three carved pieces did not survive")
		t:expect(state.level == nil, "the retired level field is still there")
	end)
end
