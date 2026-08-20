--!strict
-- World: lighting, ground, a landmark, planting.
--
-- Built from the token set through WorldKit, not from numbers chosen here. A
-- generated world that picks its own colours looks consistent with itself and
-- wrong beside the rest of the game.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local WorldKit = require(ReplicatedStorage.WorldKit)
local TokenData = require(ReplicatedStorage.Shared.TokenData)
local AssetPlan = require(ReplicatedStorage.Shared.AssetPlan)

local tokens = WorldKit.Tokens.define(TokenData)
local MOOD = "farm-noon"
local CAMERA_PROFILE = "mobile-shoulder"

local root = Instance.new("Folder")
root.Name = "World"
root.Parent = workspace

-- 1. Light first. Three props under default lighting read worse than an empty
-- scene under a considered sky, and this costs one call and no parts.
local applied = WorldKit.Mood.apply(tokens, MOOD)

local extent = tokens:grammar("plotMinDimension") * 3
local pathWidth = tokens:grammar("corridorWidth") * 2

local function slab(name: string, size: Vector3, position: Vector3, role: string): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.Position = position
	part.Color = tokens:color(role)
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = root
	return part
end

-- 2. Ground, then the things that break it up. One unbroken colour is a
-- horizon; a path and a plaza make it somewhere to go.
slab("Ground", Vector3.new(extent * 2, 2, extent * 2), Vector3.new(0, -1, 0), "ground")
slab("Plaza", Vector3.new(extent * 0.55, 0.4, extent * 0.55), Vector3.new(0, 0.1, 0), "pavement")
slab("Path", Vector3.new(pathWidth, 0.42, extent * 1.6), Vector3.new(0, 0.12, extent * 0.5), "pathPrimary")

local spawn = Instance.new("SpawnLocation")
spawn.Name = "Spawn"
spawn.Anchored = true
spawn.Size = Vector3.new(12, 1, 12)
-- Above the plaza, not level with it: a spawn flush with the ground drops the
-- character half a stud into it and the first frame of a session is a jolt.
spawn.Position = Vector3.new(0, 0.55, 0)
spawn.Color = tokens:color("pavement")
spawn.Transparency = 1
spawn.CanCollide = false
spawn.Parent = root

-- 3. A silhouette. Without something standing on it, ground of any size is a
-- horizon and the frame has no subject.
local landmarkHeight = tokens:grammar("landmarkMinHeight")
local base = slab("LandmarkBase", Vector3.new(18, 3, 18), Vector3.new(0, 1.5, -extent * 0.45), "structurePrimary")
local shaft = slab("Landmark", Vector3.new(10, landmarkHeight, 10),
	Vector3.new(0, 3 + landmarkHeight / 2, -extent * 0.45), "structureSecondary")
local crown = slab("LandmarkCrown", Vector3.new(6, 4, 6),
	Vector3.new(0, 3 + landmarkHeight + 2, -extent * 0.45), "accentGold")
crown.Material = Enum.Material.Neon

-- 4. One effect, on the thing the eye already lands on. Scattering particles
-- across a scene is how a frame turns to noise; the budget in `Vfx` refuses
-- past a ceiling rather than letting it.
WorldKit.Vfx.emitter(tokens, crown, {
	fromRole = "accentGold",
	toRole = "neutralLight",
	rate = 6,
	lifetime = NumberRange.new(1.6, 2.6),
	speed = NumberRange.new(2, 4),
	size = 1.4,
})

-- 5. Planting last, keeping clear of the places a player stands and walks.
-- Uniform scatter puts a tree on the spawn, and that reads as a bug rather
-- than as nature.
local planted = WorldKit.Nature.scatter(root, WorldKit.Palette.BrickFarm, {
	centre = Vector3.new(0, 0, 0),
	size = Vector2.new(extent * 1.8, extent * 1.8),
	count = 48,
	seed = 183965,
	minSpacing = 14,
	exclusions = {
		{ centre = Vector3.new(0, 0, 0), size = Vector2.new(extent * 0.7, extent * 0.7) },
		{ centre = Vector3.new(0, 0, extent * 0.5), size = Vector2.new(pathWidth * 2, extent * 1.6) },
		{ centre = Vector3.new(0, 0, -extent * 0.45), size = Vector2.new(30, 30) },
	},
}, 0.65)

-- 6. The camera the game is framed by, per player. A default camera on a
-- considered scene throws away the framing the token set describes.
Players.PlayerAdded:Connect(function(player: Player)
	local ok, err = pcall(function()
		WorldKit.Camera.configurePlayer(player, tokens, CAMERA_PROFILE)
	end)
	if not ok then
		warn("[probe-z] camera profile " .. CAMERA_PROFILE .. ": " .. tostring(err))
	end
end)

-- What the asset director decided, stated by the running game. An asset that is
-- still a placeholder is invisible once everything is grey, and this is where
-- that stops being invisible.
local pending = 0
for _, entry in ipairs(AssetPlan) do
	if entry.strategy == "CREATE" then
		pending += 1
	end
end

print(string.format("[probe-z] world: mood %s, %d lights, %d planted, %.0f studs, %d/%d assets still to build",
	MOOD, applied.created or 0, #planted:GetChildren(), extent * 2, pending, #AssetPlan))

return root
