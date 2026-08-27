--!strict
--[[
	Power — the generator's clock, and the only authority on charge.

	One loop runs the whole game: drain the charge, move the light to match,
	take deposits from anyone standing on the pad, and turn the night over into
	dawn and back. Nothing else in the project writes `Shift.charge`.

	Why the deposit is here and not in `Cells`
	-----------------------------------------

	Because the deposit is where the exploit would be. A client-triggered
	deposit is a client that can say "I deposited" while standing on ring three,
	and the shape of the fix is not validation, it is never asking. This loop
	looks at where the character actually is, checks that against the pad the
	server built, and reads the value off the cell the server handed out. There
	is no packet in this game whose payload can add charge.

	Why 12Hz and not once per frame
	-------------------------------

	The simulation is a number going down and a radius going out; sixty
	evaluations a second of that is fifty-five wasted. The state push is slower
	still — every 0.4s — because the client interpolates the gauge and a smooth
	bar out of five packets a second is indistinguishable from thirty.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local Net = Forge.Net
local Visual = Forge.Visual
local Boot = Forge.Core.Boot
local Audio = Forge.Audio

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Shift = require(script.Parent.Parent:WaitForChild("core"):WaitForChild("Shift"))
local Outpost = require(script.Parent:WaitForChild("Outpost"))
local Cells = require(script.Parent:WaitForChild("Cells"))

local Power = {}

local TICK = 1 / 12
local SYNC_INTERVAL = 0.4
--: A carried cell goes in when the carrier is this close to the pad's centre.
--: Generous: a player sprinting at 27 studs/second covers two studs per tick,
--: and a tight radius means a run that visibly reached the generator and did
--: not count.
local DEPOSIT_RADIUS = 15

--: Charge the emergency reserve restores after a blackout. Enough to relight
--: the inner two rings and no more — the point is that you are alive and in
--: trouble, not that the mistake was free.
local RESERVE_CHARGE = 25
local BLACKOUT_SECONDS = 7
local BLACKOUT_DAMAGE_PER_SECOND = 16

local blackingOut = false

-- =============================== deposits ===================================
local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

--: Exported so the live suite can run the loop end to end. The tick calls this
--: and so does the scenario, which is the point: a test that reimplements the
--: deposit proves that the reimplementation works.
function Power.tryDeposit(player: Player)
	local cell = Cells.heldBy(player)
	if not cell then
		return
	end
	local pad = Outpost.pad
	if not pad then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	--: Flattened to the horizontal plane. A vertical term would mean a player
	--: standing on top of the generator counted as further away than one beside
	--: it, which is exactly backwards.
	local offset = (root.Position - pad.Position) * Vector3.new(1, 0, 1)
	if offset.Magnitude > DEPOSIT_RADIUS then
		return
	end

	local ring = cell.ring
	local bonus = Shift.couplerBonus(player)
	local charge = ring.charge * bonus
	local watts = ring.watts

	Cells.consume(cell)
	Shift.addCharge(charge)
	Audio.playAt("cue.deposit", pad.Position)

	local profile = Forge.Save.get(player)
	if profile then
		profile.watts = (profile.watts or 0) + watts
		profile.lifetime = (profile.lifetime or 0) + watts
		profile.delivered = (profile.delivered or 0) + 1
	end

	Shift.onDeposit:Fire(player, ring, charge, watts)

	--: Everyone sees the surge, because a co-op game in which your teammate's
	--: good run is invisible to you is four people playing solo in one place.
	Net.fireAll("Surge", {
		grade = ring.grade,
		charge = charge,
		color = ring.color,
		who = player.DisplayName,
	})
	Net.fire(player, "Notify", {
		text = string.format("+%d charge  ·  +%d W", math.floor(charge + 0.5), watts),
		tone = "good",
	})
	Net.fire(player, "You", Shift.crewSnapshot(player))
end

-- ================================ blackout ==================================
--[[
	The generator hit zero.

	Not a game over. A round-based survival game that kicks everyone to a lobby
	on failure spends its best moment — the one where it all goes wrong — on a
	loading screen. So: seven seconds of real dark that hurts, then the reserve
	kicks in and the same night continues, harder, with the streak reset.
]]
local function blackout()
	if blackingOut then
		return
	end
	blackingOut = true

	Debug.warn(string.format("blackout at %ds into night %d", math.floor(Config.night.duration - Shift.clock), Shift.nightsSurvived))
	Shift.nightsSurvived = 0
	Shift.onBlackout:Fire()

	Outpost.applyRadius(0)
	Outpost.setBeacon(0)
	--: Non-positional: a blackout is not something that happens over there.
	Audio.play("cue.blackout")
	Net.fireAll("Notify", { text = "BLACKOUT — reserve starting", tone = "bad" })

	task.spawn(function()
		local elapsed = 0
		while elapsed < BLACKOUT_SECONDS do
			local dt = task.wait(0.5)
			elapsed += dt
			for _, player in Players:GetPlayers() do
				local humanoid = humanoidOf(player)
				if humanoid then
					humanoid:TakeDamage(BLACKOUT_DAMAGE_PER_SECOND * dt)
				end
			end
		end

		Shift.charge = RESERVE_CHARGE
		Outpost.setBeacon(1)
		Audio.play("cue.reserve")
		Net.fireAll("Notify", { text = "Reserve online. Move.", tone = "warn" })
		blackingOut = false
	end)
end

-- ================================= phases ===================================
local function payout()
	local amount = Config.payout.base + Config.payout.perNight * Shift.nightsSurvived
	for _, player in Players:GetPlayers() do
		local profile = Forge.Save.get(player)
		if profile then
			profile.watts = (profile.watts or 0) + amount
			profile.lifetime = (profile.lifetime or 0) + amount
			profile.nights = (profile.nights or 0) + 1
		end
		Net.fire(player, "Notify", { text = string.format("Shift survived  ·  +%d W", amount), tone = "good" })
		Net.fire(player, "You", Shift.crewSnapshot(player))
	end
	Debug.info(string.format("dawn: paid %d W to %d players", amount, #Players:GetPlayers()))
end

local function enterDawn()
	Shift.nightsSurvived += 1
	Shift.phase = "dawn"
	Shift.clock = Config.night.dawnDuration
	Shift.onPhase:Fire("dawn")

	--: Transitioned rather than applied. A hard cut from night to day is a
	--: single frame in which the whole screen changes, and it reads as a bug.
	Visual.transition("outpost_dawn", 6)
	Audio.play("cue.dawn")
	Net.fireAll("Notify", { text = "Dawn. The shift is over.", tone = "good" })
	payout()
end

local function enterNight()
	Shift.phase = "night"
	Shift.clock = Config.night.duration
	--: Topped up, not reset. Arriving at a new night on whatever you finished
	--: the last one with would mean a bad night poisons every night after it.
	Shift.charge = math.max(Shift.charge, Config.generator.startCharge)
	Shift.onPhase:Fire("night")

	Visual.transition("outpost_night", 5)
	Net.fireAll("Notify", { text = string.format("Night %d. Feed the generator.", Shift.nightsSurvived + 1), tone = "warn" })
end

-- ================================== loop ====================================
local function tick(dt: number)
	if Shift.phase == "night" then
		if not blackingOut then
			Shift.charge = math.max(0, Shift.charge - Shift.drainRate() * dt)
		end

		for _, player in Players:GetPlayers() do
			Power.tryDeposit(player)
		end

		if Shift.charge <= 0 and not blackingOut then
			blackout()
		end

		if not blackingOut then
			Outpost.applyRadius(Shift.radius())
			Outpost.setBeacon(Shift.charge / Config.generator.maxCharge)
		end

		Shift.clock -= dt
		if Shift.clock <= 0 and not blackingOut then
			enterDawn()
		end
	else
		--: Dawn: deposits still count, so a player who arrives at the pad two
		--: seconds after the horn is not punished for the run they already made.
		for _, player in Players:GetPlayers() do
			Power.tryDeposit(player)
		end
		Outpost.applyRadius(Config.light.maxRadius)

		Shift.clock -= dt
		if Shift.clock <= 0 then
			enterNight()
		end
	end
end

function Power.start()
	task.spawn(function()
		if not Boot.await("outpost_ready", 180) then
			Debug.error("power never saw an outpost; the generator will not run")
			return
		end

		Debug.probe("shift", function()
			return Shift.snapshot()
		end)

		local sinceSync = 0
		--: A hand-rolled accumulator rather than Heartbeat, because the tick
		--: rate is a design number and pinning it to the frame rate makes the
		--: drain faster on a good machine.
		while true do
			local dt = task.wait(TICK)
			local ok, err = pcall(tick, dt)
			if not ok then
				--: A throwing tick must not stop the clock. A game that freezes
				--: its own simulation on one bad frame is worse than one that
				--: logs and carries on with a slightly wrong number.
				Debug.error(string.format("power tick: %s", tostring(err)))
			end

			sinceSync += dt
			if sinceSync >= SYNC_INTERVAL then
				sinceSync = 0
				Net.fireAll("Shift", Shift.snapshot())
			end
		end
	end)
end

return Power
