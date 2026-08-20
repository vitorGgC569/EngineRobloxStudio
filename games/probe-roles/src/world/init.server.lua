--!strict
-- World: the validated layout, built and dressed.
--
-- The spec was expanded by the world grammar and passed the planner, including
-- its reachability walk, before this file existed. Building it here is the
-- first moment any of it becomes geometry -- and geometry alone is a greybox,
-- so the lighting, planting and camera the token set describes are applied on
-- top of it rather than left for somebody to add later.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local WorldKit = require(ReplicatedStorage.WorldKit)
local WorldSpec = require(ReplicatedStorage.Shared.WorldSpec)
local TokenData = require(ReplicatedStorage.Shared.TokenData)
local AssetPlan = require(ReplicatedStorage.Shared.AssetPlan)

local tokens = WorldKit.Tokens.define(TokenData)
local MOOD = "farm-noon"
local CAMERA_PROFILE = "mobile-shoulder"

-- 1. Light before geometry. Three regions under default lighting read worse
-- than an empty scene under a considered sky, and this is one call.
local applied = WorldKit.Mood.apply(tokens, MOOD)

-- The spec arrives as plain data; Vector types are reconstructed here rather
-- than emitted, because a serialised Vector3 is a table that merely looks like
-- one and fails at the first arithmetic.
local spec = {
	id = WorldSpec.id,
	regions = {},
	circulation = WorldSpec.circulation,
	landmarks = {},
	sightlines = WorldSpec.sightlines,
}
for _, region in ipairs(WorldSpec.regions) do
	table.insert(spec.regions, {
		id = region.id,
		kind = region.kind,
		centre = Vector3.new(region.centre[1], region.centre[2], region.centre[3]),
		size = Vector2.new(region.size[1], region.size[2]),
		spawn = region.spawn,
		elevation = region.elevation,
	})
end
for _, landmark in ipairs(WorldSpec.landmarks) do
	table.insert(spec.landmarks, {
		id = landmark.id,
		at = Vector3.new(landmark.at[1], landmark.at[2], landmark.at[3]),
		height = landmark.height,
		visibleFrom = landmark.visibleFrom,
	})
end

local problems = WorldKit.Blockout.validate(spec, tokens)
if #problems > 0 then
	-- Validated again at runtime. The planner checked this spec, but the spec
	-- that reaches the place is the one that matters, and a mismatch means the
	-- emitter and the planner disagree about the same world.
	error("[World] the built spec does not validate: " .. table.concat(problems, "; "), 0)
end

-- 2. The layout itself.
local built = WorldKit.Blockout.build(spec, tokens, workspace)

-- 3. A silhouette on every landmark the grammar declared. Regions are ground;
-- without something standing on them the horizon has no subject.
local landmarkParts = {}
for _, landmark in ipairs(spec.landmarks) do
	local shaft = Instance.new("Part")
	shaft.Name = landmark.id
	shaft.Anchored = true
	shaft.Size = Vector3.new(10, landmark.height, 10)
	shaft.Position = landmark.at + Vector3.new(0, landmark.height / 2, 0)
	shaft.Color = tokens:color("structurePrimary")
	shaft.Material = Enum.Material.SmoothPlastic
	shaft.Parent = built.root

	local crown = Instance.new("Part")
	crown.Name = landmark.id .. "-crown"
	crown.Anchored = true
	crown.Size = Vector3.new(6, 4, 6)
	crown.Position = landmark.at + Vector3.new(0, landmark.height + 2, 0)
	crown.Color = tokens:color("accentGold")
	crown.Material = Enum.Material.Neon
	crown.Parent = built.root
	table.insert(landmarkParts, crown)
end

-- 4. One effect, on what the eye already lands on. Scattering particles across
-- a scene turns a frame to noise; `Vfx` refuses past its budget rather than
-- letting that happen quietly.
for _, crown in ipairs(landmarkParts) do
	WorldKit.Vfx.emitter(tokens, crown, {
		fromRole = "accentGold",
		toRole = "neutralLight",
		rate = 6,
		lifetime = NumberRange.new(1.6, 2.6),
		speed = NumberRange.new(2, 4),
		size = 1.4,
	})
end

-- 5. Planting last, keeping clear of every region a player stands in or walks
-- through. Uniform scatter puts a tree on the spawn, and that reads as a bug
-- rather than as nature.
local exclusions = {}
for _, region in ipairs(spec.regions) do
	table.insert(exclusions, { centre = region.centre, size = region.size })
end

local bounds = 0
for _, region in ipairs(spec.regions) do
	bounds = math.max(bounds, math.abs(region.centre.X) + region.size.X,
		math.abs(region.centre.Z) + region.size.Y)
end

local planted = WorldKit.Nature.scatter(built.root, WorldKit.Palette.BrickFarm, {
	centre = Vector3.new(0, 0, 0),
	size = Vector2.new(bounds * 2.2, bounds * 2.2),
	count = 64,
	seed = 212697,
	minSpacing = 16,
	exclusions = exclusions,
}, 0.65)

-- Published meshes, built from the ids Roblox approved. `CreateMeshPartAsync`
-- rather than setting MeshId: a plugin cannot write MeshId at all, and a
-- MeshPart with an empty MeshId is an invisible part that looks like nothing
-- went wrong.
local PublishedAssets = require(ReplicatedStorage.Shared.PublishedAssets)
local AssetService = game:GetService("AssetService")
for _, entry in ipairs(PublishedAssets) do
	if entry.kind == "MESH" and entry.assetId then
		local ok, meshPart = pcall(function()
			return AssetService:CreateMeshPartAsync("rbxassetid://" .. tostring(entry.assetId))
		end)
		if ok and meshPart then
			meshPart.Name = tostring(entry.logicalId)
			meshPart.Anchored = true
			meshPart.Size = Vector3.new(12, 11, 12)
			meshPart.CFrame = CFrame.new(0, 7, -bounds * 0.6)
			meshPart.Parent = built.root
		else
			warn("[probe-roles] published mesh " .. tostring(entry.assetId) .. " did not load: " .. tostring(meshPart))
		end
	end
end

-- 6. The camera the game is framed by. A default camera over a considered
-- scene throws away the framing the token set describes.
Players.PlayerAdded:Connect(function(player: Player)
	local ok, err = pcall(function()
		WorldKit.Camera.configurePlayer(player, tokens, CAMERA_PROFILE)
	end)
	if not ok then
		warn("[probe-roles] camera profile " .. CAMERA_PROFILE .. ": " .. tostring(err))
	end
end)

local pending = 0
for _, entry in ipairs(AssetPlan) do
	if entry.strategy == "CREATE" then
		pending += 1
	end
end

print(string.format(
	"[probe-roles] world: %d regions, %d routes, mood %s, %d lights, %d planted, %d/%d assets still to build",
	#spec.regions, built.routes, MOOD, applied.created or 0, #planted:GetChildren(),
	pending, #AssetPlan))

return built
