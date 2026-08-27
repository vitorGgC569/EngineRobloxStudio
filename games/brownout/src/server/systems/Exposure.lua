--!strict
--[[
	Exposure — what the dark does to you, and the lantern that holds it off.

	This is the antagonist of the game, and it is a number rather than a
	creature on purpose. A monster in the dark needs pathing, animation, a
	spawn budget and a difficulty curve of its own, and it would still be a
	worse threat than the one already present: the light is going out and you
	are a long way from it.

	The rule is three lines long. Outside the lit radius and outside your own
	lantern, exposure climbs. Full exposure takes health. Step back into light
	and it drains fast — much faster than it filled, because a mechanic that
	punishes you for two minutes after one mistake stops teaching anything.

	Speed lives here too, for a reason that is not organisational: carrying
	slows you, the lit radius is what you are running back to, and the module
	that knows how exposed you are is the one that should decide how fast you
	can leave.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local Net = Forge.Net

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Shift = require(script.Parent.Parent:WaitForChild("core"):WaitForChild("Shift"))

local Exposure = {}

local TICK = 1 / 6
--: The per-player push is slower than the world push: exposure is a bar that
--: moves smoothly and the client tweens between the values it is given.
local SYNC_INTERVAL = 0.5

--[[
	Is this position inside the outpost's light?

	Distance to the generator against the current lit radius, and nothing else.
	Deliberately not a raycast against actual light sources: Roblox has no such
	query, every approximation of one is a lie somewhere, and a rule the player
	can state in one sentence is worth more than a rule that is physically
	defensible and unguessable.
]]
local function insideRing(position: Vector3): boolean
	--: Flat distance. Standing on a rock does not put you further into the dark.
	return (position * Vector3.new(1, 0, 1)).Magnitude <= Shift.radius()
end

--[[
	How fast the dark fills you, out past the lamps.

	The lantern buys **time, not immunity**, and that distinction is the whole
	upgrade. An immunity bubble would delete the mechanic the moment it was
	bought: a player with a lantern could stand on ring three indefinitely and
	the game would have no dark left in it. A leash instead — bigger lantern,
	longer you last out there — keeps every run a decision about how far.

	At level zero the lantern reaches 15 studs and the multiplier is 1. Fully
	upgraded it reaches 39, the multiplier is 0.38, and the same trip costs a
	third of the exposure. That is a real upgrade and it is still a timer.
]]
local function exposureRate(player: Player): number
	local base = Config.exposure.lanternRadius
	local reach = math.max(base, Shift.lanternRadius(player))
	return Config.exposure.gainPerSecond * (base / reach)
end

--: Exported so the live suite can assert the rule — a bigger lantern always
--: buys time and never buys immunity — rather than assert the number, which is
--: a balance value and would turn every tuning pass into a red build.
Exposure.rateFor = exposureRate
Exposure.insideRing = insideRing

--[[
	How fast this player should be moving.

	Sprint is the default rather than a held key. A survival game that meters
	movement with a stamina bar spends the player's attention on the bar, and
	the thing they should be watching is the horizon.
]]
local function speedFor(player: Player): number
	local state = Shift.crewOf(player)
	local speed = Shift.sprintSpeed(player)
	if state.carrying then
		speed *= 1 - Shift.carryPenalty(player, state.carrying.grade)
	end
	return math.max(Config.walk.base * 0.55, speed)
end

Exposure.speedFor = speedFor

local function tickPlayer(player: Player, dt: number)
	local state = Shift.crewOf(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?

	if not humanoid or not root or humanoid.Health <= 0 then
		--: A dead player is not in the dark, they are dead. Bleeding exposure
		--: off while down means respawning does not immediately re-kill them.
		state.down = true
		state.exposure = math.max(0, state.exposure - Config.exposure.recoverPerSecond * dt)
		return
	end

	if state.down then
		--: Fresh spawn: clear, so the first second back is not a death.
		state.down = false
		state.exposure = 0
	end

	humanoid.WalkSpeed = speedFor(player)

	local E = Config.exposure
	if insideRing(root.Position) then
		state.exposure = math.max(0, state.exposure - E.recoverPerSecond * dt)
	else
		state.exposure = math.min(E.max, state.exposure + exposureRate(player) * dt)
		if state.exposure >= E.max then
			humanoid:TakeDamage(E.damagePerSecond * dt)
		end
	end
end

function Exposure.start()
	--[[
		Walk speed is set on the Humanoid, and a respawned Humanoid comes back
		at Roblox's default 16. Without this the first character of the session
		is fast and every one after it is not, which is the kind of bug that
		gets described as "it feels different after you die once".
	]]
	local function watch(player: Player)
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
			if humanoid then
				humanoid.WalkSpeed = speedFor(player)
			end
			Shift.crewOf(player).exposure = 0
		end)
	end
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerAdded:Connect(watch)

	Debug.probe("exposure", function()
		local out = {}
		for player, state in Shift.eachCrew() do
			out[player.Name] = math.floor(state.exposure)
		end
		return out
	end)

	task.spawn(function()
		local sinceSync = 0
		while true do
			local dt = task.wait(TICK)
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(tickPlayer, player, dt)
				if not ok then
					Debug.error(string.format("exposure tick for %s: %s", player.Name, tostring(err)))
				end
			end

			sinceSync += dt
			if sinceSync >= SYNC_INTERVAL then
				sinceSync = 0
				for _, player in Players:GetPlayers() do
					Net.fire(player, "You", Shift.crewSnapshot(player))
				end
			end
		end
	end)
end

return Exposure
