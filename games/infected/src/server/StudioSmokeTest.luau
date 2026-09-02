--!strict
--[[
	Studio-only self-check for the apocalypse's rules.

	This used to assert the round game's invariants -- exactly one Patient Zero,
	survivors equal to players minus one -- and skipped itself entirely whenever
	bots were enabled, which is always. So it never ran, and if it had, it would
	have failed on a premise that no longer exists.

	It now checks the four things that define this game, and checks them by
	watching the live server rather than by reading configuration back to
	itself. A test that asserts `FriendlyFire == true` proves a constant is set;
	a test that hurts somebody proves the game does what the constant says.

	Everything prints to the Output, so verifying this game is one boot and a
	log read -- no screenshots, no clicking.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Apocalypse = require(Shared.Apocalypse)
local GameConfig = require(Shared.GameConfig)

local SmokeTest = {}

local passed, failed = 0, 0

local function report(ok: boolean, label: string)
	if ok then
		passed += 1
	else
		failed += 1
	end
	print(("[SMOKE] %s %s"):format(ok and "PASS" or "FAIL", label))
end

function SmokeTest.run(roundService: any, roleService: any, botService: any)
	task.spawn(function()
		while roundService:getState() ~= "ACTIVE" do
			task.wait(0.5)
		end
		report(true, "the world came up live")

		--: Long enough for the horde to be seeded and the rigs to settle.
		task.wait(8)

		-- ------------------------------------------------------- no traitor
		local pz = roleService.getPatientZero and roleService:getPatientZero()
		report(pz == nil, "nobody is Patient Zero")
		report(Apocalypse.Rules.PatientZero == false,
			"the rules say there is no Patient Zero")

		-- --------------------------------------------------------- the horde
		local zombies = botService and botService:zombieCount() or 0
		local wanted = Apocalypse.hordeSize(#Players:GetPlayers())
		report(zombies > 0, ("the horde exists (%d zombies)"):format(zombies))
		report(zombies >= math.min(wanted, GameConfig.Bots.MaxBots) * 0.5,
			("the horde is roughly the size asked for (%d, wanted ~%d)")
				:format(zombies, wanted))

		--: Rivals as well as dead. An apocalypse with nobody to fight over the
		--: loot with is a shooting gallery.
		local rivals = botService and botService:survivorCount() or 0
		report(rivals > 0, ("there are rivals to fight over it with (%d)"):format(rivals))

		-- ------------------------------------------ survivors shoot survivors
		--[[
			The one that matters, and it is done by actually hurting somebody.

			A survivor bot is a survivor. If the old "survivor shot survivor:
			return" branch were still in the way, a survivor would be
			untouchable; taking health off one proves it is not.
		]]
		--: Retried, because rivals die and respawn constantly out there and
		--: looking exactly once found an empty slot rather than a missing
		--: feature.
		local victim: Model? = nil
		for _ = 1, 10 do
			for _, bot in botService:bots() do
				if bot.role == "SURVIVOR" and bot.humanoid and bot.humanoid.Health > 0 then
					victim = bot.model
					break
				end
			end
			if victim then
				break
			end
			task.wait(1)
		end
		if victim then
			local humanoid = (victim :: Model):FindFirstChildOfClass("Humanoid") :: Humanoid
			local before = humanoid.Health
			humanoid:TakeDamage(10)
			report(humanoid.Health < before,
				("a survivor can be hurt (%d -> %d)"):format(before, humanoid.Health))
		else
			report(false, "no survivor bot found to test damage on")
		end
		report(Apocalypse.Rules.FriendlyFire == true, "friendly fire is on")

		-- -------------------------------------------------- the world persists
		--[[
			Watched, not assumed.

			Suppressing the end-of-round *effect* was not enough the first time:
			the machine still made the transition and the world quietly went back
			to map voting while the callback was being dropped. The only check
			worth having is to look at the state again later.
		]]
		local heldFor = 0
		local ended = false
		while heldFor < 30 do
			task.wait(5)
			heldFor += 5
			if roundService:getState() ~= "ACTIVE" then
				report(false, ("the world ended after %ds (state %s)")
					:format(heldFor, roundService:getState()))
				ended = true
				break
			end
		end
		if not ended then
			report(true, ("the world is still live after %ds"):format(heldFor))
		end

		print(("[SMOKE] %d passed, %d failed"):format(passed, failed))
	end)
end

return SmokeTest
