--!strict
--[[
	Scale and leak scenarios.

	Everything else in this suite asks whether the game is *correct*. These ask
	whether it survives, which is a different question and the one Roblox games
	actually lose. Thirty-two green scenarios running with a handful of
	entities say nothing about two hundred, and nothing in this project has ever
	been measured under load.

	Two failure modes, both invisible until they are catastrophic:

	  Frame cost. A system that is free at fourteen actors and quadratic at two
	  hundred looks identical in every test that uses fourteen.

	  Leaks. Instances and connections that are created per spawn and not
	  released per despawn. This project has already shipped one — a `UI.bar`
	  that connected a signal and never disconnected it — and nothing would have
	  caught the next.

	--- On asserting timings ------------------------------------------------

	These assert *shapes*, not milliseconds. "Two hundred actors cost less than
	twenty times what ten cost" is a statement about complexity and survives a
	slower laptop; "two hundred actors cost 4ms" is a benchmark that fails on
	somebody else's machine and teaches everyone to ignore the suite.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Stats = game:GetService("Stats")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Rig = Forge.Rig
local Anim = Forge.Anim
local Combat = Forge.Combat
local Destruction = Forge.Destruction
local Entity = Forge.Entity
local Nav = Forge.Nav

--[[
	How long a body of work takes, measured over real frames.

	`os.clock` around a loop measures the loop; what matters is what the loop
	does to the frame afterwards, because most of this engine's cost is in
	connections that run later. So this samples heartbeat deltas.
]]
local function frameCost(seconds: number): number
	local worst = 0
	local deadline = os.clock() + seconds
	while os.clock() < deadline do
		local dt = RunService.Heartbeat:Wait()
		worst = math.max(worst, dt)
	end
	return math.floor(worst * 10000) / 10000
end

local function instanceCount(): number
	local ok, value = pcall(function()
		return Stats.InstanceCount
	end)
	return ok and value or 0
end

return function(Testing)
	-- ================================= scale ================================
	Testing.scenario("a hundred animated rigs do not collapse the frame", function(t)
		--[[
			The engine's central performance claim, tested.

			`Anim` exists to make two hundred characters cost one connection
			rather than two hundred coroutines. Nothing has ever checked that at
			a number bigger than a dozen, and a claim nobody measures is a hope.
		]]
		Anim.registerAll(require(ReplicatedStorage.Forge.Anim.Presets))

		local baseline = frameCost(0.6)
		local rigs = {}
		local animators = {}

		for index = 1, 100 do
			local model = Rig.build({ name = "LoadRig" .. index, scale = 0.9 })
			model:PivotTo(CFrame.new(
				Testing.config.stageOrigin + Vector3.new((index % 10) * 8, 0, math.floor(index / 10) * 8)))
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") then
					d.Anchored = true
				end
			end
			t:track(model)
			table.insert(rigs, model)

			local animator = Anim.new(model)
			Anim.bind(animator, "heartbeat")
			animator:play("attack_1")
			table.insert(animators, animator)
		end

		local loaded = frameCost(1.2)

		for _, animator in animators do
			animator:destroy()
		end

		t:expect(#rigs == 100, "only " .. #rigs .. " rigs were built")
		--[[
			Twenty times the baseline is a deliberately loose bar. It is not
			trying to catch a slow frame; it is trying to catch the difference
			between "costs more" and "does not return", which is what a
			per-entity connection or an accidental quadratic looks like.
		]]
		t:expect(loaded < math.max(baseline * 20, 0.25), string.format(
			"a hundred animated rigs took the worst frame from %.4fs to %.4fs",
			baseline, loaded))
	end, { timeout = 90 })

	Testing.scenario("the damage pipeline stays linear in the number of targets", function(t)
		local few = {}
		for index = 1, 10 do
			local model = Rig.build({ name = "Few" .. index })
			model:PivotTo(CFrame.new(Testing.config.stageOrigin + Vector3.new(index * 4, 0, 0)))
			t:track(model)
			table.insert(few, model)
		end

		local start = os.clock()
		for _ = 1, 20 do
			for _, model in few do
				Combat.damage(model, { amount = 1, kind = "load" })
			end
		end
		local tenCost = os.clock() - start

		local many = {}
		for index = 1, 100 do
			local model = Rig.build({ name = "Many" .. index })
			model:PivotTo(CFrame.new(Testing.config.stageOrigin + Vector3.new(index * 4, 0, 30)))
			t:track(model)
			table.insert(many, model)
		end

		start = os.clock()
		for _ = 1, 20 do
			for _, model in many do
				Combat.damage(model, { amount = 1, kind = "load" })
			end
		end
		local hundredCost = os.clock() - start

		--[[
			Ten times the work should cost roughly ten times, not a hundred.
			A modifier that walks every other target, or a signal with a
			listener per subject, turns this quadratic — and that is invisible
			until the day somebody spawns a hundred.
		]]
		local ratio = tenCost > 0 and hundredCost / tenCost or 0
		t:expect(ratio < 40, string.format(
			"damage looks superlinear: 10 targets %.4fs, 100 targets %.4fs (%.1fx)",
			tenCost, hundredCost, ratio))
	end, { timeout = 60 })

	Testing.scenario("debris past the budget costs no more than the budget", function(t)
		local baseline = frameCost(0.5)

		for index = 1, 60 do
			local crate = Instance.new("Part")
			crate.Size = Vector3.new(3, 3, 3)
			crate.Anchored = true
			crate.CFrame = CFrame.new(Testing.config.stageOrigin + Vector3.new(index * 3, 0, 60))
			crate.Parent = Workspace
			Destruction.break_(crate, { shards = 12 })
		end

		local loaded = frameCost(1)
		local live = Destruction.liveCount()
		Destruction.clear()

		t:expect(live <= Destruction.config.budget, string.format(
			"sixty crates left %d shards live against a budget of %d",
			live, Destruction.config.budget))
		t:expect(loaded < math.max(baseline * 20, 0.25), string.format(
			"debris took the worst frame from %.4fs to %.4fs", baseline, loaded))
	end, { timeout = 60 })

	-- ================================= leaks ================================
	Testing.scenario("spawning and despawning returns to baseline", function(t)
		--[[
			The leak test this project needed a month ago.

			Instances created per spawn and not released per despawn are the
			classic Roblox death: nothing errors, the session simply gets
			heavier until it stops. A cycle of build-and-destroy has to come
			back to where it started, within the noise of whatever else the
			game is doing.
		]]
		local before = instanceCount()
		t:wait(0.3)

		for _ = 1, 5 do
			local batch = {}
			for index = 1, 40 do
				local model = Rig.build({ name = "LeakRig" .. index })
				model:PivotTo(CFrame.new(Testing.config.stageOrigin + Vector3.new(index * 3, 0, 90)))
				model.Parent = Workspace
				table.insert(batch, model)
			end
			for _, model in batch do
				model:Destroy()
			end
			t:wait(0.15)
		end

		t:wait(0.6)
		local after = instanceCount()
		local grew = after - before

		--[[
			A tolerance rather than an equality. Roblox creates and reaps
			instances on its own schedule and the suite itself is building
			things, so demanding an exact return would produce a scenario that
			fails at random. Two hundred spare instances after two hundred
			spawn-destroy cycles is noise; two thousand is a leak.
		]]
		t:expect(grew < 400, string.format(
			"instance count grew by %d across 200 spawn/destroy cycles (%d -> %d)",
			grew, before, after))
	end, { timeout = 90 })

	Testing.scenario("animators release their connection when destroyed", function(t)
		--[[
			A connection is the leak nothing counts.

			`Anim.bind` opens one per animator. If `destroy` does not close it,
			every character that ever existed keeps updating forever — invisible
			in the instance count, fatal over a session. Measured by frame cost
			after the animators are gone.
		]]
		local baseline = frameCost(0.5)
		local animators = {}

		for index = 1, 60 do
			local model = Rig.build({ name = "ConnRig" .. index })
			model:PivotTo(CFrame.new(Testing.config.stageOrigin + Vector3.new(index * 3, 0, 120)))
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") then
					d.Anchored = true
				end
			end
			t:track(model)
			local animator = Anim.new(model)
			Anim.bind(animator, "heartbeat")
			table.insert(animators, animator)
		end

		t:wait(0.4)
		for _, animator in animators do
			animator:destroy()
		end
		t:wait(0.6)

		local afterRelease = frameCost(0.8)
		t:expect(afterRelease < math.max(baseline * 6, 0.2), string.format(
			"frame cost stayed at %.4fs after destroying 60 animators (baseline %.4fs); "
			.. "their heartbeat connections are probably still open",
			afterRelease, baseline))
	end, { timeout = 60 })

	Testing.scenario("navigation agents stop when told to", function(t)
		--[[
			`Nav` keeps one connection for every agent and disconnects it when
			the last one leaves. An agent that is stopped but still counted
			holds that connection open and repaths forever for something nobody
			is watching.
		]]
		--[[
			Measured as a delta, because this game's own enemies are agents too.

			The first version asserted absolute counts and failed with
			"expected 12, got 26" — fourteen husks were already navigating, and
			the scenario had assumed it owned the world. In a live game nothing
			does, and a scenario that counts globals is a scenario that breaks
			the moment the game around it does anything.
		]]
		local before = Nav.agentCount()
		local walkers = {}
		for index = 1, 12 do
			local model = Rig.build({ name = "NavRig" .. index })
			model:PivotTo(CFrame.new(Testing.config.stageOrigin + Vector3.new(index * 6, 0, 150)))
			t:track(model)
			table.insert(walkers, Nav.follow(model, {
				target = Testing.config.stageOrigin + Vector3.new(0, 0, 200),
			}))
		end

		t:expectEqual(Nav.agentCount() - before, 12, "not every agent registered")
		for _, agent in walkers do
			agent:stop()
		end
		t:wait(0.3)
		t:expectEqual(Nav.agentCount(), before,
			"stopped agents are still being stepped")
	end, { timeout = 40 })
end
