--!strict
--[[
	Gameplay scenarios for Proving Ground.

	These run inside the live game against real rigs, the real damage pipeline
	and the real weapon definitions. Nothing here is stubbed: an assertion that
	a husk dies is an assertion that `Rig.build`, the Humanoid, every installed
	damage modifier and the armour maths all still agree.

	Registered by `forge gametest`, which requires this module and hands it the
	engine's Testing surface.

	What is worth asserting, and what is not
	----------------------------------------

	These check *rules*, not numbers. "Armour reduces damage" is a rule and
	will be true next month; "a husk takes exactly 14" is a balance value and
	asserting it turns every tuning pass into a red build. The one place exact
	numbers appear is where the number *is* the rule — a bullseye paying double
	is the entire reason bullseyes exist.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Combat = Forge.Combat
local Weapon = Forge.Weapon
local Data = Forge.Data

return function(Testing)
	-- ============================== damage ==================================
	Testing.scenario("damage reduces health and stops at zero", function(t)
		local enemy = t:spawnEnemy({ name = "Dummy", health = 100 }, Testing.config.stageOrigin)
		t:expectAlive(enemy)

		Combat.damage(enemy, { amount = 40, kind = "test" })
		local health = Combat.getHealth(enemy)
		t:expectNear(health, 60, 1, "40 damage off 100 should leave 60")

		-- Overkill must not drive health negative: several systems test for
		-- `<= 0` and one that reads -240 behaves differently from one reading 0.
		Combat.damage(enemy, { amount = 500, kind = "test" })
		t:expectEqual(Combat.getHealth(enemy), 0, "health floors at zero")
		t:expectDead(enemy)
	end)

	Testing.scenario("armour reduces damage without ever reaching immunity", function(t)
		local bare = t:spawnEnemy({ name = "Bare", health = 500 }, Testing.config.stageOrigin)
		local armoured = t:spawnEnemy({ name = "Armoured", health = 500 }, Testing.config.stageOrigin + Vector3.new(6, 0, 0))
		armoured:SetAttribute("Armor", 100)

		Combat.damage(bare, { amount = 100, kind = "test" })
		Combat.damage(armoured, { amount = 100, kind = "test" })

		local bareLost = 500 - Combat.getHealth(bare)
		local armouredLost = 500 - Combat.getHealth(armoured)

		t:expect(armouredLost < bareLost, "armour should reduce damage")
		t:expect(armouredLost > 0, "armour must never grant immunity")
	end)

	Testing.scenario("invulnerability windows actually block damage", function(t)
		local enemy = t:spawnEnemy({ name = "Rolling", health = 200 }, Testing.config.stageOrigin)
		Combat.grantIFrames(enemy, 1)

		Combat.damage(enemy, { amount = 50, kind = "test" })
		t:expectEqual(Combat.getHealth(enemy), 200, "i-frames should have absorbed that")

		Combat.clearIFrames(enemy)
		Combat.damage(enemy, { amount = 50, kind = "test" })
		t:expect(Combat.getHealth(enemy) < 200, "damage should land once the window closes")
	end)

	Testing.scenario("the killed signal fires exactly once", function(t)
		local enemy = t:spawnEnemy({ name = "Once", health = 30 }, Testing.config.stageOrigin)
		local fired = 0
		local conn = Combat.killed:Connect(function(model)
			if model == enemy then
				fired += 1
			end
		end)

		Combat.damage(enemy, { amount = 100, kind = "test" })
		-- Hitting a corpse must not re-kill it: score and loot both hang off
		-- this signal, and a second fire is a duplicate payout.
		Combat.damage(enemy, { amount = 100, kind = "test" })
		t:wait(0.2)
		conn:Disconnect()

		t:expectEqual(fired, 1, "killed fired " .. fired .. " times")
	end)

	-- ============================== weapons =================================
	Testing.scenario("a weapon refuses to fire faster than its cadence", function(t)
		local shooter = t:spawnBot(Testing.config.stageOrigin)
		Weapon.equip(shooter, "handcannon")

		local origin = shooter:GetPivot().Position
		local first = Weapon.fire(shooter, origin, Vector3.new(0, 0, -1), { ignore = { shooter } })
		local second = Weapon.fire(shooter, origin, Vector3.new(0, 0, -1), { ignore = { shooter } })

		t:expect(first.ok, "the first shot should be allowed")
		t:expect(not second.ok, "an immediate second shot should be refused")
		t:expectEqual(second.reason, "cooldown", "refused for the wrong reason")
	end)

	Testing.scenario("a magazine empties and reloads", function(t)
		local shooter = t:spawnBot(Testing.config.stageOrigin)
		local state = Weapon.equip(shooter, "handcannon")
		local def = Weapon.definition("handcannon")
		local origin = shooter:GetPivot().Position

		local fired = 0
		for _ = 1, def.magazine + 2 do
			local shot = Weapon.fire(shooter, origin, Vector3.new(0, 0, -1), { ignore = { shooter } })
			if shot.ok then
				fired += 1
			end
			t:wait(60 / def.rpm + 0.02)
		end

		t:expectEqual(fired, def.magazine, "a magazine should hold exactly its stated rounds")
		t:expect(Weapon.isReloading(shooter), "running dry should start a reload")

		t:expect(t:waitUntil(function()
			return not Weapon.isReloading(shooter)
		end, def.reloadTime + 2), "the reload never finished")

		local ammo = Weapon.ammo(shooter)
		t:expectEqual(ammo, def.magazine, "reloading should refill the magazine")
	end)

	Testing.scenario("spread is reproducible from a seed", function(t)
		-- Prediction depends on this and nothing else checks it at runtime: if
		-- these two ever disagree, every client tracer lands somewhere the
		-- server's bullet did not.
		local a = Weapon.spreadDirection(Vector3.new(0, 0, -1), 5, 12345, 1)
		local b = Weapon.spreadDirection(Vector3.new(0, 0, -1), 5, 12345, 1)
		local c = Weapon.spreadDirection(Vector3.new(0, 0, -1), 5, 999, 1)

		t:expect((a - b).Magnitude < 1e-6, "the same seed must give the same direction")
		t:expect((a - c).Magnitude > 1e-6, "a different seed must give a different one")
	end)

	Testing.scenario("a charged weapon refuses an undrawn shot", function(t)
		local archer = t:spawnBot(Testing.config.stageOrigin)
		Weapon.equip(archer, "longbow")
		local origin = archer:GetPivot().Position

		local shot = Weapon.fire(archer, origin, Vector3.new(0, 0, -1), { ignore = { archer } })
		t:expect(not shot.ok, "a bow that was never drawn should not loose")
		t:expectEqual(shot.reason, "undercharged", "refused for the wrong reason")

		Weapon.beginCharge(archer)
		local def = Weapon.definition("longbow")
		t:wait(def.charge.time + 0.1)

		local drawn = Weapon.fire(archer, origin, Vector3.new(0, 0, -1), { ignore = { archer } })
		t:expect(drawn.ok, "a fully drawn bow should loose")
		t:expectNear(drawn.charge, 1, 0.05, "a full draw should read as full")
	end)

	-- ============================== content =================================
	Testing.scenario("every enemy in Content builds into a usable rig", function(t)
		for _, id in Data.ids("enemy") do
			local def = Data.expect("enemy", id)
			local model = t:spawnEnemy({
				name = def.name,
				scale = def.rig.scale,
				shape = def.rig.shape,
				bulky = def.rig.bulky,
				health = def.health,
			}, Testing.config.stageOrigin)

			local humanoid = model:FindFirstChildOfClass("Humanoid")
			t:expect(humanoid ~= nil, def.name .. " has no Humanoid")
			t:expect(model:FindFirstChild("HumanoidRootPart") ~= nil,
				def.name .. " has no HumanoidRootPart")
			t:expectAlive(model, def.name .. " spawned dead")
		end
	end)
end
