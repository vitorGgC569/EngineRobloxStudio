--!strict
-- Runs ONLY in Studio (guarded by caller). Watches a live local-server playtest and
-- prints PASS/FAIL assertions for the core loop so multi-client tests verify themselves.
-- It does not fake anything the real game wouldn't do: it kills characters via
-- Humanoid:TakeDamage the same way combat will, and observes how the services react.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared").GameConfig)

local SmokeTest = {}

local function report(ok: boolean, label: string)
	print(("[SMOKE] %s %s"):format(ok and "PASS" or "FAIL", label))
end

function SmokeTest.run(roundService: any, roleService: any)
	-- The assertions below assume a bot-free lobby (human PZ, survivor = players-1).
	-- With bots enabled the PZ can be a bot and counts include bots, so skip to avoid
	-- misleading FAILs. Bot rounds are validated by playtesting instead.
	if GameConfig.Bots.Enabled then
		print("[SMOKE] skipped (bots enabled — verify bot rounds by playing)")
		return
	end
	task.spawn(function()
		-- Wait for a round to actually start
		while roundService:getState() ~= "ACTIVE" do
			task.wait(0.5)
		end
		local playerCount = #Players:GetPlayers()
		report(playerCount >= 2, ("round started with %d players"):format(playerCount))

		task.wait(2)

		-- Exactly one Patient Zero, rest survivors
		local pz = roleService:getPatientZero()
		report(pz ~= nil, "patient zero assigned")
		local survivorsBefore = roleService:survivorCount()
		report(survivorsBefore == playerCount - 1, ("survivor count %d == players-1"):format(survivorsBefore))

		-- Kill one survivor the way combat will (server-side damage) -> must convert
		local victim: Player? = nil
		for _, player in Players:GetPlayers() do
			if roleService:getRole(player) == "SURVIVOR" then
				victim = player
				break
			end
		end
		if victim ~= nil and victim.Character then
			local humanoid = victim.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid:TakeDamage(humanoid.MaxHealth)
			end
			task.wait(1)
			report(roleService:getRole(victim) == "ZOMBIE", "killed survivor converted to ZOMBIE")
			report(roleService:survivorCount() == survivorsBefore - 1, "survivor count decreased")
			-- Zombie respawn with green appearance
			task.wait(5)
			local char = victim.Character
			local respawned = char ~= nil and char:FindFirstChild("HumanoidRootPart") ~= nil
			local aura = char and char:FindFirstChild("InfectionAura", true)
			report(respawned == true, "zombie respawned")
			report(aura ~= nil, "zombie has infection appearance")
		else
			report(false, "no survivor victim found for conversion test")
		end

		print("[SMOKE] core-loop checks done — now kill remaining survivors or wait out the timer")

		-- Watch for round end
		while roundService:getState() == "ACTIVE" do
			task.wait(0.5)
		end
		report(roundService:getState() == "ROUND_END", "round reached ROUND_END")
	end)
end

return SmokeTest
