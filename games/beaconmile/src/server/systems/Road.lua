--!strict
--[[
	Road — a night lane from the coal yard to the ridge.

	The open place used to be an empty Workspace until play, and play then
	dropped three neon cubes on a black slab. This builds the lane the
	shift is actually about: a path, a coal bin, and a brazier at each
	post. A second start restyles the same parts instead of stacking
	another copy. Everything is anchored before it is parented. Nothing
	is welded.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Road = {}

local SPAWN_NAME = "Spawn"
local GROUND_NAME = "Ground"

local GROUND_SPAN = 2048
local GROUND_THICKNESS = 16

local ROAD = Color3.fromRGB(54, 52, 48)
local STONE = Color3.fromRGB(72, 68, 62)
local IRON = Color3.fromRGB(48, 50, 54)
local FLAME = Color3.fromRGB(255, 156, 64)
local COAL = Color3.fromRGB(22, 20, 18)
local WOOD = Color3.fromRGB(92, 64, 40)
local PINE = Color3.fromRGB(22, 40, 28)
local MEADOW = Color3.fromRGB(34, 46, 30)

local function container(): Instance
	local existing = Workspace:FindFirstChild("Road")
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Road"
	folder.Parent = Workspace
	return folder
end

local function claim(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

local function part(parent: Instance, name: string): Part
	local inst = claim(parent, "Part", name) :: Part
	inst.Anchored = true
	inst.TopSurface = Enum.SurfaceType.Smooth
	inst.BottomSurface = Enum.SurfaceType.Smooth
	inst.CanCollide = true
	return inst
end

local function dress(inst: Part, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?)
	inst.Size = size
	inst.CFrame = cf
	inst.Color = color
	inst.Material = material
	if shape then
		inst.Shape = shape
	end
end

local function prompt(parent: BasePart, action: string, actionText: string, objectText: string, beaconId: string?)
	local existing = parent:FindFirstChild("Prompt")
	local item = if existing and existing:IsA("ProximityPrompt")
		then existing
		else Instance.new("ProximityPrompt")
	item.Name = "Prompt"
	item:SetAttribute("Action", action)
	if beaconId ~= nil then
		item:SetAttribute("BeaconId", beaconId)
	end
	item.ActionText = actionText
	item.ObjectText = objectText
	item.RequiresLineOfSight = false
	item.MaxActivationDistance = 12
	item.Parent = parent
end

local function lamp(parent: BasePart, name: string, range: number)
	local existing = parent:FindFirstChild(name)
	local light = if existing and existing:IsA("PointLight") then existing else Instance.new("PointLight")
	light.Name = name
	light.Color = FLAME
	light.Brightness = 2.4
	light.Range = range
	light.Shadows = true
	light.Parent = parent
end

local function ribbon(parent: Instance, name: string, a: Vector3, b: Vector3, width: number, y: number, color: Color3, material: Enum.Material)
	local flatA = Vector3.new(a.X, y, a.Z)
	local flatB = Vector3.new(b.X, y, b.Z)
	local delta = flatB - flatA
	local length = delta.Magnitude
	if length < 0.5 then
		return
	end
	local mid = flatA + delta / 2
	local inst = part(parent, name)
	dress(inst, Vector3.new(width, 0.35, length), CFrame.lookAt(mid, flatB), color, material)
end

local function pine(parent: Instance, name: string, x: number, z: number, y: number)
	local trunk = part(parent, name .. "Trunk")
	dress(trunk, Vector3.new(1.2, 7, 1.2), CFrame.new(x, y + 3.5, z), WOOD, Enum.Material.Wood)
	local crown = part(parent, name .. "Crown")
	dress(crown, Vector3.new(7, 8, 7), CFrame.new(x, y + 9, z), PINE, Enum.Material.Grass, Enum.PartType.Ball)
end

local function brazier(parent: Instance, beacon: { id: string, label: string?, position: Vector3 }, floorY: number)
	local x, z = beacon.position.X, beacon.position.Z
	local id = beacon.id
	local label = beacon.label or id

	local plinth = part(parent, id)
	dress(plinth, Vector3.new(4.5, 1.2, 4.5), CFrame.new(x, floorY + 0.6, z), STONE, Enum.Material.Cobblestone)
	prompt(plinth, "feed", "Alimentar", label, id)

	local post = part(parent, id .. "Post")
	dress(post, Vector3.new(0.7, 6.5, 0.7), CFrame.new(x, floorY + 4.4, z), IRON, Enum.Material.Metal)

	local bowl = part(parent, id .. "Bowl")
	dress(bowl, Vector3.new(2.4, 0.8, 2.4), CFrame.new(x, floorY + 7.6, z), IRON, Enum.Material.Metal)

	local flame = part(parent, id .. "Flame")
	dress(
		flame,
		Vector3.new(1.3, 1.6, 1.3),
		CFrame.new(x, floorY + 8.6, z),
		FLAME,
		Enum.Material.Neon,
		Enum.PartType.Ball
	)
	flame.CanCollide = false
	lamp(flame, "Fire", 36)
end

local function coalBin(parent: Instance, center: Vector3)
	local bin = part(parent, "CoalBin")
	dress(bin, Vector3.new(8, 1.4, 6), CFrame.new(center.X, center.Y + 0.7, center.Z - 1), WOOD, Enum.Material.WoodPlanks)

	local lumps = {
		Vector3.new(-1.6, 1.5, -0.6),
		Vector3.new(0.4, 1.7, -1.4),
		Vector3.new(1.8, 1.4, -0.2),
		Vector3.new(-0.2, 2.2, -0.8),
	}
	for index, offset in lumps do
		local lump = part(parent, "Coal" .. index)
		dress(
			lump,
			Vector3.new(1.8, 1.5, 1.6),
			CFrame.new(center.X + offset.X, center.Y + offset.Y, center.Z + offset.Z),
			COAL,
			Enum.Material.Slate,
			Enum.PartType.Ball
		)
		lump.CanCollide = false
	end
end

local function night()
	Lighting.ClockTime = 21.4
	Lighting.Brightness = 1.6
	Lighting.Ambient = Color3.fromRGB(42, 46, 62)
	Lighting.OutdoorAmbient = Color3.fromRGB(72, 82, 108)
	Lighting.FogColor = Color3.fromRGB(26, 30, 42)
	Lighting.FogStart = 120
	Lighting.FogEnd = 520
	Lighting.GlobalShadows = true

	local atmosphere = claim(Lighting, "Atmosphere", "BeaconAtmosphere") :: Atmosphere
	atmosphere.Density = 0.32
	atmosphere.Offset = 0.2
	atmosphere.Color = Color3.fromRGB(58, 68, 96)
	atmosphere.Decay = Color3.fromRGB(18, 16, 28)
	atmosphere.Glare = 0.15
	atmosphere.Haze = 1.4

	local grade = claim(Lighting, "ColorCorrectionEffect", "BeaconGrade") :: ColorCorrectionEffect
	grade.TintColor = Color3.fromRGB(214, 224, 255)
	grade.Saturation = -0.08
	grade.Contrast = 0.12
	grade.Brightness = 0.02

	local bloom = claim(Lighting, "BloomEffect", "BeaconBloom") :: BloomEffect
	bloom.Intensity = 0.45
	bloom.Size = 28
	bloom.Threshold = 0.9
end

function Road.start()
	night()
	local root = container()

	local padBottom = Config.yard.position.Y - Config.yard.size.Y / 2
	local floorY = padBottom
	local roadY = floorY + 0.58

	local ground = part(root, GROUND_NAME)
	dress(
		ground,
		Vector3.new(GROUND_SPAN, GROUND_THICKNESS, GROUND_SPAN),
		CFrame.new(0, floorY - GROUND_THICKNESS / 2, 0),
		MEADOW,
		Enum.Material.Grass
	)

	local meadow = part(root, "Meadow")
	dress(meadow, Vector3.new(180, 0.4, 160), CFrame.new(36, floorY + 0.2, -24), MEADOW, Enum.Material.LeafyGrass)

	local yard = part(root, Config.yard.partName)
	dress(yard, Config.yard.size, CFrame.new(Config.yard.position), STONE, Enum.Material.Cobblestone)
	prompt(yard, "take", "Pegar", "Carvão", nil)
	coalBin(root, Vector3.new(Config.yard.position.X, padTop, Config.yard.position.Z))

	local spawn = claim(root, "SpawnLocation", SPAWN_NAME) :: SpawnLocation
	local height = 1
	local padTop = Config.yard.position.Y + Config.yard.size.Y / 2
	spawn.Size = Vector3.new(6, height, 6)
	spawn.CFrame = CFrame.new(Config.yard.position.X, padTop + height / 2 + 0.05, Config.yard.position.Z + 4)
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Anchored = true
	spawn.CanCollide = false
	spawn.Transparency = 1

	local posts = Config.beacons
	local yardEdge = Vector3.new(Config.yard.position.X, roadY, Config.yard.position.Z - Config.yard.size.Z / 2)
	ribbon(root, "LaneYard", yardEdge, posts[1].position, 10, roadY, ROAD, Enum.Material.Asphalt)
	ribbon(root, "LaneBend", posts[1].position, posts[2].position, 10, roadY, ROAD, Enum.Material.Asphalt)
	ribbon(root, "LaneRidge", posts[2].position, posts[3].position, 10, roadY, ROAD, Enum.Material.Asphalt)

	for _, beacon in posts do
		brazier(root, beacon, floorY)
	end

	pine(root, "PineWest", -14, -18, floorY)
	pine(root, "PineEast", 16, -40, floorY)
	pine(root, "PineBend", 28, -16, floorY)
	pine(root, "PineRidge", 84, -40, floorY)
end

return Road
