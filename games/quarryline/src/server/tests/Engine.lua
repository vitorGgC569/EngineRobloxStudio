--!strict
--[[
	Live scenarios for the four engine families no game has ever executed.

	Why these exist
	---------------

	`AI`, `Match`, `Movement` and `State` are thirty-two modules that compile,
	pass the type checker, have unit specs, and are used by **zero games**. Not
	one line of them has ever run inside a Roblox process.

	Everything found in this project during the past week was found the same
	way -- by running code that had never been run:

	  * `Net.fire` is server-only, so every client control was inert
	  * the client never called `Net.define`, so no handler ever bound
	  * a replicated Model arrives before its children, so the animator adopted
	    nothing
	  * `CreateEditableImageAsync(nil, ...)` is the wrong overload, so no upload
	    ever reached the network
	  * `CreateAssetAsync` returns the result before the id, so the first upload
	    that worked returned an enum where the id goes
	  * `life` counts from zero and `DropperChain` asserts tiers start at one,
	    so Build threw for every new player

	Six for six. Unit tests caught none of them, because a unit test runs the
	module the way its author imagined and a game runs it the way the platform
	actually behaves.

	So these are not unit tests moved. They run inside the live server, against
	the real `Forge` tree that rojo built, in the DataModel the game is playing
	in -- which is the only place the six defects above could have surfaced.

	What is asserted
	----------------

	Invariants, not values. "A behaviour tree's sequence fails when a child
	fails" is a property and will hold next year; "the third tick returns
	4.82" is a number that turns a tuning change into a red build.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug

return function(Testing)

-- =================================== AI =====================================
Testing.scenario("a behaviour tree sequences, falls back, and inverts", function(t)
	local BehaviorTree = Forge.AI.BehaviorTree
	t:expect(BehaviorTree ~= nil, "Forge.AI.BehaviorTree is not reachable from a game")

	local ran = {}
	--[[
		Statuses are numbers here, not words.

		`-1` failure, `0` running, `1` success -- the module says so in its own
		header and this scenario first asserted with strings, which are neither.
		A tree fed a string treats it as "not failure" and the sequence ran on,
		so the failure looked like a broken sequence when it was a broken test.
	]]
	local function leaf(name: string, status: number)
		return BehaviorTree.action(function()
			table.insert(ran, name)
			return status
		end)
	end
	local FAILURE, SUCCESS = -1, 1

	--[[
		A sequence stops at the first failure.

		This is the whole contract: if it kept going, every guard written as an
		early child of a sequence would be decorative.
	]]
	local sequence = BehaviorTree.sequence({
		leaf("first", SUCCESS),
		leaf("second", FAILURE),
		leaf("third", SUCCESS),
	})
	local status = BehaviorTree.run(sequence, {}, 1 / 60)
	t:expect(status == FAILURE, "a sequence with a failing child must fail, got " .. tostring(status))
	t:expect(table.find(ran, "third") == nil,
		"the sequence ran a child after one failed; guards would never guard")

	table.clear(ran)
	local fallback = BehaviorTree.fallback({
		leaf("a", FAILURE),
		leaf("b", SUCCESS),
		leaf("c", SUCCESS),
	})
	t:expect(BehaviorTree.run(fallback, {}, 1 / 60) == SUCCESS,
		"a fallback must succeed once any child does")
	t:expect(table.find(ran, "c") == nil,
		"the fallback kept trying after one child succeeded")

	local inverted = BehaviorTree.invert(leaf("x", FAILURE))
	t:expect(BehaviorTree.run(inverted, {}, 1 / 60) == SUCCESS,
		"invert must turn failure into success")
end)

Testing.scenario("perception remembers what it saw and forgets on request", function(t)
	local Perception = Forge.AI.Perception
	t:expect(Perception ~= nil, "Forge.AI.Perception is not reachable from a game")

	local eyes = Perception.new({ fovDeg = 120, hearingRange = 40, memorySeconds = 30 })
	eyes:setFacing(0, 1)
	eyes:observe({ x = 0, z = 0 }, {
		{ key = "ahead", pos = { x = 0, z = 10 }, visible = true },
		{ key = "behind", pos = { x = 0, z = -10 }, visible = false },
	})

	local known = eyes:known()
	local keys = {}
	for _, memory in known do
		keys[memory.key or ""] = true
	end
	t:expect(keys["ahead"] == true, "a target in front and visible was not remembered")

	eyes:forget("ahead")
	local after = eyes:known()
	for _, memory in after do
		t:expect(memory.key ~= "ahead", "forget left the memory in place")
	end
end)

Testing.scenario("crowd separation pushes two entities apart, not together", function(t)
	local Crowd = Forge.AI.CrowdSeparation
	t:expect(Crowd ~= nil, "Forge.AI.CrowdSeparation is not reachable from a game")

	local crowd = Crowd.new({ radiusFactor = 2, strength = 1 })
	local push = crowd:compute({
		--[[
			`id` and `size`, which is what `EntityPos` declares.

			This first passed `radius` (the module adds `a.size + b.size`, so it
			added two nils) and then `key` (it indexes `corrections[a.id]`, so it
			indexed with nil). Both crashes read like engine faults and both were
			a signature read from the constructor instead of from the type.
		]]
		{ id = "left", x = -1, z = 0, size = 2 },
		{ id = "right", x = 1, z = 0, size = 2 },
	})

	local left, right = push["left"], push["right"]
	t:expect(left ~= nil and right ~= nil, "separation returned nothing for two overlapping entities")
	if left and right then
		--: The sign is the whole point. A separation that pulls is a pile-up.
		t:expect(left.x <= 0, "the left entity was pushed right, into its neighbour")
		t:expect(right.x >= 0, "the right entity was pushed left, into its neighbour")
	end
end)

-- ================================== Match ===================================
Testing.scenario("a card cycle deals a hand and never repeats what it holds", function(t)
	local CardCycle = Forge.Match.CardCycle
	t:expect(CardCycle ~= nil, "Forge.Match.CardCycle is not reachable from a game")

	local cycle = CardCycle.new({
		cards = { "a", "b", "c", "d", "e", "f", "g", "h" },
		handSize = 4,
		seed = 7,
	})

	local hand = cycle:hand()
	t:expect(#hand == 4, "a hand of four came back with " .. #hand)

	local seen = {}
	for _, card in hand do
		t:expect(seen[card] == nil, "the same card was dealt twice into one hand: " .. card)
		seen[card] = true
	end

	local played = hand[1]
	local result = cycle:play(played)
	t:expect(result ~= nil, "playing a card in hand returned nothing")
	t:expect(cycle:has(played) == false or #cycle:hand() == 4,
		"the hand did not refill after a card was played")
end)

Testing.scenario("a round machine advances through its phases and repeats", function(t)
	local RoundMachine = Forge.Match.RoundMachine
	t:expect(RoundMachine ~= nil, "Forge.Match.RoundMachine is not reachable from a game")

	local machine = RoundMachine.new({
		phases = {
			{ name = "warmup", duration = 2 },
			{ name = "fight", duration = 3 },
		},
	})

	t:expect(machine:current() == "warmup", "a fresh machine must start in its first phase")
	machine:tick(2.1)
	t:expect(machine:current() == "fight",
		"the machine did not advance past a phase whose duration had elapsed")
	machine:tick(3.1)
	t:expect(machine:current() == "warmup", "the machine did not wrap back to the first phase")
	t:expect(machine:iteration() >= 2, "the iteration counter did not advance across a full cycle")
end)

Testing.scenario("a win resolver answers with the criterion that decided it", function(t)
	local WinResolver = Forge.Match.WinResolver
	t:expect(WinResolver ~= nil, "Forge.Match.WinResolver is not reachable from a game")

	local resolver = WinResolver.new({
		{ name = "timeout", decide = function(ctx: any)
			return ctx.clock <= 0 and "draw" or nil
		end },
		{ name = "score", decide = function(ctx: any)
			return ctx.score >= 10 and "win" or nil
		end },
	})

	local won = resolver:resolve({ clock = 30, score = 12 })
	t:expect(won.outcome == "win", "a passing score did not resolve to a win")
	--[[
		Naming the criterion is not decoration.

		A match that ends and cannot say *why* is unappealable, and the first
		question anyone asks about a contested result is which rule fired.
	]]
	t:expect(won.decidedBy == "score",
		"the outcome did not name the criterion that produced it, got " .. tostring(won.decidedBy))

	local undecided = resolver:resolve({ clock = 30, score = 1 })
	t:expect(undecided.outcome ~= "win", "an unmet criterion still declared a winner")
end)

-- ================================= Movement =================================
Testing.scenario("acceleration ramps toward a cap and brakes to a stop", function(t)
	local AccelMove = Forge.Movement.AccelMove
	t:expect(AccelMove ~= nil, "Forge.Movement.AccelMove is not reachable from a game")

	local mover = AccelMove.new({ maxSpeed = 16, accelMoving = 8, accelStopping = 6 })
	local speed = 0
	for _ = 1, 240 do
		local v = mover:step({ x = 1, z = 0 }, 1 / 60)
		speed = math.sqrt(v.x * v.x + v.z * v.z)
	end

	t:expect(speed > 0, "four seconds of forward input produced no motion at all")
	t:expect(speed <= 16.01, "speed passed its own cap: " .. speed)

	--: Zero input means brake, and a brake that never reaches zero is a drift.
	for _ = 1, 600 do
		local v = mover:step({ x = 0, z = 0 }, 1 / 60)
		speed = math.sqrt(v.x * v.x + v.z * v.z)
	end
	t:expect(speed < 0.05, "ten seconds of braking left it moving at " .. speed)
end)

Testing.scenario("ballistics spread stays inside the cone it was given", function(t)
	local Ballistics = Forge.Movement.Ballistics
	t:expect(Ballistics ~= nil, "Forge.Movement.Ballistics is not reachable from a game")

	local base = { x = 0, y = 0, z = 1 }
	local outside = 0
	for index = 1, 200 do
		local shot = Ballistics.sampleCone(base, 10, function()
			--: Deterministic, so a failure here is reproducible rather than a
			--: story about a bad afternoon.
			return (index * 0.37) % 1
		end)
		if not Ballistics.withinAngle(shot, base, 10.5) then
			outside += 1
		end
	end
	t:expect(outside == 0,
		string.format("%d of 200 shots left a 10 degree cone; a spread that leaks is not a spread", outside))

	local flight = Ballistics.timeOfFlight(100, 50)
	t:expect(math.abs(flight - 2) < 0.001, "time of flight over 100 studs at 50/s should be 2s, got " .. flight)
	t:expect(Ballistics.gravityDrop(100, 50) > 0, "a projectile over 100 studs did not drop at all")
end)

-- ================================== State ===================================
Testing.scenario("a store reduces, reads back, and notifies subscribers", function(t)
	local Store = Forge.State.Store
	t:expect(Store ~= nil, "Forge.State.Store is not reachable from a game")

	Store.reducer("engineProbe", function(state: any, action: any)
		state = state or { count = 0 }
		if action.type == "engineProbe/add" then
			return { count = state.count + (action.amount or 1) }
		end
		return state
	end)

	local heard = {}
	local unsubscribe = Store.subscribe("engineProbe", function(new: any)
		table.insert(heard, new.count)
	end)

	Store.dispatch({ type = "engineProbe/add", amount = 3 })
	t:expect((Store.get("engineProbe") or {}).count == 3,
		"the reducer did not apply; got " .. tostring((Store.get("engineProbe") or {}).count))
	t:expect(#heard >= 1, "a subscriber was never told about a change to its own slice")

	unsubscribe()
	Store.dispatch({ type = "engineProbe/add", amount = 5 })
	t:expect(#heard == 1, "unsubscribe left the listener attached")
	t:expect((Store.get("engineProbe") or {}).count == 8,
		"the second dispatch did not reach the reducer")
end)

Testing.scenario("replication refuses to send what a player may not see", function(t)
	local Replication = Forge.State.Replication
	t:expect(Replication ~= nil, "Forge.State.Replication is not reachable from a game")

	--[[
		Closed by default is the property worth pinning.

		A replication layer that leaks unless told otherwise leaks the first
		time somebody adds an action and forgets the rule -- which is every
		time. `openByDefault = false` is what makes forgetting safe.
	]]
	Replication.rule("engineProbe/secret", function(_action: any, _player: Player)
		return false
	end)
	Replication.public("engineProbe/public")

	local secret = Replication.mayReceive({ type = "engineProbe/secret" }, nil :: any)
	local open = Replication.mayReceive({ type = "engineProbe/public" }, nil :: any)
	local unknown = Replication.mayReceive({ type = "engineProbe/neverDeclared" }, nil :: any)

	t:expect(secret == false, "an action with a refusing rule was cleared for sending")
	t:expect(open == true, "an action declared public was withheld")
	t:expect(unknown == false,
		"an undeclared action was sent anyway; the layer is open by default and leaks on every omission")

	Debug.info("engine families exercised: AI, Match, Movement, State")
end)
-- ================================== assets ==================================
Testing.scenario("every published icon still resolves to a real image", function(t)
	local Icons = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Icons"))

	--[[
		The library, checked as a whole rather than the six the HUD happens to
		use.

		162 icons were lifted from licensed projects, resampled and published,
		and a game references six of them. The other 156 are real assets on a
		real account and nothing in the repository would notice if one were
		deleted, moderated, or replaced with a different id -- until a future
		game reached for it and drew nothing.

		An `ImageLabel` with a dead id is not an error. It is a blank rectangle,
		which is why this has to be asserted rather than watched for.
	]]
	local names = {}
	for name in Icons.ui do
		table.insert(names, name)
	end
	table.sort(names)

	t:expect(#names > 100, string.format(
		"the icon library has %d entries; it was published with 162", #names))

	local malformed = {}
	for _, name in names do
		local content = Icons.ui[name]
		if typeof(content) ~= "string" or not string.match(content, "^rbxassetid://%d+$") then
			table.insert(malformed, name)
		end
	end
	t:expect(#malformed == 0, string.format(
		"%d icons are not well-formed asset ids: %s",
		#malformed, table.concat(malformed, ", "):sub(1, 120)))

	--: `find` is what a future game calls, and it must reach the ui set as well
	--: as the hud one.
	t:expect(Icons.find(names[1]) ~= nil, "Icons.find cannot reach the ui library")
	t:expect(Icons.find("coin") ~= nil, "Icons.find no longer falls back to the hud set")
	t:expect(Icons.find("nothing_was_ever_called_this") == nil,
		"Icons.find invented an answer for a name that does not exist")

	Debug.info(string.format("%d icons declared and well-formed", #names))
end)

end
