--!strict
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local WorldKit = require(ReplicatedStorage.WorldKit)
local Build = WorldKit.Build
local Props = WorldKit.Props
local Setpiece = WorldKit.Setpiece
local Tokens = WorldKit.Tokens
local Palette = WorldKit.Palette
local Sky = WorldKit.Sky

local BarricadeModeler = require(ReplicatedStorage.Shared.MeshKit.BarricadeModeler)

local OutpostWorldBuilder = {}

function OutpostWorldBuilder.build(): { [string]: any }
	print("[OutpostWorldBuilder] Initializing WorldKit Apocalypse Outpost...")

	local tokens = Tokens.default()
	local theme = Palette.MinersRidge

	local mapFolder = Workspace:FindFirstChild("Map")
	if not mapFolder then
		mapFolder = Instance.new("Folder")
		mapFolder.Name = "Map"
		mapFolder.Parent = Workspace
	end

	local spawnPointsFolder = Instance.new("Folder")
	spawnPointsFolder.Name = "ZombieSpawns"
	spawnPointsFolder.Parent = mapFolder

	local barricadesFolder = Instance.new("Folder")
	barricadesFolder.Name = "Barricades"
	barricadesFolder.Parent = mapFolder

	-- 1. Main Vast Ground & Wasteland Platform
	local groundSwatch = Palette.get(theme, "pavement") or { color = Color3.fromRGB(38, 40, 45), material = Enum.Material.Slate }
	local ground = Build.part(mapFolder, "MainGround", Vector3.new(650, 4, 650), Vector3.new(0, -2, 0), groundSwatch)

	-- 2. Fortified Safe Zone Platform (Elevated with stepped trims)
	local floorSwatch = Palette.get(theme, "stoneSecondary") or { color = Color3.fromRGB(60, 65, 75), material = Enum.Material.DiamondPlate }
	local trimSwatch = Palette.get(theme, "accentGold") or { color = Color3.fromRGB(80, 85, 95), material = Enum.Material.Concrete }
	local bunkerFloor = Build.platform(mapFolder, "BunkerFloor", Vector3.new(100, 1.5, 100), Vector3.new(0, 0.75, 0), floorSwatch, trimSwatch, 1.2)

	-- 3. Gothic Ruined Sanctuary Keep (Built via WorldKit.Setpiece)
	local sanctuary = Setpiece.ruinedSanctuary(mapFolder, tokens, {
		cframe = CFrame.new(0, 1.5, -30),
		width = 45,
		length = 60,
		wallHeight = 22,
		naveWidth = 18,
		bays = 4,
		seed = 1042,
		focusKind = "altar",
	})
	sanctuary.model.Name = "SanctuaryKeep"

	-- 4. Perimeter Ramparts & Reinforced Defensive Walls
	local wallSwatch = Palette.get(theme, "stonePrimary") or { color = Color3.fromRGB(55, 58, 65), material = Enum.Material.Concrete }
	local metalSwatch = Palette.get(theme, "metalDark") or { color = Color3.fromRGB(30, 32, 36), material = Enum.Material.Metal }

	-- North, South, East, West Wall Segments with Gate Openings
	local walls = {
		{ name = "WallN_L", size = Vector3.new(38, 14, 4), pos = Vector3.new(-30, 7, -50) },
		{ name = "WallN_R", size = Vector3.new(38, 14, 4), pos = Vector3.new(30, 7, -50) },
		{ name = "WallS_L", size = Vector3.new(38, 14, 4), pos = Vector3.new(-30, 7, 50) },
		{ name = "WallS_R", size = Vector3.new(38, 14, 4), pos = Vector3.new(30, 7, 50) },
		{ name = "WallW_L", size = Vector3.new(4, 14, 38), pos = Vector3.new(-50, 7, -30) },
		{ name = "WallW_R", size = Vector3.new(4, 14, 38), pos = Vector3.new(-50, 7, 30) },
		{ name = "WallE_L", size = Vector3.new(4, 14, 38), pos = Vector3.new(50, 7, -30) },
		{ name = "WallE_R", size = Vector3.new(4, 14, 38), pos = Vector3.new(50, 7, 30) },
	}
	for _, w in ipairs(walls) do
		Build.part(mapFolder, w.name, w.size, w.pos, wallSwatch)
	end

	-- 5. Four Corner Watchtowers with High-Power Floodlights
	local cornerCoords = {
		Vector3.new(-50, 0, -50),
		Vector3.new(50, 0, -50),
		Vector3.new(-50, 0, 50),
		Vector3.new(50, 0, 50),
	}
	for i, coord in ipairs(cornerCoords) do
		local towerPillar = Build.cylinder(mapFolder, "TowerPillar_" .. i, Vector3.new(6, 28, 6), coord + Vector3.new(0, 14, 0), metalSwatch)
		local platform = Build.platform(mapFolder, "TowerPlatform_" .. i, Vector3.new(16, 2, 16), coord + Vector3.new(0, 28, 0), floorSwatch, trimSwatch, 1.5)

		local spot = Instance.new("SpotLight")
		spot.Name = "TowerFloodlight"
		spot.Color = Color3.fromRGB(255, 245, 220)
		spot.Brightness = 6.0
		spot.Range = 140
		spot.Angle = 75
		spot.Face = Enum.NormalId.Bottom
		spot.Shadows = true
		spot.Parent = platform
	end

	-- 6. Props: Braziers, Lamp Posts, Weapons Racks, Crates, Barrels (via WorldKit.Props)
	-- Braziers at Gates
	local brazierPositions = {
		Vector3.new(-12, 1.5, -48),
		Vector3.new(12, 1.5, -48),
		Vector3.new(-12, 1.5, 48),
		Vector3.new(12, 1.5, 48),
		Vector3.new(-48, 1.5, -12),
		Vector3.new(-48, 1.5, 12),
		Vector3.new(48, 1.5, -12),
		Vector3.new(48, 1.5, 12),
	}
	for i, bPos in ipairs(brazierPositions) do
		local brazier = Props.brazier(mapFolder, tokens, { position = bPos, scale = 1.1, seed = 50 + i })
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 140, 40)
		light.Brightness = 4.0
		light.Range = 35
		light.Parent = brazier
	end

	-- Supply Crates & Barrels Scatter
	local cratePositions = {
		Vector3.new(-22, 1.5, -18),
		Vector3.new(-26, 1.5, -20),
		Vector3.new(24, 1.5, -22),
		Vector3.new(28, 1.5, -24),
		Vector3.new(-25, 1.5, 20),
		Vector3.new(25, 1.5, 20),
	}
	for i, cPos in ipairs(cratePositions) do
		Props.crate(mapFolder, tokens, { position = cPos, scale = 1.0, seed = 200 + i })
		Props.barrel(mapFolder, tokens, { position = cPos + Vector3.new(3, 0, 1), scale = 0.9, seed = 300 + i })
	end

	-- Weapons Rack beside Quartermaster
	Props.weaponsRack(mapFolder, tokens, { position = Vector3.new(-18, 1.5, -15), rotation = 45, scale = 1.1, seed = 77 })

	-- 7. Dead Trees & Rocky Outcroppings in the Wasteland (via WorldKit.Props)
	local treeSeed = Random.new(8888)
	for i = 1, 24 do
		local dist = treeSeed:NextNumber(90, 240)
		local angle = treeSeed:NextNumber(0, math.pi * 2)
		local tPos = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
		Props.tree(mapFolder, tokens, { position = tPos, scale = treeSeed:NextNumber(0.8, 1.4), seed = i * 73 })
	end

	for i = 1, 20 do
		local dist = treeSeed:NextNumber(70, 220)
		local angle = treeSeed:NextNumber(0, math.pi * 2)
		local rPos = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
		Props.rock(mapFolder, tokens, { position = rPos, scale = treeSeed:NextNumber(1.0, 2.5), seed = i * 91 })
	end

	-- 8. Quartermaster Shop Station
	local shopCounter = Build.building(mapFolder, "QuartermasterShop", Vector3.new(18, 7, 8), Vector3.new(-22, 4, -18), wallSwatch, trimSwatch)
	local shopPrompt = Instance.new("ProximityPrompt")
	shopPrompt.Name = "ShopPrompt"
	shopPrompt.ActionText = "Open Armory"
	shopPrompt.ObjectText = "Quartermaster"
	shopPrompt.HoldDuration = 0.2
	shopPrompt.MaxActivationDistance = 14.0
	shopPrompt.Parent = shopCounter

	local shopSign = Props.sign(mapFolder, tokens, {
		position = Vector3.new(-22, 8.5, -14),
		rotation = 0,
		scale = 1.2,
		text = "ARMORY",
		seed = 123,
	})

	-- 9. Defensive Gate Barricades
	local gateCFrames = {
		CFrame.new(0, 1.5, -50),
		CFrame.new(0, 1.5, 50),
		CFrame.new(-50, 1.5, 0) * CFrame.Angles(0, math.rad(90), 0),
		CFrame.new(50, 1.5, 0) * CFrame.Angles(0, math.rad(90), 0),
	}
	for i, cf in ipairs(gateCFrames) do
		local bar = BarricadeModeler.build(1, cf)
		bar.Name = "Barricade_" .. i
		bar.Parent = barricadesFolder
	end

	-- 10. Zombie Spawn Portals in the Mist
	local spawnCoords = {
		Vector3.new(0, 1, -160),
		Vector3.new(0, 1, 160),
		Vector3.new(-160, 1, 0),
		Vector3.new(160, 1, 0),
		Vector3.new(-120, 1, -120),
		Vector3.new(120, 1, -120),
		Vector3.new(-120, 1, 120),
		Vector3.new(120, 1, 120),
	}
	for i, pos in ipairs(spawnCoords) do
		local sp = Build.cylinder(spawnPointsFolder, "Spawn_" .. i, Vector3.new(10, 1, 10), pos, { color = Color3.fromRGB(255, 40, 40), material = Enum.Material.Neon })
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 40, 40)
		light.Brightness = 4.0
		light.Range = 30
		light.Parent = sp
	end

	-- 11. Safe Zone Player Spawn
	local spawnPad = Instance.new("SpawnLocation")
	spawnPad.Name = "SafeZoneSpawn"
	spawnPad.Size = Vector3.new(12, 1, 12)
	spawnPad.Position = Vector3.new(0, 2, 10)
	spawnPad.Anchored = true
	spawnPad.CanCollide = true
	spawnPad.Color = Color3.fromRGB(0, 220, 255)
	spawnPad.Material = Enum.Material.Neon
	spawnPad.Duration = 0
	spawnPad.Parent = mapFolder

	-- 12. Atmosphere & Sky Mood (via WorldKit.Sky & Lighting)
	Lighting.ClockTime = 18.4 -- Dusk Twilight
	Lighting.Brightness = 2.4
	Lighting.Ambient = Color3.fromRGB(65, 70, 85)
	Lighting.OutdoorAmbient = Color3.fromRGB(85, 95, 115)
	Lighting.ShadowSoftness = 0.3
	Lighting.FogColor = Color3.fromRGB(45, 50, 65)
	Lighting.FogStart = 100
	Lighting.FogEnd = 550

	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Parent = Lighting
	end
	atmosphere.Density = 0.38
	atmosphere.Offset = 0.25
	atmosphere.Color = Color3.fromRGB(95, 100, 120)
	atmosphere.Decay = Color3.fromRGB(40, 45, 60)
	atmosphere.Glare = 0.2
	atmosphere.Haze = 1.5

	local colorCorrection = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	if not colorCorrection then
		colorCorrection = Instance.new("ColorCorrectionEffect")
		colorCorrection.Parent = Lighting
	end
	colorCorrection.Brightness = 0.04
	colorCorrection.Contrast = 0.15
	colorCorrection.Saturation = -0.1
	colorCorrection.TintColor = Color3.fromRGB(255, 245, 240)

	local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
	if not bloom then
		bloom = Instance.new("BloomEffect")
		bloom.Parent = Lighting
	end
	bloom.Intensity = 0.6
	bloom.Size = 24
	bloom.Threshold = 0.82

	print("[OutpostWorldBuilder] WorldKit Apocalypse Outpost Built with 100% Architectural Composition!")

	return {
		mapFolder = mapFolder,
		spawnPoints = spawnPointsFolder:GetChildren(),
		barricades = barricadesFolder:GetChildren(),
		shopCounter = shopCounter,
	}
end

return OutpostWorldBuilder
