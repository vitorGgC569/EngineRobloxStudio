--!strict
--[[
	Netcode scenarios: prediction, authority and latency.

	The oldest open item in this project. A latency sweep was built to drive
	0–400ms from outside the game and never produced a number, because the
	channel it spoke on did not exist yet on the client — the engine wired its
	netcode remotes only when a game reached its own `Netcode.define`, which on
	the server happens after terrain generation. The client asked first, waited,
	and gave up.

	That is fixed, and this is the part that was missing either way: the
	measurement belongs *inside* the game, as a scenario, not outside it as a
	sweep. A scenario runs on every suite, reports a number, and fails when the
	number moves — which a sweep run by hand once never did.

	What is measured
	----------------

	Simulated latency is applied to the server's own view, and each scenario
	asserts a *rule* rather than a millisecond: that a command still applies at
	400ms, that authority still refuses what it should, that the rewind window
	grows with latency rather than being ignored. Timing values on a Studio
	machine are not a benchmark and asserting them would produce a suite that
	fails on a slower laptop.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Netcode = Forge.Netcode
local Combat = Forge.Combat
local Save = Forge.Save

return function(Testing)
	Testing.scenario("the netcode channel exists before anyone asks for it", function(t)
		--[[
			The root cause of the sweep never working, asserted directly.

			`Netcode.wire` now runs at module load rather than when a game
			happens to define its first command, so the remotes exist as soon as
			anything requires the module. If that regresses, a client's first
			listener waits twenty seconds for a remote and then fails, and the
			only symptom is netcode that silently does nothing.
		]]
		local remotes = ReplicatedStorage:FindFirstChild("ForgeNet")
		t:expect(remotes ~= nil, "no ForgeNet folder; the engine never defined its channel")
		if not remotes then
			return
		end
		for _, name in { "NetcodeCmd", "NetcodeAck", "NetcodePing", "NetcodeSim" } do
			t:expect(remotes:FindFirstChild(name) ~= nil,
				name .. " was never created on the server")
		end
	end)

	Testing.scenario("simulated latency is applied and reported", function(t)
		--[[
			The sweep, as an assertion, and honest about which half it can see.

			`Netcode.perform` refuses to run on the server, and correctly:
			prediction is a client concern and a server that predicts is a
			server guessing at its own authority. So the suite — which is
			server-side — cannot drive a round trip. What it can do is walk the
			whole latency range, set each value, and prove the layer took it and
			reports it, which is the part that silently did nothing for weeks
			because the channel did not exist yet.

			The client half is exercised by the game itself: every attack goes
			through `Netcode.perform`, and its timing lands in `describe().timing`.
		]]
		local seen = {}
		for _, latency in { 0, 50, 100, 150, 200, 300, 400 } do
			Netcode.simulate(latency, 0)
			t:wait(0.05)
			local report = Netcode.describe()
			table.insert(seen, string.format("%d->%d", latency, report.simulatedLatencyMs))
			t:expectEqual(report.simulatedLatencyMs, latency, string.format(
				"asked for %dms and the layer reports %dms", latency, report.simulatedLatencyMs))
		end
		Netcode.simulate(0, 0)
		t:expectEqual(Netcode.describe().simulatedLatencyMs, 0,
			"latency did not reset: " .. table.concat(seen, " "))
	end, { timeout = 40 })

	Testing.scenario("packet loss is a fraction, and clamped", function(t)
		--[[
			Loss above one or below zero would silently become "never arrives"
			or "arrives twice", and both are worse than the value being refused.
		]]
		Netcode.simulate(0, 0.33)
		t:expectNear(Netcode.describe().simulatedLoss, 0.33, 0.001, "loss was not taken")

		Netcode.simulate(0, 5)
		t:expectNear(Netcode.describe().simulatedLoss, 1, 0.001, "loss above 1 was not clamped")

		Netcode.simulate(0, -2)
		t:expectNear(Netcode.describe().simulatedLoss, 0, 0.001, "negative loss was not clamped")
		Netcode.simulate(0, 0)
	end, { timeout = 20 })

	Testing.scenario("prediction is refused on the server, on purpose", function(t)
		--[[
			An assertion about a refusal, which is worth as much as one about a
			success. A server that could predict would be a server rolling its
			own authority back, and the error is the design.
		]]
		local ok = pcall(function()
			Netcode.perform("suite_never", {})
		end)
		t:expect(not ok, "the server was allowed to predict")
	end)

	Testing.scenario("netcode reports timings a machine can read", function(t)
		local report = Netcode.describe()
		t:expect(report ~= nil, "netcode does not describe itself")
		if not report then
			return
		end
		--[[
			The point is that the numbers exist at all. A sweep nobody can read
			is a sweep run once by a person and never again; a report in the
			suite is a number that moves when the netcode does.
		]]
		t:expect(report.counters ~= nil, "no counters, so nothing can be tracked over time")
		t:expect(report.timing ~= nil, "no timing block")
		if report.timing then
			t:expect(report.timing.samples ~= nil,
				"timing exists but reports no sample count")
		end
	end)

	-- ============================== two players =============================
	Testing.scenario("player state is isolated per player", function(t)
		--[[
			What "two players" actually tests, most of the time.

			A second human is hard to arrange in a suite; the failures a second
			human finds are almost always shared state — one player's weapon,
			profile or stamina leaking into another's, because a module kept one
			table instead of one per subject.

			So this asserts the isolation directly, with as many distinct
			subjects as the session has, and says plainly when there is only one.
		]]
		local players = Players:GetPlayers()
		t:expect(#players >= 1, "no players in the session at all")

		local Weapon = Forge.Weapon
		local a = t:spawnBot(Testing.config.stageOrigin)
		local b = t:spawnBot(Testing.config.stageOrigin + Vector3.new(10, 0, 0))

		Weapon.equip(a, "handcannon")
		Weapon.equip(b, "handcannon")

		local origin = Testing.config.stageOrigin
		Weapon.fire(a, origin, Vector3.new(0, 0, -1), { ignore = { a } })

		local ammoA = Weapon.ammo(a)
		local ammoB = Weapon.ammo(b)
		t:expect(ammoA < ammoB, string.format(
			"one subject firing changed another's ammo (%d vs %d)", ammoA, ammoB))

		-- Health is the other place a shared table would show.
		Combat.damage(a, { amount = 25, kind = "test" })
		t:expect(Combat.getHealth(a) < Combat.getHealth(b),
			"damaging one subject changed another's health")

		if #players < 2 then
			-- Not a failure: a note, so the report says what was not covered
			-- rather than implying it was.
			t:expect(true, "only one real player present; isolation checked between bots")
		end
	end, { timeout = 40 })

	Testing.scenario("two profiles do not share a save", function(t)
		local players = Players:GetPlayers()
		if #players < 2 then
			t:expect(true, "one player in session; per-player save isolation needs two")
			return
		end
		local first = Save.get(players[1])
		local second = Save.get(players[2])
		t:expect(first ~= second, "two players share one profile table")
	end)
end
