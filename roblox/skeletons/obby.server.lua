--!strict
--- OBBY — a course of stages, checkpoints, and things that kill you.
---
--- This is a starting point, not a framework. Read it, change it, delete the
--- half you do not want. Nothing in the engine depends on this file's shape.
---
--- What it sets up:
---   * a stage per platform, with a checkpoint at each
---   * respawn at the last checkpoint reached
---   * a kill plane so falling ends the attempt instead of lasting forever
---   * a timer per player, and a best time worth beating
---
--- The interesting decisions are marked. Everything else is plumbing you can
--- take on faith or rewrite.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = require(ReplicatedStorage.Core)
local Behaviours = require(ReplicatedStorage.Behaviours)

local Actions, Events, Timer = Core.Actions, Core.Events, Core.Timer
local Play, World = Behaviours.Play, Behaviours.World

-- ---------------------------------------------------------------- the course

--- Stage geometry. Replace this with your own layout, or build it from
--- `WorldKit.Blockout` and read the parts back — either works.
local COURSE = workspace:FindFirstChild("Course") or Instance.new("Folder")
COURSE.Name = "Course"
COURSE.Parent = workspace

local STAGE_COUNT = 8
local STAGE_GAP = 40

local function buildStage(index: number): BasePart
	local platform = Instance.new("Part")
	platform.Name = ("Stage%d"):format(index)
	platform.Size = Vector3.new(20, 2, 20)
	platform.Position = Vector3.new(0, index * 6, index * STAGE_GAP)
	platform.Anchored = true
	platform.Parent = COURSE

	local marker = Instance.new("Part")
	marker.Name = ("Checkpoint%d"):format(index)
	marker.Size = Vector3.new(6, 1, 6)
	marker.Position = platform.Position + Vector3.new(0, 1.5, 0)
	marker.Anchored = true
	marker.CanCollide = false
	marker.Color = Color3.fromRGB(120, 200, 140)
	marker.Material = Enum.Material.Neon
	marker.Parent = COURSE

	Play.checkpoint(marker, { order = index, message = ("Stage %d"):format(index) })
	return platform
end

local stages = {}
for index = 1, STAGE_COUNT do
	stages[index] = buildStage(index)
end

-- --------------------------------------------------------------- the hazards

--- Every other stage gets something that moves. **This is where an obby is
--- won or lost** — a course of static platforms is a walk, not a game.
for index = 2, STAGE_COUNT, 2 do
	local platform = stages[index]

	local slider = Instance.new("Part")
	slider.Name = ("Slider%d"):format(index)
	slider.Size = Vector3.new(6, 1, 6)
	slider.Position = platform.Position + Vector3.new(0, 3, STAGE_GAP * 0.5)
	slider.Anchored = true
	slider.Color = Color3.fromRGB(200, 160, 90)
	slider.Parent = COURSE

	World.platform(slider, {
		slider.Position - Vector3.new(12, 0, 0),
		slider.Position + Vector3.new(12, 0, 0),
	}, { speed = 6 + index * 0.4, pause = 0.4 })
end

for index = 3, STAGE_COUNT, 3 do
	local spike = Instance.new("Part")
	spike.Name = ("Hazard%d"):format(index)
	spike.Size = Vector3.new(18, 1, 4)
	spike.Position = stages[index].Position + Vector3.new(0, 2, 8)
	spike.Anchored = true
	spike.Color = Color3.fromRGB(190, 70, 60)
	spike.Material = Enum.Material.Neon
	spike.Parent = COURSE
	World.hazard(spike, { damage = 100, message = "Back to the checkpoint." })
end

-- Falling forever is the worst thing an obby can do to a player.
World.killPlane(-20)
Play.respawnAtCheckpoints()

-- ------------------------------------------------------------------ the clock

--- A run is only a run if it is timed. Personal best is per session here;
--- persist it with `GameKit.Save` when you want it to survive a rejoin.
Events.onPlayer(function(player)
	Actions.set(player, "CheckpointOrder", -1)
	Actions.set(player, "Best", 0)
	Actions.set(player, "Started", os.clock())
end)

Events.onCharacter(function(_, player)
	if (Actions.get(player, "CheckpointOrder", -1) :: number) < 0 then
		Actions.set(player, "Started", os.clock())
	end
end)

--- The finish. Reaching the last stage stops the clock and records a best.
local finish = stages[STAGE_COUNT]
Events.onTouch(finish, function(_, player)
	if player == nil then
		return
	end
	if (Actions.get(player, "CheckpointOrder", -1) :: number) < STAGE_COUNT - 1 then
		return
	end
	local elapsed = os.clock() - (Actions.get(player, "Started", os.clock()) :: number)
	local best = Actions.get(player, "Best", 0) :: number
	if best == 0 or elapsed < best then
		Actions.set(player, "Best", elapsed)
		Actions.notify(player, ("New best: %.1fs"):format(elapsed))
	else
		Actions.notify(player, ("Finished in %.1fs"):format(elapsed))
	end
	-- Straight back to the start, so the loop is a loop.
	Actions.set(player, "CheckpointOrder", -1)
	Actions.set(player, "Started", os.clock())
	Actions.teleport(player, stages[1].Position + Vector3.new(0, 5, 0))
end, { debounce = 2 })

print("[obby] course of", STAGE_COUNT, "stages is live")
