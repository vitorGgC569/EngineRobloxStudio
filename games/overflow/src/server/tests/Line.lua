--!strict
--[[
	overflow — live scenarios, run inside the running game.

	Rules, not numbers. "A further ramp is a faster belt" is true next month;
	"at 30 sorts the belt runs at 24" is a balance value and asserting it would
	turn every tuning pass into a red build.

	Two of these disturb the live shift — the belt is shared with whoever is
	playing — so each one records what it changed and puts it back. A test that
	leaves the line stopped is a test that broke the game to prove it works.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Server = ServerScriptService:WaitForChild("Server")
local Shift = require(Server:WaitForChild("core"):WaitForChild("Shift"))
local systems = Server:WaitForChild("systems")
local Mill = require(systems:WaitForChild("Mill"))
local Line = require(systems:WaitForChild("Line"))
local Play = require(systems:WaitForChild("Play"))
local Store = require(systems:WaitForChild("Store"))
local Save = Forge.Save

return function(Testing)
	-- ============================== the world ===============================

	Testing.scenario("the mill the game is played in actually got built", function(t)
		for _, name in Config.containers do
			t:expect(Workspace:FindFirstChild(name) ~= nil,
				"the '" .. name .. "' container was never created")
		end
		t:expect(Mill.belt ~= nil, "there is no belt; nothing can travel")
		t:expect(#Mill.chutes == 4, string.format("expected 4 chutes, found %d", #Mill.chutes))

		local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
		t:expect(spawn ~= nil, "the place has no SpawnLocation; players fall")

		--: A floor under the spawn, checked by raycast rather than by trusting
		--: that a part was created. The one instrument that answers the
		--: question actually being asked is the one that fires a ray.
		if spawn then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { spawn }
			local hit = Workspace:Raycast(spawn.Position + Vector3.new(0, 6, 0),
				Vector3.new(0, -40, 0), params)
			t:expect(hit ~= nil, "nothing solid under the spawn pad")
		end
	end, { timeout = 90 })

	Testing.scenario("every chute has a lever a player can reach and a mouth over the belt", function(t)
		t:expect(#Mill.chutes > 0, "no chutes to check; this scenario would pass vacuously")
		for _, chute in Mill.chutes do
			t:expect(chute.lever ~= nil, chute.spec.id .. " has no lever")
			t:expect(chute.mouth ~= nil, chute.spec.id .. " has no mouth")
			--: The lever must be on the player's side of the belt, or the only
			--: way to reach it is to stand on the line.
			t:expect(chute.lever.Position.Z < Config.belt.z,
				chute.spec.id .. "'s lever is on the far side of the belt")
			--: And close enough to its own mouth that the connection between
			--: standing here and that hole opening is visible.
			local reach = (chute.lever.Position - chute.mouth.Position).Magnitude
			t:expect(reach < 40,
				string.format("%s's lever is %d studs from its mouth", chute.spec.id, reach))
		end
	end)

	-- ============================== the rules ===============================

	Testing.scenario("the belt gets faster and the crates get closer together", function(t)
		local savedSorts = Shift.sorts

		Shift.sorts = 0
		local slow, wide = Shift.speed(0), Shift.interval(0)
		Shift.sorts = Config.line.rampSorts
		local fast, tight = Shift.speed(0), Shift.interval(0)

		Shift.sorts = savedSorts

		t:expect(fast > slow, "the belt does not speed up; there is no curve")
		t:expect(tight < wide, "crates do not arrive more often as the shift goes on")
		t:expect(slow > 0, "the belt does not move at all")
	end)

	Testing.scenario("the line brake makes a shift start easier and never stops it", function(t)
		local savedSorts = Shift.sorts
		Shift.sorts = 0
		local plain = Shift.speed(0)
		local braked = Shift.speed(4)
		Shift.sorts = savedSorts

		t:expect(braked < plain, "the brake upgrade does not slow the start")
		t:expect(braked > 0, "the brake stops the belt entirely, which is not a game")
	end)

	Testing.scenario("a crate is only worth something in its own chute", function(t)
		for _, kind in Line.kinds do
			local right, points, coins = Shift.valueOf(kind, kind)
			t:expect(right, kind .. " does not match its own chute")
			t:expect(points > 0, kind .. " scores nothing when sorted correctly")
			t:expect(coins > 0, kind .. " pays no coins when sorted correctly")

			for _, other in Line.kinds do
				if other ~= kind then
					local wrong, wrongPoints = Shift.valueOf(kind, other)
					t:expect(not wrong, kind .. " counted as correct in the " .. other .. " chute")
					t:expect(wrongPoints == 0, kind .. " scored in the wrong chute")
				end
			end
		end
	end)

	Testing.scenario("a streak pays more and a mistake takes it away", function(t)
		local savedStreak = Shift.streak
		Shift.streak = 0
		local plain = Shift.multiplier()
		Shift.streak = Config.shift.streakStep * 3
		local hot = Shift.multiplier()
		Shift.streak = savedStreak

		t:expect(hot > plain, "a streak does not raise the multiplier")
		t:expect(plain >= 1, "the multiplier starts below one, so sorting can score nothing")
		t:expect(hot <= Config.shift.maxMultiplier, "the multiplier passed its own ceiling")
	end)

	Testing.scenario("upgrades get dearer and eventually run out", function(t)
		for _, spec in Config.upgrades do
			local previous = -1
			for level = 0, spec.max - 1 do
				local cost = Shift.upgradeCost(spec, level)
				t:expect(cost ~= nil, string.format("%s has no price at level %d", spec.id, level))
				t:expect((cost :: number) > previous,
					string.format("%s does not get dearer at level %d", spec.id, level))
				previous = cost :: number
			end
			t:expect(Shift.upgradeCost(spec, spec.max) == nil,
				string.format("%s can be bought past its maximum", spec.id))
		end
	end)

	Testing.scenario("the preview never promises a crate the belt will not deliver", function(t)
		--[[
			The game's central fairness. The strip is a control surface, not
			decoration: if what arrives is not what was shown, planning is
			impossible and the player cannot tell that from bad luck.
		]]
		local before = Line.preview()
		t:expect(#before > 0, "the queue is empty, so the strip shows nothing")
		if #before == 0 then
			return
		end

		local crate = Line.spawn()
		t:expect(crate ~= nil, "the line could not spawn a crate")
		if crate then
			t:expect(crate.kind == before[1],
				string.format("the strip promised %s and the belt delivered %s",
					before[1], crate.kind))
			--: And the strip advances rather than repeating.
			local after = Line.preview()
			t:expect(after[1] == before[2],
				"the strip did not advance after a crate was taken from it")
			crate.model:Destroy()
			for index, held in Line.crates do
				if held == crate then
					table.remove(Line.crates, index)
					break
				end
			end
		end
	end, { timeout = 20 })

	-- ============================== the loop ================================

	Testing.scenario("a crate in an open gate is taken, scored, and gone", function(t)
		--[[
			The whole game, end to end, in the running game: put a real crate on
			the belt inside a real chute's span, open that chute the way the
			packet does, and read the score.

			Everything it disturbs is put back.
		]]
		local player = Players:GetPlayers()[1]
		t:expect(player ~= nil, "no player in the session to pull a lever")
		if not player then
			return
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		t:expect(root ~= nil, "the player has no character")
		if not root then
			return
		end

		local chute = Mill.chutes[2]
		t:expect(chute ~= nil, "no second chute to test with")
		if not chute then
			return
		end

		local savedPose = root.CFrame
		local savedScore, savedSorts = Shift.score, Shift.sorts
		local savedStrikes, savedStreak = Shift.strikes, Shift.streak
		local savedPhase = Shift.phase

		--[[
			Clear the belt before putting a crate on it.

			The suite runs inside the running game and the game does not stop for
			it. The first version of this scenario left the shift's own crates
			riding, and during the two seconds it waited for a score those crates
			reached the end, took the fourth strike, ended the shift — which
			calls `Line.clear()` — and destroyed the crate under test. It then
			reported "a correct sort scored nothing" about a game that sorts
			correctly.

			Clearing the line and zeroing the strikes is the smallest thing that
			makes this measurement about one crate instead of about the weather.
		]]
		Line.clear()
		Shift.strikes = 0
		Shift.phase = "running"
		savedScore = Shift.score
		local baseStrikes = Shift.strikes

		--: A crate of this chute's kind, parked in the middle of its span.
		local crate = Line.spawn()
		t:expect(crate ~= nil, "could not put a crate on the belt")
		if crate then
			crate.kind = chute.spec.id
			crate.x = chute.spec.x
			crate.model:PivotTo(CFrame.new(crate.x, Config.belt.y + 1.7, Config.belt.z))

			--: Standing at the lever, which is what the server checks.
			root.CFrame = CFrame.new(chute.lever.Position + Vector3.new(0, 4, 3))
			task.wait(0.2)

			--[[
				Prove the lookup before blaming the gate.

				A failure here and a failure after the pull mean completely
				different things — "the chute cannot see the crate" versus "the
				gate did not fire" — and without this line the scenario reports
				the second when it means the first.
			]]
			local span = Shift.span(Play.crewLevel("reach"))
			local seen = Line.crateAt(chute.spec.x, span)
			t:expect(seen == crate, string.format(
				"the chute cannot see the crate: crate at x=%.1f, chute at x=%.1f, span %.1f, found %s",
				crate.x, chute.spec.x, span, seen and seen.kind or "nothing"))
			t:expect(seen ~= nil and seen.kind == chute.spec.id, string.format(
				"the crate in the span is a %s and the chute takes %s",
				seen and seen.kind or "nothing", chute.spec.id))
			local correctNow = Shift.valueOf(seen and seen.kind or "", chute.spec.id)
			t:expect(correctNow, "valueOf says this pairing is wrong before the gate even opens")

			local pulled, reason = Play.pullFor(player, chute.spec.id)
			t:expect(pulled, "could not pull a lever while standing at it: " .. tostring(reason))

			--[[
				Resolved here, synchronously, rather than by waiting on the loop.

				Waiting made the measurement about timing: the crate keeps
				moving, the shift can end underneath it, and a failure could mean
				any of four things. One direct call means a failure here is about
				the resolution and nothing else.
			]]
			Play.resolveGates()

			t:expect(Shift.score > savedScore, "a correct sort in an open gate scored nothing")
			t:expect(Shift.sorts > savedSorts, "a correct sort was not counted")
			t:expect(Shift.strikes == baseStrikes, string.format(
				"a correct sort took %d strike(s)", Shift.strikes - baseStrikes))

			--: And the crate left the belt.
			local stillThere = false
			for _, held in Line.crates do
				if held == crate then
					stillThere = true
				end
			end
			t:expect(not stillThere, "the crate is still on the belt after being taken")
		end

		Line.clear()
		root.CFrame = savedPose
		Shift.score, Shift.sorts = savedScore, savedSorts
		Shift.strikes, Shift.streak = savedStrikes, savedStreak
		Shift.phase = savedPhase
		chute.openUntil, chute.readyAt = 0, 0
		Mill.paintGate(chute, false)
	end, { timeout = 30 })

	Testing.scenario("a lever cannot be pulled from across the room", function(t)
		--: The exploit this game would otherwise have: read the belt, send the
		--: matching chute, never move. The range check is the game.
		local player = Players:GetPlayers()[1]
		if not player then
			t:expect(false, "no player in the session")
			return
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			t:expect(false, "the player has no character")
			return
		end

		local chute = Mill.chutes[1]
		local far = Mill.chutes[#Mill.chutes]
		local savedPose = root.CFrame
		local savedPhase = Shift.phase
		Shift.phase = "running"

		root.CFrame = CFrame.new(chute.lever.Position + Vector3.new(0, 4, 3))
		task.wait(0.2)
		local ok, reason = Play.pullFor(player, far.spec.id)
		t:expect(not ok, "a lever at the far end of the room answered a pull")
		t:expect(string.find(tostring(reason), "far") ~= nil,
			"the refusal did not say the player was too far: " .. tostring(reason))

		root.CFrame = savedPose
		Shift.phase = savedPhase
		for _, c in Mill.chutes do
			c.openUntil, c.readyAt = 0, 0
			Mill.paintGate(c, false)
		end
	end, { timeout = 20 })

	Testing.scenario("buying an upgrade spends the coins and raises the level", function(t)
		local player = Players:GetPlayers()[1]
		t:expect(player ~= nil, "no player in the session to buy anything")
		if not player then
			return
		end
		local profile = Save.get(player)
		t:expect(profile ~= nil, "the player has no profile to spend from")
		if not profile then
			return
		end

		local savedCoins = profile.coins
		local savedUpgrades = {}
		for id, level in profile.upgrades or {} do
			savedUpgrades[id] = level
		end

		local spec = Config.upgrades[1]
		local cost = Shift.upgradeCost(spec, Shift.upgradeLevel(player, spec.id))
		t:expect(cost ~= nil, "the first upgrade has no price at its current level")
		if cost then
			--: The refusal path first: it is the one an exploit would walk past.
			profile.coins = cost - 1
			local poor = Store.buyFor(player, spec.id)
			t:expect(not poor, "bought an upgrade without enough coins")

			local before = Shift.upgradeLevel(player, spec.id)
			profile.coins = cost
			local rich, message = Store.buyFor(player, spec.id)
			t:expect(rich, "could not buy with exactly the price: " .. tostring(message))
			t:expect(Shift.upgradeLevel(player, spec.id) == before + 1,
				"the purchase did not raise the level")
			t:expect((tonumber(profile.coins) or 0) == 0, "the purchase did not deduct the price")
		end

		local bogus = Store.buyFor(player, "no_such_upgrade")
		t:expect(not bogus, "an unknown upgrade id was accepted")

		profile.coins = savedCoins
		profile.upgrades = savedUpgrades
		Store.refresh(player)
	end, { timeout = 25 })

	Testing.scenario("a player can reach a lever before the first crate reaches the end", function(t)
		--[[
			The unwinnable check, which the engine's own trap list ends on: a
			game can be unloseable-by-skill and still lose every time if the
			action that saves you takes longer than the first threat.

			A crate crosses the whole belt at the shift's opening speed. The
			player has to cover, at worst, the distance from spawn to the far
			lever. If the second number is not comfortably smaller than the
			first, the game is lost before it is played.
		]]
		local B = Config.belt
		local travel = (B.tailX - B.headX) / Config.line.startSpeed

		local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
		t:expect(spawn ~= nil, "no spawn to measure from")
		if not spawn then
			return
		end

		local worst = 0
		for _, chute in Mill.chutes do
			local flat = (chute.lever.Position - spawn.Position) * Vector3.new(1, 0, 1)
			worst = math.max(worst, flat.Magnitude)
		end
		local run = worst / Config.walk.speed

		t:expect(run < travel * 0.7, string.format(
			"the furthest lever is %.1fs away and the first crate lands in %.1fs",
			run, travel))
	end)

	Testing.scenario("every sound the game plays is registered and actually loads", function(t)
		--[[
			Registered is not audible.

			An unregistered cue is silence and so is a registered one whose asset
			will not fetch — and on this account, which is moderated, almost
			every asset will not fetch. The first half of this scenario is cheap
			and catches a typo; the second half is the one that would have caught
			a bank built from `rbxassetid://` ids, every one of which answers 403
			here while looking perfectly correct in the source.
		]]
		local SoundBank = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sound"))

		for _, name in { "cue.lever", "cue.sort", "cue.strike", "cue.horn" } do
			t:expect(Forge.Audio.defined(name), string.format("sound '%s' was never defined", name))
		end

		for name, spec in SoundBank.cues do
			local probe = Instance.new("Sound")
			local ok = pcall(function()
				probe.SoundId = spec.id
			end)
			probe.Parent = workspace
			local deadline = os.clock() + 5
			while ok and not probe.IsLoaded and os.clock() < deadline do
				task.wait(0.1)
			end
			local loaded = ok and probe.IsLoaded
			t:expect(loaded, string.format("'%s' (%s) never loaded; it will play as silence",
				name, spec.id))
			if loaded then
				t:expect(probe.TimeLength > 0,
					string.format("'%s' loaded with no length", name))
			end
			probe:Destroy()
		end
	end, { timeout = 40 })
end
