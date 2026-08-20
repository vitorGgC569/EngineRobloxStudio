--!strict
--- TOWER DEFENSE — a lane, waves along it, and placements that were wrong.
---
--- The genre's design is the moment a player realises their last placement was
--- a mistake. That needs three things working together: a lane long enough to
--- read, waves that change what a good answer is, and money that arrives just
--- slowly enough to hurt.
---
--- What it sets up:
---   * a lane of waypoints and creeps that walk it
---   * buildable pads, a turret per pad, and an upgrade
---   * waves that grow, with a bounty per kill and a leak that costs you
---   * a base with lives, and a loss when they run out

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = require(ReplicatedStorage.Core)
local Behaviours = require(ReplicatedStorage.Behaviours)

local Actions, Events, Timer, Curve = Core.Actions, Core.Events, Core.Timer, Core.Curve
local Spatial, Signal = Core.Spatial, Core.Signal
local Life = Behaviours.Life

-- -------------------------------------------------------------------- the design

--- **The three numbers that are the game.** Bounty against turret price sets
--- how fast the board fills; creep health growth sets when a good answer stops
--- being one.
local START_CASH = 250
local TURRET_PRICE = 120
local BOUNTY = 18
local LIVES = 20

local LANE = {
	Vector3.new(-140, 3, -60),
	Vector3.new(-40, 3, -60),
	Vector3.new(-40, 3, 40),
	Vector3.new(60, 3, 40),
	Vector3.new(60, 3, -30),
	Vector3.new(140, 3, -30),
}

-- ---------------------------------------------------------------------- the board

local FIELD = Instance.new("Folder")
FIELD.Name = "Field"
FIELD.Parent = workspace

local ground = Instance.new("Part")
ground.Size = Vector3.new(340, 4, 240)
ground.Position = Vector3.new(0, -2, 0)
ground.Anchored = true
ground.Color = Color3.fromRGB(96, 110, 88)
ground.Parent = FIELD

--- The lane, drawn. A tower defense where the path is invisible is a puzzle
--- about guessing, which is a different and worse game.
for index = 1, #LANE - 1 do
	local from, to = LANE[index], LANE[index + 1]
	local segment = Instance.new("Part")
	segment.Name = ("Lane%d"):format(index)
	segment.Anchored = true
	segment.Size = Vector3.new(10, 0.4, (to - from).Magnitude)
	segment.CFrame = CFrame.lookAt((from + to) * 0.5, to)
	segment.Color = Color3.fromRGB(150, 140, 110)
	segment.Material = Enum.Material.Sand
	segment.Parent = FIELD
end

