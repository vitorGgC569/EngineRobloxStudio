--!strict
--- SURVIVAL / HORROR — a night to get through, and something that wants you.
---
--- The genre's design is tension, and tension is a resource curve: light,
--- fuel, sanity, ammunition — something that runs down while you do the thing
--- the game wants. Take the resource away and it is a walking simulator.
---
--- What it sets up:
---   * a lantern that burns down and must be refuelled
---   * a night clock with waves of pursuers that get bolder
---   * safe zones where the resource recovers, and where the threat will not go
---   * an objective count that ends the night
---
--- The threat uses `GameKit.Pursuit` and `GameKit.Motion`, which handle
--- pathfinding and gait. Everything else is here to be changed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = require(ReplicatedStorage.Core)
local Behaviours = require(ReplicatedStorage.Behaviours)
local GameKit = require(ReplicatedStorage.GameKit)
local WorldKit = require(ReplicatedStorage.WorldKit)

local Actions, Events, Timer, Curve = Core.Actions, Core.Events, Core.Timer, Core.Curve
local Spatial, Zone = Core.Spatial, Core.Zone
local Play, Life, World = Behaviours.Play, Behaviours.Life, Behaviours.World

-- ------------------------------------------------------------------ the design

--- **The tension knobs.** Lantern drain against the time it takes to reach the
--- next fuel is the entire feel of the game: too slow and there is no pressure,
--- too fast and it is a chore.
local NIGHT_MINUTES = 8
local LANTERN_DRAIN = 1.6        -- per second
local LANTERN_MAX = 100
local FUEL_GIVES = 45
local EMBERS_TO_WIN = 6

local ARENA = Vector3.new(0, 0, 0)
local ARENA_SIZE = 300

-- --------------------------------------------------------------------- the world

local NIGHT = Instance.new("Folder")
NIGHT.Name = "Night"
NIGHT.Parent = workspace

local ground = Instance.new("Part")
ground.Name = "Ground"
ground.Size = Vector3.new(ARENA_SIZE, 4, ARENA_SIZE)
ground.Position = ARENA - Vector3.new(0, 2, 0)
ground.Anchored = true
ground.Color = Color3.fromRGB(58, 60, 66)
ground.Parent = NIGHT

--- Sanctuaries. The threat refuses to enter, and the lantern recovers.
local sanctuaries = {}
for index = 1, 3 do
	local angle = (index / 3) * math.pi * 2
	local at = ARENA + Vector3.new(math.cos(angle) * 90, 0, math.sin(angle) * 90)

	local shrine = Instance.new("Part")
	shrine.Name = ("Shrine%d"):format(index)
	shrine.Size = Vector3.new(14, 8, 14)
	shrine.Position = at + Vector3.new(0, 4, 0)
	shrine.Anchored = true
	shrine.Color = Color3.fromRGB(180, 160, 120)
	shrine.Material = Enum.Material.Marble
	shrine.Parent = NIGHT

	local light = Instance.new("PointLight")
	light.Range = 40
	light.Brightness = 2
	light.Color = Color3.fromRGB(255, 220, 160)
	light.Parent = shrine

	local zone = Zone.new(at + Vector3.new(0, 8, 0), Vector3.new(40, 20, 40), { ignore = { shrine } })
	zone.entered:connect(function(_, player)
		if player ~= nil then
			Actions.set(player, "Sheltered", true)
		end
	end)
	zone.left:connect(function(_, player)
		if player ~= nil then
			Actions.set(player, "Sheltered", false)
		end
	end)
	table.insert(sanctuaries, { part = shrine, at = at, zone = zone })
end

--- Embers to gather. The reason to leave the light.
local gathered = 0
for index = 1, EMBERS_TO_WIN + 2 do
	local angle = (index / (EMBERS_TO_WIN + 2)) * math.pi * 2
	local radius = 40 + (index % 3) * 45
	local at = ARENA + Vector3.new(math.cos(angle) * radius, 3, math.sin(angle) * radius)

	local ember = Instance.new("Part")
	ember.Name = ("Ember%d"):format(index)
	ember.Size = Vector3.new(2, 2, 2)
	ember.Position = at
	ember.Anchored = true
	ember.CanCollide = false
	ember.Color = Color3.fromRGB(255, 160, 70)
	ember.Material = Enum.Material.Neon
	ember.Parent = NIGHT

	local handle = Play.pickup(ember, { currency = "Embers", amount = 1, spin = true })
	handle.collected:connect(function(player)
		gathered += 1
		Actions.notify(player, ("Ember %d of %d"):format(gathered, EMBERS_TO_WIN))
		if gathered >= EMBERS_TO_WIN then
			Events.emit("night.survived")
		end
	end)
