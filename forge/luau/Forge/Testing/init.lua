--!strict
--[[
	Testing — assertions about a game that is actually running.

	Every other check in this project reads source. The compiler reads syntax,
	the doctor reads structure, the unit tests read text. None of them can tell
	you whether an attack lands, whether an enemy dies, or whether a save
	survives a rejoin — and those are the only questions that matter.

	So this runs inside the live game. It drives real characters through real
	systems and asserts on real state. Nothing here is mocked: a test that hits
	a fake enemy with a fake sword proves that the fakes agree with each other.

		Testing.scenario("a third hit finishes a husk", function(t)
			local enemy = t:spawnEnemy("husk", Vector3.new(0, 5, 0))
			local hero = t:spawnBot(Vector3.new(0, 5, 6))

			t:face(hero, enemy)
			for _ = 1, 3 do
				t:attack(hero)
				t:wait(0.6)
			end

			t:expect(not Combat.isAlive(enemy), "the husk should be down")
		end)

		Testing.run()   -- returns a report a machine can read

	--- Why bots and not mocks ---------------------------------------------

	A bot here is a real `Rig` with a real `Humanoid`, spawned into the real
	world, moved by the real movement code and damaged by the real damage
	pipeline. When one of these tests fails it is because the game is broken,
	not because a stub drifted. That is the entire point: this suite is the
	thing that was missing when every genuine bug in this project had to be
	found by a person watching a screen.

	--- Determinism ---------------------------------------------------------

	Scenarios are given their own RNG stream and their own container, and the
	world is put back afterwards. Two runs of the same suite see the same
	numbers, so a failure is reproducible rather than a story about one
	afternoon.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Rig = require(script.Parent.Rig)
local Combat = require(script.Parent.Combat)
local Rng = require(script.Parent.Core).Rng

local Testing = {}

export type Case = {
	name: string,
	fn: (any) -> (),
	timeout: number?,
	tags: { string }?,
	--[[
		A precondition. Returns true when the scenario can meaningfully run.

		Without this a scenario that cannot run has two options and both lie: it
		fails, blaming the game for a fixture that was not ready, or it passes
		having asserted nothing. The second is how "every lamp is lit correctly"
		went green against a world containing zero lamps.

		A scenario whose `requires` returns false is reported **skipped**, which
		is neither pass nor fail and is counted separately.
	]]
	requires: (() -> (boolean, string?))?,
}

local cases: { Case } = {}
local currentContainer: Folder? = nil

Testing.config = {
	-- A scenario that has not finished by now is a hang, not a slow test.
	timeout = 20,
	-- Where spawned things go, so cleanup is one Destroy rather than a hunt.
	containerName = "ForgeTestStage",
	--[[
		Where scenarios spawn, by default.

		Far from any playfield rather than merely high above it. Height alone
		is not distance: anything unanchored falls back down into the game, and
		anything that raycasts finds the world below it. Scenarios may pass
		their own position; this is the safe default when they do not care.
	]]
	stageOrigin = Vector3.new(0, 5000, 20000),
}

-- ================================ registry ==================================
function Testing.scenario(name: string, fn: (any) -> (), options: any?)
	local opts = options or {}
	table.insert(cases, {
		name = name,
		fn = fn,
		timeout = opts.timeout,
		tags = opts.tags,
		requires = opts.requires,
	})
end

function Testing.clear()
	table.clear(cases)
end

function Testing.count(): number
	return #cases
end

function Testing.names(): { string }
	local out = {}
	for _, case in cases do
		table.insert(out, case.name)
	end
	return out
end

-- ================================= context ==================================
local Context = {}
Context.__index = Context

--[[
	The handle a scenario is given.

	Everything it spawns is tracked, so a scenario that fails half way through
	still cleans up after itself. A suite that leaks husks into the world
	poisons every test after it and produces failures that look like the code's
	fault.
]]
local function newContext(name: string, container: Folder): any
	return setmetatable({
		name = name,
		container = container,
		spawned = {},
		failures = {},
		checks = 0,
		rng = Rng.stream("test." .. name),
		startedAt = os.clock(),
	}, Context)
end

--[[
	Own an instance for the length of the scenario, and hold it still.

	Anchored, because a rig from `Rig.build` is unanchored and has a Humanoid:
	spawned at test altitude it falls, lands in the middle of whatever someone
	is playing, and is deleted a second later. That is exactly what it looks
	like from the player's seat — bodies dropping out of the sky and vanishing
	— and it is the test suite doing it.

	A scenario that genuinely needs physics unanchors what it spawned; that is
	one line and an explicit decision, which is the right way round.
]]
function Context:track(instance: Instance): Instance
	table.insert(self.spawned, instance)
	if instance:IsA("Model") then
		for _, d in instance:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
			end
		end
	end
	instance.Parent = self.container
	return instance
end

--[[
	A real enemy, built by the same code the game uses.

	Deliberately not a stub with a Health attribute: the value of this suite is
	that it exercises `Rig.build`, the Humanoid, the damage pipeline and every
	modifier the game installed. A stub would pass while the real thing was
	broken, which is the failure mode being designed out.
]]
function Context:spawnEnemy(spec: any, at: Vector3): Model
	local model = Rig.build(typeof(spec) == "table" and spec or {
		name = tostring(spec),
		scale = 1,
		shape = "biped",
	})
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.MaxHealth = (typeof(spec) == "table" and spec.health) or 100
		humanoid.Health = humanoid.MaxHealth
	end
	self:track(model)
	model:PivotTo(CFrame.new(at))
	return model
end

function Context:spawnBot(at: Vector3, spec: any?): Model
	local model = Rig.build(spec or { name = "TestBot", rigType = "R15" })
	self:track(model)
	model:PivotTo(CFrame.new(at))
	return model
end

-- Point one model at another. Combat is directional almost everywhere, so a
-- test that forgets this fails for the wrong reason.
function Context:face(subject: Model, target: Model | Vector3)
	local to = typeof(target) == "Vector3" and target or (target :: Model):GetPivot().Position
	local from = subject:GetPivot().Position
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if flat.Magnitude < 0.01 then
		return
	end
	subject:PivotTo(CFrame.lookAt(from, from + flat.Unit))
end

function Context:wait(seconds: number)
	local deadline = os.clock() + seconds
	repeat
		RunService.Heartbeat:Wait()
	until os.clock() >= deadline
end

--[[
	Wait for something to become true, or give up.

	The alternative — a fixed sleep long enough for the slowest machine — makes
	a suite that is both slow and flaky. This is fast when the game is fast and
	still correct when it is not.
]]
function Context:waitUntil(predicate: () -> boolean, seconds: number?): boolean
	local deadline = os.clock() + (seconds or 5)
	while os.clock() < deadline do
		if predicate() then
			return true
		end
		RunService.Heartbeat:Wait()
	end
	return false
end

-- ================================ assertions ================================
function Context:expect(condition: any, message: string)
	self.checks += 1
	if not condition then
		table.insert(self.failures, message)
	end
end

function Context:expectEqual(actual: any, expected: any, message: string?)
	self.checks += 1
	if actual ~= expected then
		table.insert(self.failures, string.format(
			"%s (expected %s, got %s)",
			message or "values differ", tostring(expected), tostring(actual)))
	end
end

function Context:expectNear(actual: number, expected: number, tolerance: number, message: string?)
	self.checks += 1
	if math.abs(actual - expected) > tolerance then
		table.insert(self.failures, string.format(
			"%s (expected %.3f +/- %.3f, got %.3f)",
			message or "value out of range", expected, tolerance, actual))
	end
end

--[[
	Prove there is something to assert about, then return it.

	The failure this exists to stop: a scenario reads "every lamp is lit
	correctly", iterates a list, finds nothing to iterate, and passes. It
	asserted nothing and reported success -- and it reports success loudest
	exactly when the world failed to build, which is when a green suite is most
	dangerous.

	`expectSome` makes the population itself an assertion. Put it before the
	loop and an empty world fails the test instead of flattering it.

		local lamps = ctx:expectSome(Lighting.all(), 1, "lamps")
		for _, lamp in lamps do ctx:expect(lamp.lit, "lamp is lit") end
]]
function Context:expectSome(items: { any }, minimum: number?, label: string?): { any }
	local floor = minimum or 1
	local count = #items
	self.checks += 1
	if count < floor then
		table.insert(self.failures, string.format(
			"expected at least %d %s, found %d -- nothing to assert about",
			floor, label or "items", count))
	end
	return items
end

--[[
	Sample a value now, so a later assertion can compare against it.

	The other half of the racing problem. A suite that runs beside a live game
	measures a moving target: one scenario here failed a correct game because a
	12Hz tick had already banked the resource between the action and the
	measurement. Capturing before acting turns "is it 5" into "did it go up by
	1", which is true regardless of what the tick did in between.
]]
function Context:baseline(read: () -> any): () -> any
	local before = read()
	return function()
		return before
	end
end

function Context:expectAlive(model: Model, message: string?)
	self:expect(Combat.isAlive(model), message or (model.Name .. " should be alive"))
end

function Context:expectDead(model: Model, message: string?)
	self:expect(not Combat.isAlive(model), message or (model.Name .. " should be down"))
end

function Context:cleanup()
	for _, instance in self.spawned do
		if instance.Parent then
			instance:Destroy()
		end
	end
	table.clear(self.spawned)
end

-- =================================== run ====================================
local function container(): Folder
	local existing = Workspace:FindFirstChild(Testing.config.containerName)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = Testing.config.containerName
	folder.Parent = Workspace
	return folder
end

--[[
	Run every registered scenario and report.

	Each case runs inside a coroutine with a deadline, because the most common
	way a live test fails is not an assertion but a hang: something waits for an
	event that a broken system never fires. A hang that takes the whole suite
	down teaches nothing; a hang reported as a timeout on one named scenario
	points straight at the break.
]]
function Testing.run(filter: string?): { [string]: any }
	local stage = container()
	currentContainer = stage

	local results = {}
	local passed, failed, timedOut, skipped = 0, 0, 0, 0
	local startedAt = os.clock()

	for _, case in cases do
		if filter and not case.name:lower():find(filter:lower(), 1, true) then
			continue
		end

		--[[
			Preconditions first, before a context exists.

			A scenario that cannot run must not be given the chance to assert
			nothing and call it a pass. Skipping is recorded with the reason, so
			a suite reading 12 passed / 4 skipped can never be mistaken for 16
			green -- which is the whole point of having the third state.
		]]
		if case.requires then
			local ok, met, why = pcall(case.requires)
			if not ok then
				met, why = false, "precondition errored: " .. tostring(met)
			end
			if not met then
				skipped += 1
				table.insert(results, {
					name = case.name,
					status = "skipped",
					checks = 0,
					failures = {},
					reason = why or "precondition not met",
					seconds = 0,
				})
				continue
			end
		end

		local ctx = newContext(case.name, stage)
		local finished = false
		local errored: string? = nil

		local thread = task.spawn(function()
			local ok, err = pcall(case.fn, ctx)
			if not ok then
				errored = tostring(err)
			end
			finished = true
		end)

		local deadline = os.clock() + (case.timeout or Testing.config.timeout)
		while not finished and os.clock() < deadline do
			RunService.Heartbeat:Wait()
		end

		local status
		if not finished then
			task.cancel(thread)
			status = "timeout"
			timedOut += 1
		elseif errored then
			status = "error"
			failed += 1
		elseif #ctx.failures > 0 then
			status = "failed"
			failed += 1
		else
			status = "passed"
			passed += 1
		end

		table.insert(results, {
			name = case.name,
			status = status,
			checks = ctx.checks,
			failures = ctx.failures,
			error = errored,
			seconds = math.floor((os.clock() - ctx.startedAt) * 1000) / 1000,
		})

		ctx:cleanup()
	end

	if stage.Parent then
		stage:Destroy()
	end
	currentContainer = nil

	return {
		total = passed + failed + timedOut + skipped,
		passed = passed,
		failed = failed,
		timedOut = timedOut,
		--: Its own number, never folded into `passed`. A suite that reports
		--: only a pass count cannot distinguish "all green" from "most did not
		--: run", and those are opposite pieces of news.
		skipped = skipped,
		seconds = math.floor((os.clock() - startedAt) * 1000) / 1000,
		results = results,
		ok = failed == 0 and timedOut == 0,
	}
end

--[[
	Publish the last report where a tool outside the game can read it.

	A StringValue under ReplicatedStorage, the same channel `Debug.expose` uses
	and for the same reason: it replicates, so it is readable from a play
	session that no edit-mode command can reach. The alternative — returning
	the report to a caller — only works if the caller is inside the same Lua
	VM, which a CLI never is.
]]
function Testing.publish(report: { [string]: any })
	local holder = ReplicatedStorage:FindFirstChild("ForgeTests")
	if not holder then
		holder = Instance.new("Folder")
		holder.Name = "ForgeTests"
		holder.Parent = ReplicatedStorage
	end
	local value = holder:FindFirstChild("Report")
	if not value then
		value = Instance.new("StringValue")
		value.Name = "Report"
		value.Parent = holder
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(report)
	end)
	;(value :: StringValue).Value = ok and encoded or "{}"
end

--[[
	Load a game's scenarios, run them, and publish the result.

	One call, so a game's bootstrap can opt in with a single line and a CLI has
	one thing to trigger.

	`game` is the project's own name, and it is here because nothing else in a
	running Studio session can supply it. `game.Name` is "Game" for every place
	opened from a local file, whatever the project is called, so a CLI that
	guards against attributing a suite to the wrong project cannot ask Studio --
	it has to be told, by the only party that knows.
]]
function Testing.runAndPublish(suite: Instance?, filter: string?,
                              game: string?): { [string]: any }
	Testing.clear()
	local loaded = 0
	if suite then
		for _, module in suite:GetChildren() do
			if module:IsA("ModuleScript") then
				local ok, err = pcall(function()
					require(module)(Testing)
				end)
				if not ok then
					local failure = {
						ok = false, game = game,
						error = string.format("scenario module '%s' failed to load: %s",
							module.Name, tostring(err)),
					}
					Testing.publish(failure)
					return failure
				end
				loaded += 1
			end
		end
	end
	local report = Testing.run(filter)
	report.modules = loaded
	report.game = game
	Testing.publish(report)
	return report
end

function Testing.describe(): { [string]: any }
	return {
		context = RunService:IsServer() and "server" or "client",
		registered = #cases,
		names = Testing.names(),
	}
end

return Testing