local base = Instance.new("Part")
base.Name = "Base"
base.Size = Vector3.new(16, 16, 16)
base.Position = LANE[#LANE] + Vector3.new(0, 8, 0)
base.Anchored = true
base.Color = Color3.fromRGB(120, 160, 200)
base.Material = Enum.Material.Metal
base.Parent = FIELD

Actions.set(base, "Lives", LIVES)

-- ---------------------------------------------------------------------- the creeps

local creeps = Instance.new("Folder")
creeps.Name = "Creeps"
creeps.Parent = FIELD

local leaked = Signal.new("creep.leaked")
local killed = Signal.new("creep.killed")

local function makeCreep(wave: number): Instance?
	local body = Instance.new("Part")
	body.Name = "Creep"
	body.Size = Vector3.new(3, 5, 3)
	body.Position = LANE[1]
	body.Anchored = true
	body.Color = Color3.fromRGB(180, 80, 90)
	body.Parent = creeps

	local model = Instance.new("Model")
	model.Name = "Creep"
	body.Parent = model
	model.PrimaryPart = body
	model.Parent = creeps

	local health = Life.health(model, math.floor(Curve.geometric(40, 1.22, wave)))
	health.died:connect(function()
		killed:fire(wave)
	end)

	--- Walking the lane by hand rather than by pathfinding: the lane *is* the
	--- design, and letting a creep find its own way round would undo it.
	local leg, speed = 1, 10 + wave * 0.5
	Timer.each(function(delta)
		if model.Parent == nil then
			return true
		end
		local goal = LANE[leg + 1]
		if goal == nil then
			leaked:fire()
			model:Destroy()
			return true
		end
		local toward = goal - body.Position
		local step = speed * delta
		if toward.Magnitude <= step then
			leg += 1
		else
			body.Position += toward.Unit * step
		end
		return false
	end, "creep")

	return model
end

-- ---------------------------------------------------------------------- the towers

local pads = {}
for index = 1, 10 do
	local angle = (index / 10) * math.pi * 2
	local at = Vector3.new(math.cos(angle) * 95, 1, math.sin(angle) * 70)

	local pad = Instance.new("Part")
	pad.Name = ("Pad%d"):format(index)
	pad.Size = Vector3.new(10, 1, 10)
	pad.Position = at
	pad.Anchored = true
	pad.Color = Color3.fromRGB(130, 130, 140)
	pad.Parent = FIELD
	table.insert(pads, pad)

	local built = false
	Events.onPrompt(pad, function(player)
		if built then
			-- Upgrading is the second decision, and the one that makes the
			-- first one feel like a commitment.
			if not Actions.spend(player, "Cash", TURRET_PRICE) then
				Actions.notify(player, ("Upgrade costs %d"):format(TURRET_PRICE))
				return
			end
			local mount = pad:FindFirstChild("Mount") :: BasePart
			Actions.set(mount, "Level", (Actions.get(mount, "Level", 1) :: number) + 1)
			mount.Size += Vector3.new(0.6, 1.2, 0.6)
			Actions.notify(player, "Upgraded")
			return
		end
		if not Actions.spend(player, "Cash", TURRET_PRICE) then
			Actions.notify(player, ("A turret costs %d"):format(TURRET_PRICE))
			return
		end
		built = true

		local mount = Instance.new("Part")
		mount.Name = "Mount"
		mount.Size = Vector3.new(4, 7, 4)
		mount.Position = at + Vector3.new(0, 4, 0)
		mount.Anchored = true
		mount.Color = Color3.fromRGB(190, 180, 160)
		mount.Parent = pad
		Actions.set(mount, "Level", 1)

		Life.turret(mount, { range = 55, damage = 12, reload = 0.9 })
		Actions.notify(player, "Turret built")
	end, { label = "Pad", action = ("Build (%d)"):format(TURRET_PRICE) })
end

-- ---------------------------------------------------------------------- the waves

local spawner = Life.spawner(makeCreep, {
	first = 5, growth = 1.2, gap = 1.1, between = 12, cap = 60,
})

killed:connect(function()
	for _, player in ipairs(Players:GetPlayers()) do
		Actions.add(player, "Cash", BOUNTY)
	end
end)

leaked:connect(function()
	local left = Actions.add(base, "Lives", -1, { min = 0 })
	for _, player in ipairs(Players:GetPlayers()) do
		Actions.notify(player, ("A creep got through — %d lives left"):format(left))
	end
	if left <= 0 then
		spawner.clearAll()
		for _, player in ipairs(Players:GetPlayers()) do
			Actions.notify(player, "The base has fallen.")
		end
	end
end)

spawner.waveStarted:connect(function(wave, count)
	for _, player in ipairs(Players:GetPlayers()) do
		Actions.notify(player, ("Wave %d — %d incoming"):format(wave, count))
	end
end)

Events.onPlayer(function(player)
	Actions.set(player, "Cash", START_CASH)
	task.defer(function()
		Actions.teleport(player, Vector3.new(0, 8, 90))
	end)
end)

Timer.after(5, spawner.start)
print("[tower-defense] lane of", #LANE, "waypoints,", #pads, "pads")
