--!strict
--[[
	brownout — live scenarios.

	These run inside the running game and publish a report `forge gametest`
	reads. Everything else in this project reads source, and source cannot tell
	you whether a lamp lights.

	What is asserted here is **rules, not numbers**. "Charge buys light" is true
	next month; "58 charge buys 121 studs" is a balance value, and asserting it
	would turn every tuning pass into a red build. So each scenario below states
	a design promise the game would be broken without, and none of them care
	what the numbers currently are.

	Two of these test a world that another system built, which means they are
	also the only check in the project that the build order held: a scenario
	asserting "there are lamps" fails loudly if `Outpost` gave up waiting on
	`ground_ready`, and that failure is otherwise a silent empty field.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Server = ServerScriptService:WaitForChild("Server")
local Shift = require(Server:WaitForChild("core"):WaitForChild("Shift"))
local systems = Server:WaitForChild("systems")
local Outpost = require(systems:WaitForChild("Outpost"))
local Cells = require(systems:WaitForChild("Cells"))
local Exposure = require(systems:WaitForChild("Exposure"))
local Power = require(systems:WaitForChild("Power"))
local Store = require(systems:WaitForChild("Store"))
local Roster = require(systems:WaitForChild("Roster"))
local Save = Forge.Save

return function(Testing)
	-- ============================== the world ===============================

	Testing.scenario("the world the game is played in actually got built", function(t)
		for _, name in Config.containers do
			t:expect(Workspace:FindFirstChild(name) ~= nil,
				"the '" .. name .. "' container was never created")
		end

		--[[
			Terrain, checked by standing on it.

			The first version of this assertion read `Terrain.MaxExtents` and
			passed against a world with no floor in it at all — `MaxExtents` is
			the *allowed* volume of the Terrain object, ±32000 on an empty one,
			and it has nothing to say about whether anything was written.

			A raycast where the player spawns is the honest question, and it is
			the one that catches a `World.paint` that reported every chunk
			written and wrote air.
		]]
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { Workspace.Terrain }
		for _, radius in { 0, 90, 200, 360 } do
			local hit = Workspace:Raycast(
				Vector3.new(radius, 500, 0), Vector3.new(0, -900, 0), params)
			t:expect(hit ~= nil,
				string.format("no terrain floor %d studs from the generator", radius))
		end

		local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
		t:expect(spawn ~= nil, "the place has no SpawnLocation; players fall")
	end, { timeout = 90 })

	Testing.scenario("the outpost has a generator, lamps and fuel to fetch", function(t)
		t:expect(Outpost.pad ~= nil, "no generator pad; nothing can ever be delivered")
		t:expect(#Outpost.lamps > 0, "no lamps were built; the charge gauge has no world half")
		t:expect(#Cells.list > 0, "no fuel cells; the game has no verb")

		--: One cell of every grade. A ring that failed to place is a risk curve
		--: with a hole in it, and the symptom is players never leaving ring one.
		local grades = {}
		for _, cell in Cells.list do
			grades[cell.ring.grade] = (grades[cell.ring.grade] or 0) + 1
		end
		for _, ring in Config.cells.rings do
			t:expect((grades[ring.grade] or 0) > 0,
				string.format("ring %d placed no cells", ring.grade))
		end
	end, { timeout = 90 })

	-- ============================== the rules ===============================

	Testing.scenario("charge buys light, and losing it takes light away", function(t)
		local saved = Shift.charge

		Shift.charge = Config.generator.maxCharge
		local bright = Shift.radius()
		Shift.charge = Config.generator.maxCharge * 0.25
		local dim = Shift.radius()
		Shift.charge = 0
		local dark = Shift.radius()

		Shift.charge = saved

		t:expect(bright > dim, "a full generator does not light further than a quarter-full one")
		t:expect(dim > dark, "losing the last of the charge does not shrink the light")
		t:expect(dark >= 0, "an empty generator produced a negative radius")
	end)

	Testing.scenario("a lamp is lit exactly when the light reaches it", function(t)
		--: The single most load-bearing promise in the game: the rings *are*
		--: the gauge. If this drifts, the player is reading a world that is
		--: telling them something the simulation does not agree with.
		--:
		--: Guarded first, because every assertion below loops over the lamp
		--: list. Against an empty list "all of them lit" and "none of them lit"
		--: are both true, and this scenario went green against a world with no
		--: lamps in it at all before the guard was here.
		t:expect(#Outpost.lamps > 0, "no lamps to check; this scenario would pass vacuously")
		if #Outpost.lamps == 0 then
			return
		end

		local outer = 0
		for _, lamp in Outpost.lamps do
			outer = math.max(outer, lamp.distance)
		end

		Outpost.applyRadius(outer + 10)
		local allLit = true
		for _, lamp in Outpost.lamps do
			allLit = allLit and lamp.lit
		end

		Outpost.applyRadius(0)
		local anyLit = false
		for _, lamp in Outpost.lamps do
			anyLit = anyLit or lamp.lit
		end

		--: Restored, because this suite runs inside a session somebody may be
		--: playing. A test that leaves the lights off is a test that broke the
		--: game to prove the game works.
		Outpost.applyRadius(Shift.radius())

		t:expect(allLit, "a radius past every lamp left some of them dark")
		t:expect(not anyLit, "a radius of zero left lamps lit")
	end)

	Testing.scenario("the night gets harder as it goes on", function(t)
		local savedClock, savedPhase = Shift.clock, Shift.phase
		Shift.phase = "night"

		Shift.clock = Config.night.duration
		local early = Shift.drainRate()
		Shift.clock = Config.night.duration * 0.05
		local late = Shift.drainRate()

		Shift.clock, Shift.phase = savedClock, savedPhase

		t:expect(late > early, "the drain does not ramp; the end of the night is the same as the start")
		t:expect(early > 0, "the generator does not drain at all; there is no game")
	end)

	Testing.scenario("dawn stops the drain", function(t)
		local savedPhase = Shift.phase
		Shift.phase = "dawn"
		local resting = Shift.drainRate()
		Shift.phase = savedPhase
		t:expect(resting == 0, "the generator still drains at dawn, so the shift never ends")
	end)

	Testing.scenario("a further ring is worth more than a nearer one", function(t)
		--: The risk curve. If this inverts, the optimal play is to never leave
		--: the lit zone and the entire game collapses into a walk.
		local rings = Config.cells.rings
		for index = 2, #rings do
			local nearer, further = rings[index - 1], rings[index]
			t:expect(further.radius > nearer.radius,
				string.format("ring %d is not further out than ring %d", index, index - 1))
			t:expect(further.charge > nearer.charge,
				string.format("ring %d does not pay more charge than ring %d", index, index - 1))
			t:expect(further.watts > nearer.watts,
				string.format("ring %d does not pay more watts than ring %d", index, index - 1))
		end
	end)

	Testing.scenario("a heavier cell always costs more speed, at every upgrade level", function(t)
		--: Checked across the whole upgrade track rather than at the level the
		--: session's player happens to be. The promise is not "grade 3 is slower
		--: today", it is "no amount of hauler rig makes the big cell free", and
		--: only the second one survives somebody buying five levels.
		local hauler
		for _, spec in Config.upgrades do
			if spec.id == "hauler" then
				hauler = spec
			end
		end
		t:expect(hauler ~= nil, "the hauler upgrade is gone from the config")
		if not hauler then
			return
		end

		for level = 0, hauler.max do
			local light = Shift.rule.carryPenalty(level, 1)
			local heavy = Shift.rule.carryPenalty(level, 3)
			t:expect(heavy > light,
				string.format("at hauler L%d, grade 3 does not slow you more than grade 1", level))
			t:expect(light > 0,
				string.format("at hauler L%d, carrying is free and the ring choice stops mattering", level))
		end
	end)

	Testing.scenario("the lantern buys time and never buys immunity", function(t)
		--: The exposure rate is gain scaled by the base reach over the upgraded
		--: reach. Asserted over every level: it must always fall, and it must
		--: never reach zero, or a fully-upgraded player can stand on ring three
		--: for ever and the dark stops being the antagonist.
		local lantern
		for _, spec in Config.upgrades do
			if spec.id == "lantern" then
				lantern = spec
			end
		end
		t:expect(lantern ~= nil, "the lantern upgrade is gone from the config")
		if not lantern then
			return
		end

		local base = Config.exposure.lanternRadius
		local previousReach, previousRate = -1, math.huge
		for level = 0, lantern.max do
			local reach = Shift.rule.lanternRadius(level)
			local rate = Config.exposure.gainPerSecond * (base / math.max(base, reach))

			t:expect(reach > previousReach,
				string.format("lantern L%d does not reach further than L%d", level, level - 1))
			t:expect(rate > 0,
				string.format("lantern L%d makes the dark harmless", level))
			t:expect(rate <= previousRate,
				string.format("lantern L%d fills you faster than L%d", level, level - 1))
			previousReach, previousRate = reach, rate
		end

		--: And the wiring: the module the game actually calls agrees with the
		--: rule this scenario just checked.
		local player = game:GetService("Players"):GetPlayers()[1]
		if player then
			t:expect(Exposure.rateFor(player) > 0, "the live exposure rate is zero")
		end
	end)

	Testing.scenario("upgrades get more expensive and eventually run out", function(t)
		for _, spec in Config.upgrades do
			local previous = -1
			for level = 0, spec.max - 1 do
				local cost = Shift.upgradeCost(spec, level)
				t:expect(cost ~= nil, string.format("%s has no price at level %d", spec.id, level))
				t:expect((cost :: number) > previous,
					string.format("%s does not get more expensive at level %d", spec.id, level))
				previous = cost :: number
			end
			t:expect(Shift.upgradeCost(spec, spec.max) == nil,
				string.format("%s can be bought past its maximum", spec.id))
		end
	end)

	Testing.scenario("lifting a cell and carrying it to the generator raises the charge", function(t)
		--[[
			The whole game, end to end, in the running game.

			This is the scenario worth having. Every other one checks a rule in
			isolation; this one moves a real character to a real cell, calls the
			same function the `Grab` packet calls, walks it to the pad the
			generator built, and calls the same deposit the tick calls. If it
			passes, the loop the player came for works.

			It runs against the live session, so everything it disturbs — the
			charge, the cell, where the player is standing — is put back.
		]]
		local player = game:GetService("Players"):GetPlayers()[1]
		t:expect(player ~= nil, "no player in the session to carry anything")
		if not player then
			return
		end

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		t:expect(root ~= nil, "the player has no character to carry with")
		if not root then
			return
		end

		local cell
		for _, candidate in Cells.list do
			if candidate.available and not candidate.holder then
				cell = candidate
				break
			end
		end
		t:expect(cell ~= nil, "every cell in the field is already taken or respawning")
		if not cell then
			return
		end

		local savedPose = root.CFrame
		local savedCharge = Shift.charge
		local savedPhase = Shift.phase
		--[[
			Mid-range charge, and dawn rather than night.

			Mid-range so the deposit has room to raise it without fighting the
			clamp at 100. Dawn because `Power` ticks twelve times a second in the
			same world this scenario is manipulating, and during night that tick
			is also draining — so "did the charge go up" becomes a race between
			the deposit and the drain. At dawn the drain is zero and deposits
			still count, which makes the measurement clean.

			The tick still *deposits*, and that is the other half of the lesson:
			the first version of this scenario captured its baseline after
			walking onto the pad, by which time the tick had already taken the
			cell. It reported "the charge did not rise" about a game that had
			just raised it. The baseline is now taken out at the ring, while the
			cell is still in hand and 200 studs from the generator.
		]]
		Shift.charge = 40
		Shift.phase = "dawn"

		--: Beside the cell, well within the pickup range the server enforces.
		root.CFrame = CFrame.new(cell.core.Position + Vector3.new(0, 3, 4))
		task.wait(0.15)

		local lifted, reason = Cells.grabFor(player)
		t:expect(lifted, "could not lift a cell standing next to it: " .. tostring(reason))

		if lifted then
			t:expect(Cells.heldBy(player) == cell, "lifted a different cell than the nearest one")
			t:expect(Shift.crewOf(player).carrying ~= nil, "the crew state does not know it is carrying")

			--: The baseline, taken here: still holding the cell, still out at
			--: the ring, before anything can take it.
			local before = Shift.charge

			--: Onto the pad, and deposit through the same path the tick uses.
			local pad = Outpost.pad
			t:expect(pad ~= nil, "no generator pad to deliver to")
			if pad then
				root.CFrame = CFrame.new(pad.Position + Vector3.new(0, 4, 0))
				task.wait(0.3)

				--: A no-op if the tick got there first, which it usually does.
				--: Called anyway, because the scenario must not depend on losing
				--: that race to pass.
				Power.tryDeposit(player)

				t:expect(Shift.charge > before,
					"a cell delivered to the generator did not raise the charge")
				t:expect(Cells.heldBy(player) == nil,
					"the cell is still in the player's hands after delivery")
				t:expect(Shift.crewOf(player).carrying == nil,
					"the crew state still thinks it is carrying")
			end
		end

		--: Put the session back the way it was found.
		local stillHeld = Cells.heldBy(player)
		if stillHeld then
			Cells.detach(stillHeld, stillHeld.home)
		end
		root.CFrame = savedPose
		Shift.charge = savedCharge
		Shift.phase = savedPhase
	end, { timeout = 30 })

	Testing.scenario("buying an upgrade spends the watts and raises the level", function(t)
		--[[
			The other half of the economy, through the same path the packet takes.

			Worth its own scenario because this is the only place in the game a
			persistent balance goes *down*, and a balance that can be decremented
			without being checked is the bug that reaches production and nowhere
			else. Everything it touches is restored at the end.
		]]
		local player = game:GetService("Players"):GetPlayers()[1]
		t:expect(player ~= nil, "no player in the session to buy anything")
		if not player then
			return
		end
		local profile = Save.get(player)
		t:expect(profile ~= nil, "the player has no profile to spend from")
		if not profile then
			return
		end

		local savedWatts = profile.watts
		local savedUpgrades = {}
		for id, level in profile.upgrades or {} do
			savedUpgrades[id] = level
		end

		local spec = Config.upgrades[1]
		local cost = Shift.upgradeCost(spec, Shift.upgradeLevel(player, spec.id))
		t:expect(cost ~= nil, "the first upgrade has no price at its current level")

		if cost then
			--: Broke. The refusal path matters more than the success path: it is
			--: the one an exploit would try to walk past.
			profile.watts = cost - 1
			local poor, reason = Store.buyFor(player, spec.id)
			t:expect(not poor, "bought an upgrade without enough watts: " .. tostring(reason))
			t:expect(Shift.upgradeLevel(player, spec.id) == (savedUpgrades[spec.id] or 0),
				"a refused purchase still raised the level")

			--: And exactly enough.
			local before = Shift.upgradeLevel(player, spec.id)
			profile.watts = cost
			local rich, message = Store.buyFor(player, spec.id)
			t:expect(rich, "could not buy an upgrade with exactly its price: " .. tostring(message))
			t:expect(Shift.upgradeLevel(player, spec.id) == before + 1,
				"the purchase did not raise the level")
			t:expect((tonumber(profile.watts) or 0) == 0,
				"the purchase did not deduct the full price")
		end

		--: An id that names nothing must be refused rather than error.
		local bogus = Store.buyFor(player, "no_such_upgrade")
		t:expect(not bogus, "an unknown upgrade id was accepted")

		profile.watts = savedWatts
		profile.upgrades = savedUpgrades
		Roster.refresh(player)
	end, { timeout = 25 })

	Testing.scenario("the dark fills you and the light drains it back", function(t)
		--[[
			The antagonist, measured on a live character.

			`Exposure` ticks six times a second on its own; this scenario moves
			the player and waits for it rather than calling into it, so what is
			being checked is the system that actually runs.
		]]
		local player = game:GetService("Players"):GetPlayers()[1]
		t:expect(player ~= nil, "no player in the session to expose")
		if not player then
			return
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local humanoid = character and character:FindFirstChildOfClass("Humanoid") :: Humanoid?
		t:expect(root ~= nil and humanoid ~= nil, "the player has no character")
		if not root or not humanoid then
			return
		end

		local savedPose = root.CFrame
		local savedHealth = humanoid.Health
		local state = Shift.crewOf(player)
		local savedExposure = state.exposure

		--: Well outside the lit ring, on measured ground so the character is
		--: standing rather than falling — a falling player is a different test.
		local out = Shift.radius() + 90
		local ground = Forge.World.surface(out, 0)
		root.CFrame = CFrame.new((ground or Vector3.new(out, 30, 0)) + Vector3.new(0, 4, 0))
		state.exposure = 0
		task.wait(1.6)
		local inDark = state.exposure
		t:expect(inDark > 0, "standing past the lamps built no exposure at all")

		--: Back to the generator, which is always inside the light.
		root.CFrame = CFrame.new(Vector3.new(0, (savedPose.Position.Y), 0) + Vector3.new(0, 4, 0))
		task.wait(1.6)
		t:expect(state.exposure < inDark, "coming back into the light did not drain exposure")

		--: And the promise that makes the mechanic fair: recovery is faster
		--: than the fill, so one mistake is not a two-minute punishment.
		t:expect(Config.exposure.recoverPerSecond > Config.exposure.gainPerSecond,
			"exposure drains slower than it fills")

		root.CFrame = savedPose
		state.exposure = savedExposure
		humanoid.Health = savedHealth
	end, { timeout = 30 })

	Testing.scenario("the player list shows the profile", function(t)
		local player = game:GetService("Players"):GetPlayers()[1]
		t:expect(player ~= nil, "no player in the session")
		if not player then
			return
		end
		Roster.refresh(player)
		local stats = player:FindFirstChild("leaderstats")
		t:expect(stats ~= nil, "no leaderstats folder; the player list is empty")
		if not stats then
			return
		end
		local watts = stats:FindFirstChild("Watts")
		t:expect(watts ~= nil and watts:IsA("IntValue"), "no Watts entry in the player list")
		local profile = Save.get(player)
		if watts and profile then
			t:expect((watts :: IntValue).Value == math.floor(profile.watts or 0),
				"the player list disagrees with the profile")
		end
	end)

	Testing.scenario("every sound the game plays is registered", function(t)
		--[[
			An unregistered cue is silence, and silence reads exactly like the
			bug it was meant to fix. `Audio.play` on an unknown name warns once
			and returns nil, which nobody sees.
		]]
		local Audio = Forge.Audio
		for _, name in {
			"bed.night", "bed.wind",
			"machine.generator", "machine.lamp",
			"cue.lift", "cue.deposit", "cue.blackout", "cue.reserve", "cue.click", "cue.dawn",
		} do
			t:expect(Audio.defined(name), string.format("sound '%s' was never defined", name))
		end
	end)

	Testing.scenario("a dropped cell goes back into the world instead of vanishing", function(t)
		--: The disconnect path. Deleting a carried cell on leave would slowly
		--: starve a busy server of ring three, and the symptom — "the game gets
		--: unwinnable after an hour" — points nowhere near the cause.
		local cell = Cells.list[1]
		t:expect(cell ~= nil, "no cell to test with; the fuel field never built")
		if not cell then
			return
		end

		local wasAvailable = cell.available
		Cells.detach(cell, cell.home)
		t:expect(cell.available, "a detached cell was not made available again")
		t:expect(cell.model.Parent ~= nil, "a detached cell left the world")
		t:expect(cell.core.Anchored, "a detached cell was left unanchored and will fall")
		cell.available = wasAvailable
	end)
end
