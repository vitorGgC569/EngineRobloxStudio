--!strict
--[[
	Arena — the ground this game is fought on.

	Every line here is a decision about *this* game. The engine supplied the
	heightfield, the painter and the scatter; what a bowl-shaped arena ringed
	by cliffs means is not something Forge knows or should.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local World = Forge.World
local Rng = Forge.Core.Rng
local Debug = Forge.Debug

local Arena = {}

Arena.field = nil
Arena.spawnPoint = Vector3.new(0, 40, 0)
Arena.radius = 190

local MATERIALS = {
	floor = Enum.Material.Ground,
	path = Enum.Material.Slate,
	wall = Enum.Material.Rock,
	high = Enum.Material.Basalt,
}

function Arena.start()
	local t0 = os.clock()

	-- A bowl: flat in the middle, walls rising at the rim. One `flat` feature
	-- and one inverted ring is the whole shape.
	local field = World.heightfield({
		size = 520,
		seed = Rng.masterSeed(),
		base = {
			{ frequency = 0.006, octaves = 4, weight = 0.7 },
			{ frequency = 0.03, octaves = 3, weight = 0.3 },
		},
		range = { 26, 44 },
		features = {
			-- Order matters: floor first, then the wall that rings it.
			-- `rim` and not `mound` — a mound peaks at the centre, which turns
			-- the arena into a hill. That mistake shipped once and was only
			-- visible in a screenshot.
			{ kind = "flat", center = Vector2.new(0, 0), radius = 130, height = 32, blend = 1.3 },
			{ kind = "rim", center = Vector2.new(0, 0), radius = 250, inner = 108, amount = 82, sharpness = 2.1 },
			-- low cover inside the ring, so the floor is not a featureless disc
			{ kind = "mound", center = Vector2.new(64, -44), radius = 30, amount = 9, sharpness = 2 },
			{ kind = "mound", center = Vector2.new(-72, 56), radius = 34, amount = 12, sharpness = 2 },
			{ kind = "basin", center = Vector2.new(-30, -70), radius = 26, amount = 5, sharpness = 2 },
		},
		floor = 10,
	})
	Arena.field = field

	World.paint(field, {
		clear = true,
		seaLevel = 14,
		chunk = 64,
		budgetMs = 10,
		-- Material by position, not by height. Keying the fighting ring off a
		-- height band looked right in the table and painted the entire floor
		-- one flat colour in the game, because the floor is a plateau at
		-- exactly that height. Distance from the centre is what actually
		-- describes "the ring you fight in".
		material = function(x, z, height, slope)
			if slope < 0.55 then
				return MATERIALS.wall
			end
			if height > 78 then
				return MATERIALS.high
			end
			if height > 46 then
				return MATERIALS.wall
			end

			local distance = math.sqrt(x * x + z * z)
			if distance < 34 then
				return MATERIALS.path -- the duelling circle, visibly different
			end
			if distance > 104 then
				return Enum.Material.Sand -- the run-up to the wall
			end
			return MATERIALS.floor
		end,
		onProgress = function(done, total)
			if done == total then
				Debug.info(string.format("arena terrain written (%d chunks)", total))
			end
		end,
	})

	local props = Workspace:FindFirstChild("Props") :: Folder

	-- Rocks: cover, and something for the eye to measure distance against.
	local placed = World.scatter(field, {
		id = "arena.rocks",
		step = 16,
		budget = 220,
		density = function(x, z, height, slope)
			-- inside the ring only. Rocks on the wall read as visual noise and
			-- cost part budget for scenery nobody walks past.
			if math.sqrt(x * x + z * z) > 116 then
				return 0
			end
			if height < 30 or height > 40 or slope < 0.8 then
				return 0
			end
			return 0.3
		end,
		place = function(position, stream)
			local model = Instance.new("Model")
			model.Name = "Rock"
			local chunks = stream:int(1, 3)
			for i = 1, chunks do
				local size = stream:number(2.5, 7.5) / i
				local part = Instance.new("Part")
				part.Size = Vector3.new(size * stream:number(0.8, 1.5), size, size * stream:number(0.8, 1.5))
				part.CFrame = CFrame.new(position + Vector3.new(stream:number(-3, 3), size * 0.28, stream:number(-3, 3)))
					* CFrame.Angles(stream:number(0, 1), stream:number(0, 6.28), stream:number(0, 1))
				part.Color = Color3.fromRGB(104, 100, 96):Lerp(Color3.new(0, 0, 0), stream:number(0, 0.25))
				part.Material = Enum.Material.Slate
				part.Anchored = true
				part.TopSurface = Enum.SurfaceType.Smooth
				part.BottomSurface = Enum.SurfaceType.Smooth
				part.Parent = model
			end
			model.Parent = props
		end,
	})

	-- Braziers mark the fighting ring: a readable boundary beats an invisible wall.
	for i = 1, 8 do
		local angle = (i / 8) * math.pi * 2
		local x, z = math.cos(angle) * 96, math.sin(angle) * 96
		local ground = World.surface(x, z) or Vector3.new(x, 32, z)

		local post = Instance.new("Part")
		post.Size = Vector3.new(1.2, 9, 1.2)
		post.CFrame = CFrame.new(ground + Vector3.new(0, 4.5, 0))
		post.Color = Color3.fromRGB(58, 52, 48)
		post.Material = Enum.Material.Metal
		post.Anchored = true
		post.Parent = props

		local flame = Instance.new("Part")
		flame.Size = Vector3.new(2.2, 2.2, 2.2)
		flame.Shape = Enum.PartType.Ball
		flame.CFrame = CFrame.new(ground + Vector3.new(0, 9.6, 0))
		flame.Color = Color3.fromRGB(255, 148, 62)
		flame.Material = Enum.Material.Neon
		flame.Anchored = true
		flame.CanCollide = false
		flame.Parent = props

		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 160, 80)
		light.Range = 42
		light.Brightness = 2.4
		light.Parent = flame
	end

	local spawn = World.surface(0, 0)
	Arena.spawnPoint = (spawn or Vector3.new(0, 34, 0)) + Vector3.new(0, 4, 0)

	Debug.probe("arena", function()
		return {
			radius = Arena.radius,
			props = #props:GetChildren(),
			spawnPoint = { Arena.spawnPoint.X, Arena.spawnPoint.Y, Arena.spawnPoint.Z },
			seed = Rng.masterSeed(),
		}
	end)

	Debug.info(string.format("arena ready in %.1fs (%d rocks)", os.clock() - t0, placed))
end

-- Somewhere standable, at least `minDistance` from the centre.
function Arena.pointInRing(minDistance: number, maxDistance: number): Vector3?
	local stream = Rng.stream("arena.spawns")
	for _ = 1, 16 do
		local angle = stream:number(0, math.pi * 2)
		local dist = stream:number(minDistance, maxDistance)
		local x, z = math.cos(angle) * dist, math.sin(angle) * dist
		local point = World.surface(x, z)
		if point and Arena.field and Arena.field:slope(x, z) > 0.75 then
			return point + Vector3.new(0, 3, 0)
		end
	end
	return nil
end

return Arena
