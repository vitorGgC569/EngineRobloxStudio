--!strict
--[[
	Play — the only authority on score, strikes and gates.

	One loop runs the game: step the belt, spawn on interval, take crates into
	open gates, shut gates that have timed out, count what fell off the end, and
	turn a lost shift over into the next one.

	Why the pull is validated here and not in the client
	---------------------------------------------------

	`Pull` names a chute and nothing else. The server checks the player is
	actually standing at that lever, that the gate is off cooldown, and then
	decides — from the crate the *server* has on the belt — what it was worth.
	There is no packet in this game whose payload can add a point. The obvious
	exploit against any other design is to send `Pull` for whichever chute
	matches the crate you can see, from anywhere in the room; the range check is
	what makes running between levers the actual game.

	Why 30Hz
	--------

	The belt is the clock. At 34 studs a second and a 12-stud span, a 12Hz tick
	moves a crate 2.8 studs between samples, which is a quarter of the catch
	window — enough that an honest pull can miss. 30Hz costs nothing here and
	makes the window mean what it says.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local Net = Forge.Net
local Audio = Forge.Audio
local Boot = Forge.Core.Boot

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Shift = require(script.Parent.Parent:WaitForChild("core"):WaitForChild("Shift"))
local Mill = require(script.Parent:WaitForChild("Mill"))
local Line = require(script.Parent:WaitForChild("Line"))

local Play = {}

local TICK = 1 / 30
local SYNC_INTERVAL = 0.25
--: Seconds of horn-and-scoreboard between shifts.
local BREATHER = 9

local sinceSpawn = 0

-- ============================== helpers =====================================
--[[
	The best upgrade level anyone in the room has.

	This is a co-operative line, not four separate ones: the belt, the gates and
	the strikes are shared, so a per-player span would mean the same crate is
	inside the window for one operator and outside it for another. Taking the
	best in the room makes upgrades a thing the crew brings rather than a thing
	that splits the rules.
]]
local function crewLevel(id: string): number
	local best = 0
	for _, player in Players:GetPlayers() do
		best = math.max(best, Shift.upgradeLevel(player, id))
	end
	return best
end

Play.crewLevel = crewLevel

local function humanoidRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function chuteById(id: string): any
	for _, chute in Mill.chutes do
		if chute.spec.id == id then
			return chute
		end
	end
	return nil
end

Play.chuteById = chuteById

local function pushShift()
	Net.fireAll("Shift", Shift.snapshot(
		Line.preview(),
		Shift.speed(crewLevel("brake")),
		Shift.allowedStrikes(crewLevel("buffer"))))
end

Play.pushShift = pushShift

-- ============================== the pull ====================================
--[[
	Open one gate, if the player is standing at it.

	Exported because it is the whole verb of the game and the live suite has to
	be able to exercise it. `Net.on("Pull")` is a two-line wrapper, so a
	scenario runs the same path the packet does rather than a parallel one
	written to be testable.

	Returns `(opened, reason)`.
]]
function Play.pullFor(player: Player, chuteId: string): (boolean, string)
	if Shift.phase ~= "running" then
		return false, "The line is stopped."
	end
	local chute = chuteById(chuteId)
	if not chute then
		return false, "No such chute."
	end
	local root = humanoidRoot(player)
	if not root then
		return false, "No character."
	end

	--: Flat distance to the lever. A player on a crate is not further from the
	--: lever than one beside it, and the vertical term would say otherwise.
	local offset = (root.Position - chute.lever.Position) * Vector3.new(1, 0, 1)
	if offset.Magnitude > Config.gate.range then
		return false, "Too far from that lever."
	end

	local now = os.clock()
	if now < chute.readyAt then
		return false, "Lever resetting."
	end
	if now < chute.openUntil then
		return false, "Already open."
	end

	chute.openUntil = now + Shift.gateSeconds(crewLevel("hold"))
	chute.readyAt = chute.openUntil + Config.gate.cooldownSeconds
	Mill.paintGate(chute, true)
	Audio.playAt("cue.lever", chute.lever.Position)
	Net.fireAll("Gate", { chute = chuteId, open = true })
	return true, "Open."
end

-- ============================== resolution ==================================
local function strike(reason: string, kind: string?)
	Shift.strikes += 1
	Shift.streak = 0
	Audio.play("cue.strike")
	Net.fireAll("Sorted", { result = "strike", reason = reason, kind = kind })

	local allowed = Shift.allowedStrikes(crewLevel("buffer"))
	if Shift.strikes >= allowed then
		Play.endShift()
	end
end

local function award(player: Player?, kind: string, points: number, coins: number)
	Shift.score += points
	Shift.sorts += 1
	Shift.streak += 1

	--: Coins go to everyone on the line. It is one belt and one score; paying
	--: only the operator who happened to reach the lever would make a two-player
	--: shift a race to steal each other's pulls.
	for _, member in Players:GetPlayers() do
		local profile = Forge.Save.get(member)
		if profile then
			profile.coins = (profile.coins or 0) + coins
			profile.lifetime = (profile.lifetime or 0) + coins
		end
	end

	Net.fireAll("Sorted", {
		result = "sorted",
		kind = kind,
		points = points,
		multiplier = Shift.multiplier(),
	})
	Audio.play("cue.sort")
end

--[[
	Take crates into whichever gates are open, and shut the ones that timed out.

	Order matters: gates are resolved before the belt is stepped, so a crate
	that entered the span this tick is catchable this tick rather than one tick
	later. At thirty-four studs a second that difference is a stud, and a stud
	is the width of the complaint "I pulled it in time".
]]
--: Exported so the live suite can run one resolution synchronously instead of
--: waiting on the loop and guessing why nothing happened.
function Play.resolveGates()
	local now = os.clock()
	local span = Shift.span(crewLevel("reach"))

	for _, chute in Mill.chutes do
		if chute.openUntil <= 0 then
			continue
		end
		if now >= chute.openUntil then
			chute.openUntil = 0
			Mill.paintGate(chute, false)
			Net.fireAll("Gate", { chute = chute.spec.id, open = false })
			continue
		end

		local crate = Line.crateAt(chute.spec.x, span)
		if not crate then
			continue
		end

		local correct, points, coins = Shift.valueOf(crate.kind, chute.spec.id)
		Line.consume(crate, chute, correct)
		Shift.onResolved:Fire(crate.kind, chute.spec.id, correct)

		if correct then
			award(nil, crate.kind, points, coins)
		else
			strike("contaminated", crate.kind)
		end

		--: One crate per pull. A gate that stays open eating everything under
		--: it would turn a well-timed pull into a scoop, and the timing is the
		--: game.
		chute.openUntil = 0
		Mill.paintGate(chute, false)
		Net.fireAll("Gate", { chute = chute.spec.id, open = false })
	end
end

-- =============================== the shift ==================================
function Play.endShift()
	if Shift.phase ~= "running" then
		return
	end
	Shift.phase = "over"
	Shift.breather = BREATHER
	Shift.onPhase:Fire("over")

	local score = Shift.score
	local record = score > Shift.best
	Shift.best = math.max(Shift.best, score)

	Audio.play("cue.horn")
	for _, player in Players:GetPlayers() do
		local profile = Forge.Save.get(player)
		if profile then
			profile.shifts = (profile.shifts or 0) + 1
			if score > (profile.bestScore or 0) then
				profile.bestScore = score
			end
		end
		Net.fire(player, "Notify", {
			text = if record
				then string.format("Shift over — %d. A new best.", score)
				else string.format("Shift over — %d. Best is %d.", score, Shift.best),
			tone = if record then "good" else "warn",
		})
		Net.fire(player, "You", Shift.crewSnapshot(player))
	end

	Debug.info(string.format("shift over: score %d, %d sorts", score, Shift.sorts))
	Line.clear()
	pushShift()
end

function Play.beginShift()
	Shift.reset()
	Shift.breather = 0
	sinceSpawn = 0
	Line.clear()
	Line.fill(Config.line.previewCount + 4)
	for _, chute in Mill.chutes do
		chute.openUntil = 0
		chute.readyAt = 0
		Mill.paintGate(chute, false)
	end
	Shift.onPhase:Fire("running")
	Net.fireAll("Notify", { text = "Line running. Watch the queue.", tone = "warn" })
	pushShift()
end

-- ================================== loop ====================================
local function tick(dt: number)
	if Shift.phase ~= "running" then
		Shift.breather -= dt
		if Shift.breather <= 0 then
			Play.beginShift()
		end
		return
	end

	local brake = crewLevel("brake")
	local speed = Shift.speed(brake)

	Play.resolveGates()

	local fell = Line.step(dt, speed)
	for _, crate in fell do
		crate.model:Destroy()
		strike("overflow", crate.kind)
		--: A strike may have ended the shift; the rest of the crates on the
		--: belt were cleared with it and must not be counted twice.
		if Shift.phase ~= "running" then
			return
		end
	end

	sinceSpawn += dt
	if sinceSpawn >= Shift.interval(brake) then
		sinceSpawn = 0
		Line.spawn()
	end
end

function Play.start()
	Net.on("Pull", function(player, payload)
		local ok, reason = Play.pullFor(player, payload.chute)
		if not ok then
			Net.fire(player, "Notify", { text = reason, tone = "warn" })
		end
	end)

	task.spawn(function()
		if not Boot.await("line_ready", 180) then
			Debug.error("play never saw a line; the belt will not run")
			return
		end

		Debug.probe("shift", function()
			return Shift.snapshot(Line.preview(), Shift.speed(crewLevel("brake")),
				Shift.allowedStrikes(crewLevel("buffer")))
		end)

		--[[
			A beat before the first crate.

			The players' characters do not exist at the moment the world
			finishes building, and a shift that starts against an empty room
			spends its first strikes on nobody's mistake. Also the reason the
			engine's own trap list ends with "check that a player can act before
			the first thing that can hurt them".
		]]
		task.wait(3)
		Play.beginShift()

		local sinceSync = 0
		while true do
			local dt = task.wait(TICK)
			local ok, err = pcall(tick, dt)
			if not ok then
				--: A throwing tick must not stop the belt. A game that freezes
				--: its own simulation on one bad frame is worse than one that
				--: logs and carries on with a slightly wrong number.
				Debug.error(string.format("play tick: %s", tostring(err)))
			end

			sinceSync += dt
            if sinceSync >= SYNC_INTERVAL then
				sinceSync = 0
				pushShift()
			end
		end
	end)
end

return Play
