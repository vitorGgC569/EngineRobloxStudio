--!strict
--[[
	aurarift — live scenarios.

	These run inside the game, during bootstrap in Studio, and publish a report
	that `forge gametest` reads. That is the point: every other check in this
	project reads source, and source cannot tell you whether your game works.

	The two below are a starting shape, not a suite. Replace them with
	assertions about *your* rules — a scenario that says "the game booted" stops
	being useful the moment there is a game.

	What is worth asserting
	-----------------------

	Rules, not numbers. "A blocked hit does less damage than an unblocked one"
	is true next month; "a blocked hit does 7" is a balance value, and asserting
	it turns every tuning pass into a red build.

	Real things, not stubs. Spawn what the game spawns and damage it through the
	real pipeline. A scenario that hits a fake enemy with a fake sword proves
	only that the fakes agree with each other.

		Testing.scenario("a name that reads as a sentence", function(t)
			local thing = t:spawnEnemy({ name = "Dummy", health = 100 },
				Testing.config.stageOrigin)
			t:expectAlive(thing)
		end)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

return function(Testing)
	Testing.scenario("every container the config declares exists", function(t)
		--[[
			Cheap, and it catches a real class of mistake: a system writing into
			a folder the bootstrap never made puts its work in nil and fails
			silently.
		]]
		for _, name in Config.containers do
			t:expect(Workspace:FindFirstChild(name) ~= nil,
				"the '" .. name .. "' container was never created")
		end
	end)

	Testing.scenario("a rig builds and can be damaged", function(t)
		--[[
			The shortest end-to-end path through the engine: build a real rig,
			put real damage through the real pipeline, read the health back.
			If this fails, nothing else in your game is worth debugging yet.
		]]
		local subject = t:spawnEnemy({ name = "Smoke", health = 100 },
			Testing.config.stageOrigin)
		t:expectAlive(subject)

		Forge.Combat.damage(subject, { amount = 30, kind = "smoke" })
		t:expect(Forge.Combat.getHealth(subject) < 100, "damage did not land")

		Forge.Combat.damage(subject, { amount = 500, kind = "smoke" })
		t:expectDead(subject)
	end, { timeout = 20 })
end
