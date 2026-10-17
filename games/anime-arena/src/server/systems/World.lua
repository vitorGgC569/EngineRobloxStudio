--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local World = Forge.World
local Rng = Forge.Core.Rng
local Debug = Forge.Debug

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Arena = {}

function Arena.build()
	-- Lighting: anime dusk mood
	Lighting.Technology = Enum.Technology.Future
	Lighting.ClockTime = 17.5
	Lighting.Brightness = 2.2
	Lighting.Ambient = Color3.fromRGB(60, 50, 90)
	Lighting.OutdoorAmbient = Color3.fromRGB(90, 80, 120)
	Lighting.FogColor = Color3.fromRGB(120, 100, 160)
	Lighting.FogStart = 200
	Lighting.FogEnd = 900
	Lighting.EnvironmentDiffuseScale = 0.5
	Lighting.EnvironmentSpecularScale = 0.4

	-- Atmosphere
	local atm = Instance.new("Atmosphere")
	atm.Density = 0.3
	atm.Offset = 0.1
	atm.Color = Color3.fromRGB(180, 150, 220)
	atm.Decay = Color3.fromRGB(80, 60, 120)
	atm.Glare = 0.2
	atm.Haze = 1.2
	atm.Parent = Lighting

	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = 0.6
	bloom.Size = 24
	bloom.Threshold = 0.9
	bloom.Parent = Lighting

	local cc = Instance.new("ColorCorrectionEffect")
	cc.Brightness = 0.05
	cc.Contrast = 0.1
	cc.Saturation = 0.15
	cc.TintColor = Color3.fromRGB(255, 235, 255)
	cc.Parent = Lighting

	local radius = Config.arenaRadius

	-- Heightfield terrain
	local field = World.heightfield({
		size = radius * 2 + 120,
		seed = Rng.masterSeed(),
		base = {
			{ frequency = 0.004, octaves = 3, weight = 0.5 },
			{ frequency = 0.02, octaves = 2, weight = 0.2 },
		},
		range = { 2, 18 },
		features = {
			{ kind = "flat", center = Vector2.new(0, 0), radius = 110, height = 6, blend = 1.4 },
			{ kind = "rim", center = Vector2.new(0, 0), radius = radius + 20, inner = 118, amount = 46, sharpness = 2.0 },
			{ kind = "mound", center = Vector2.new(55, -40), radius = 22, amount = 8, sharpness = 2 },
			{ kind = "mound", center = Vector2.new(-60, 50), radius = 24, amount = 9, sharpness = 2 },
			{ kind = "basin", center = Vector2.new(-20, -60), radius = 18, amount = 4, sharpness = 2 },
		},
		floor = 0,
	})
	Arena.field = field

	World.paint(field, {
		clear = true,
		seaLevel = 0,
		chunk = 64,
		budgetMs = 10,
		material = function(x, z, height, slope)
			if slope and slope > 0.55 then
				return Enum.Material.Rock
			end
			if height < 3 then
				return Enum.Material.Grass
			end
			return Enum.Material.Ground
		end,
	})

	-- Scatter cover rocks
	local propsFolder = Workspace:FindFirstChild("Props")
	if not propsFolder then
		propsFolder = Instance.new("Folder")
		propsFolder.Name = "Props"
		propsFolder.Parent = Workspace
	end
	local placed = World.scatter(field, {
		id = "anime-arena.rocks",
		step = 14,
		budget = 24,
		budgetMs = 4,
		min = Vector2.new(-radius, -radius),
		max = Vector2.new(radius, radius),
		density = function(px, pz, h, slope)
			if slope > 0.4 then return 0 end
			if (px * px + pz * pz) < 25 * 25 then return 0 end
			return 0.18
		end,
		place = function(point, stream)
			local rock = Instance.new("Part")
			rock.Name = "CoverRock"
			local sx = 4 + stream:number(0, 4)
			local sy = 3 + stream:number(0, 4)
			local sz = 4 + stream:number(0, 4)
			rock.Size = Vector3.new(sx, sy, sz)
			rock.Position = point + Vector3.new(0, sy / 2, 0)
			rock.Anchored = true
			rock.Material = Enum.Material.Slate
			rock.Color = Color3.fromRGB(90, 80, 110)
			rock.Parent = propsFolder
		end,
	})
	Debug.info("scattered " .. tostring(placed) .. " rocks")

	-- Spawn pad
	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "SpawnLocation"
	spawnLocation.Size = Vector3.new(8, 1, 8)
	spawnLocation.Position = Vector3.new(0, field:height(0, 0) + 1, 0)
	spawnLocation.Anchored = true
	spawnLocation.Material = Enum.Material.Neon
	spawnLocation.Color = Color3.fromRGB(160, 100, 255)
	spawnLocation.Parent = Workspace

	-- Glowing pillars as landmarks
	for i = 1, 4 do
		local angle = (i / 4) * math.pi * 2 + math.pi / 4
		local x = math.cos(angle) * 45
		local z = math.sin(angle) * 45
		local y = field:height(x, z)
		local pillar = Instance.new("Part")
		pillar.Name = "LandmarkPillar"
		pillar.Size = Vector3.new(3, 14, 3)
		pillar.Position = Vector3.new(x, y + 7, z)
		pillar.Anchored = true
		pillar.Material = Enum.Material.Glass
		pillar.Color = Color3.fromRGB(180, 120, 255)
		pillar.Transparency = 0.3
		pillar.Parent = Workspace
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(180, 120, 255)
		light.Brightness = 2
		light.Range = 30
		light.Parent = pillar
	end

	Debug.info("arena built with terrain")
	return { trees = 0, rocks = 18, ruins = 0, caches = 0 }
end

function Arena.start()
	Arena.build()
end

return Arena