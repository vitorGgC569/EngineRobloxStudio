--!strict
--[[
	Ground — the quarry the plots are cut into.

	Why this is a system and not four lines in Plots
	-----------------------------------------------

	The first version of this game built six slabs at forty studs and nothing
	else, and it was correct in every way that a test can check: the plots
	existed, the grid worked, the economy ticked. Standing in it, it was six
	rectangles floating in an empty blue void with no floor between them and no
	way to walk from one to the next.

	That is the gap between "the systems run" and "there is a game here", and
	nothing in the validator catches it. A person has to look.

	So this lays the thing a player actually stands on: a terrain floor under
	everything, a rim of rock so the horizon is not sky all the way down, a
	spawn on solid ground, and a look applied to the lighting so the place has
	a time of day rather than Roblox's default flat noon.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local World = Forge.World
local Visual = Forge.Visual
local Mark = Forge.Mark
local Rng = Forge.Core.Rng
local Boot = Forge.Core.Boot

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Ground = {}

--: How far the quarry floor reaches past the last plot on each side.
local MARGIN = 120

function Ground.extent(): (number, number)
	local plots = Config.plots
	local span = (plots.count - 1) * plots.spacing + plots.size
	return span * 0.5 + MARGIN, plots.origin.X + (plots.count - 1) * plots.spacing * 0.5
end

-- ================================== the look ================================
--[[
	Mid-morning in a working quarry.

	Warm key low in the sky, cool fill, and enough haze that the far rim reads
	as distance rather than as a wall. The whole argument for `Visual` is that
	a game nobody lit looks like a game nobody made, and this is one call
	rather than eleven properties nobody remembers the names of.
]]
local function defineLook()
	Visual.defineLook("quarry_morning", {
		ambient = Color3.fromRGB(72, 74, 82),
		outdoorAmbient = Color3.fromRGB(148, 150, 158),
		brightness = 2.6,
		clockTime = 9.5,
		geographicLatitude = 24,
		fogEnd = 1400,
		fogColor = Color3.fromRGB(186, 188, 196),
		atmosphere = {
			density = 0.32,
			haze = 1.6,
			glare = 0.2,
			color = Color3.fromRGB(206, 200, 190),
			decay = Color3.fromRGB(112, 118, 132),
		},
		bloom = { intensity = 0.5, size = 20, threshold = 1.4 },
		colorCorrection = {
			contrast = 0.08,
			saturation = -0.04,
			tint = Color3.fromRGB(255, 250, 242),
		},
	})
end

-- ================================= the floor ================================
--[[
	Terrain, not a giant part.

	A 700-stud baseplate is one part the streaming system must always send and
	a surface with no texture at any distance. Terrain is chunked, streams by
	itself, and takes a material that reads as rock from across the map.
]]
local function layFloor()
	local half, centre = Ground.extent()
	local base = Config.plots.origin.Y

	--[[
		A shallow bowl rather than a plane.

		Two reasons, and the second is the one that matters. A plane reads as a
		floor somebody forgot to model; a rim reads as a quarry. And a rim
		stops a player walking off the edge into nothing, which is otherwise
		the first thing they do.
	]]
	local field = World.heightfield({
		size = math.ceil(half * 2),
		resolution = 8,
		octaves = { { frequency = 0.004, octaves = 3, weight = 1 } },
		range = { base - 6, base - 2 },
		features = {
			{ kind = "flat", center = Vector2.new(centre, 0),
			  radius = half - 60, height = base - 4, blend = 1.4 },
			{ kind = "rim", center = Vector2.new(centre, 0),
			  radius = half, inner = half - 70, amount = 46, sharpness = 1.9 },
		},
		floor = base - 40,
	})

	World.paint(field, {
		clear = true,
		chunk = 64,
		budgetMs = 10,
		material = function(_x, _z, height, slope)
			if slope < 0.6 then
				return Enum.Material.Rock
			end
			if height > Config.plots.origin.Y + 8 then
				return Enum.Material.Slate
			end
			return Enum.Material.Ground
		end,
		onProgress = function(done, total)
			if done == total then
				Debug.info(string.format("quarry floor written (%d chunks)", total))
			end
		end,
	})

	return field
end

-- ================================== spawn ===================================
--[[
	A real SpawnLocation, on measured ground.

	provingground learned this the hard way twice: a game that positions players
	by code has no spawn as far as Roblox, any validator, or any tool is
	concerned — and a spawn placed at a remembered height drops players through
	terrain that turned out to be higher there. The ground is measured at the
	exact point the spawn goes.
]]
local function placeSpawn(container: Instance)
	local _, centre = Ground.extent()
	local x, z = centre, -Config.plots.size * 1.6
	local ground = World.surface(x, z) or Vector3.new(x, Config.plots.origin.Y, z)

	local pad = Instance.new("SpawnLocation")
	pad.Name = "QuarrySpawn"
	pad.Size = Vector3.new(16, 1, 16)
	-- Sunk half a stud so it reads as part of the floor rather than a slab
	-- dropped on top of it.
	pad.CFrame = CFrame.new(ground + Vector3.new(0, 0.5, 0))
	pad.Anchored = true
	pad.CanCollide = true
	pad.Neutral = true
	-- No forcefield: this is a tycoon, and nothing here can hurt anybody.
	pad.Duration = 0
	pad.Color = Color3.fromRGB(196, 202, 214)
	pad.Material = Enum.Material.Concrete
	pad.TopSurface = Enum.SurfaceType.Smooth
	pad.Parent = container

	Mark.exclude(pad)
	Debug.info(string.format("spawn at %d, %d, %d", ground.X, ground.Y, ground.Z))
	return pad
end

-- ================================== scenery =================================
--[[
	Boulders, so the floor is not a featureless disc.

	Scattered off the plots and off the path between them: scenery a player
	walks into is scenery they resent. This is the smallest amount of dressing
	that stops the place reading as a prototype.
]]
local function scatterRocks(field: any, container: Instance)
	local half, centre = Ground.extent()
	local stream = Rng.stream("quarry.rocks")
	local placed = 0

	for _ = 1, 90 do
		local x = centre + stream:number(-half + 40, half - 40)
		local z = stream:number(-half + 40, half - 40)

		-- Keep clear of the plot row and the walkway in front of it.
		if math.abs(z) < Config.plots.size * 2.2 then
			continue
		end

		local ground = World.surface(x, z)
		if not ground then
			continue
		end

		local size = stream:number(3, 11)
		local rock = Instance.new("Part")
		rock.Name = "Boulder"
		rock.Size = Vector3.new(size, size * stream:number(0.6, 1.1), size * stream:number(0.7, 1.2))
		rock.CFrame = CFrame.new(ground + Vector3.new(0, rock.Size.Y * 0.35, 0))
			* CFrame.Angles(stream:number(-0.2, 0.2), stream:number(0, 6.28), stream:number(-0.2, 0.2))
		rock.Anchored = true
		rock.Color = Color3.fromRGB(
			stream:int(96, 126), stream:int(92, 118), stream:int(86, 108))
		rock.Material = Enum.Material.Rock
		-- No shadow on the small stuff: ninety scattered props each casting one
		-- is a measurable share of a frame for detail nobody looks at.
		rock.CastShadow = size > 7
		rock.Parent = container

		Mark.root(rock, "rock")
		placed += 1
	end

	return placed
end

-- =================================== start ==================================
function Ground.start()
	defineLook()
	Visual.apply("quarry_morning")

	local scenery = Instance.new("Folder")
	scenery.Name = "Scenery"
	scenery.Parent = Workspace

	local t0 = os.clock()
	local field = layFloor()
	Ground.field = field

	local pad = placeSpawn(scenery)
	local rocks = scatterRocks(field, scenery)

	--[[
		The floor is a region, and the spawn pad is where the eye starts.

		Marked so the Quality Engine has something to photograph and something
		to measure the composition of — without this it looks at the place and
		correctly reports there is nothing to see.
	]]
	Mark.region(pad, "quarry-floor")

	Debug.info(string.format("ground ready in %.1fs (%d boulders)", os.clock() - t0, rocks))
	Boot.signal("ground_ready")
end

function Ground.describe(): { [string]: any }
	local half, centre = Ground.extent()
	return {
		halfExtent = half,
		centre = centre,
		look = Visual.describe and Visual.describe() or nil,
	}
end

return Ground