end

--- Fuel, deliberately scarcer than embers.
for index = 1, 4 do
	local angle = (index / 4) * math.pi * 2 + 0.4
	local at = ARENA + Vector3.new(math.cos(angle) * 70, 3, math.sin(angle) * 70)
	local can = Instance.new("Part")
	can.Name = ("Fuel%d"):format(index)
	can.Size = Vector3.new(2, 3, 2)
	can.Position = at
	can.Anchored = true
	can.Color = Color3.fromRGB(120, 170, 130)
	can.Parent = NIGHT

	Events.onTouch(can, function(_, player)
		if player == nil then
			return
		end
		Actions.add(player, "Lantern", FUEL_GIVES, { min = 0, max = LANTERN_MAX })
		Actions.notify(player, "Refuelled")
		can.Transparency = 1
		Timer.after(35, function()
			can.Transparency = 0
		end)
	end, { debounce = 1 })
end

-- -------------------------------------------------------------------- the lantern

Events.onPlayer(function(player)
	Actions.set(player, "Lantern", LANTERN_MAX)
	Actions.set(player, "Embers", 0)
	Actions.set(player, "Sheltered", false)
end)

Timer.every(1, function()
	for _, player in ipairs(Players:GetPlayers()) do
		local sheltered = Actions.get(player, "Sheltered", false)
		local delta = if sheltered then 6 else -LANTERN_DRAIN
		local left = Actions.add(player, "Lantern", delta, { min = 0, max = LANTERN_MAX })

		local character = player.Character
		if character ~= nil then
			-- The lantern is the light. When it runs out the dark is real, and
			-- that is the whole horror of the resource.
			local head = character:FindFirstChild("Head")
			if head ~= nil and head:IsA("BasePart") then
				local glow = head:FindFirstChild("Lantern") :: PointLight?
				if glow == nil then
					glow = Instance.new("PointLight")
					glow.Name = "Lantern"
					glow.Color = Color3.fromRGB(255, 200, 140)
					glow.Parent = head
				end
				glow.Range = Curve.remap(left, 0, LANTERN_MAX, 4, 34)
				glow.Brightness = Curve.remap(left, 0, LANTERN_MAX, 0.2, 1.6)
			end
			if left <= 0 then
				Actions.damage(character, 6)
			end
		end
	end
end, "lantern")

-- --------------------------------------------------------------------- the threat

local tokens = WorldKit.Tokens.define(require(ReplicatedStorage.Shared.TokenData))
local threats = Instance.new("Folder")
threats.Name = "Threats"
threats.Parent = NIGHT

local function makePilgrim(wave: number): Instance?
	local angle = math.random() * math.pi * 2
	local at = ARENA + Vector3.new(math.cos(angle) * 130, 4, math.sin(angle) * 130)

	local ok, model = pcall(function()
		return WorldKit.Threat.build(threats, tokens, {
			id = ("Pilgrim%d"):format(math.random(1, 99999)),
			displayName = "Pilgrim",
			cframe = CFrame.new(at),
			maxHealth = 60 + wave * 15,
			health = 60 + wave * 15,
			scale = 1.05,
			seed = math.random(1, 9999),
			bodyRole = "ink", mantleRole = "slate",
			faceRole = "neutralLight", accentRole = "accentDanger",
			showHealth = false,
		})
	end)
	if not ok or model == nil then
		return nil
	end

	--- Chases, and gives up when it loses you. `Life.guard` handles both, and
	--- animates while it moves so it does not slide.
	Life.guard(model, {
		sight = 70 + wave * 4,
		chaseSpeed = 9 + wave * 0.8,
		giveUp = 5,
		gait = "menace",
	})
	return model
end

local spawner = Life.spawner(makePilgrim, {
	first = 2, growth = 1.35, gap = 2.5, between = 20, cap = 18,
})

spawner.waveStarted:connect(function(wave, count)
	for _, player in ipairs(Players:GetPlayers()) do
		Actions.notify(player, ("Wave %d — %d approaching"):format(wave, count))
	end
end)

-- ---------------------------------------------------------------------- the night

World.dayNight(NIGHT_MINUTES * 2, {})
game:GetService("Lighting").ClockTime = 0

Events.on("night.survived", function()
	for _, player in ipairs(Players:GetPlayers()) do
		Actions.notify(player, "The embers are lit. You survived.")
	end
	spawner.clearAll()
end)

Timer.after(3, spawner.start)
print("[survival] night begins —", EMBERS_TO_WIN, "embers to gather")
