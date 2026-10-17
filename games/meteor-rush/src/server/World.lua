--!strict
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Mark = Forge.Mark
local Place = Forge.Catalog.Place
local Itch = Forge.Catalog.ItchAssets
local Rng = Forge.Core.Rng

local Config = require(ReplicatedStorage.Shared.Config)
local Content = require(ReplicatedStorage.Shared.Content)

local World = {}

export type Base = {
	index: number,
	model: Model,
	cf: CFrame,
	spawn: BasePart,
	decoder: BasePart,
	decoderPrompt: ProximityPrompt,
	ownerLabel: TextLabel,
	owner: Player?,
	displays: Folder,
}

World.root = nil :: Folder?
World.meteors = nil :: Folder?
World.bases = {} :: { Base }
World.byPlayer = {} :: { [Player]: Base }

local decorRng = Rng.stream("meteor-rush.decor")

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function cylinder(parent: Instance, name: string, diameter: number, height: number, position: Vector3, color: Color3, material: Enum.Material): Part
	local p = part(
		parent,
		name,
		Vector3.new(height, diameter, diameter),
		CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90)),
		color,
		material
	)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function surface(target: BasePart, variant: string, base: Enum.Material)
	target.Material = base
	target.MaterialVariant = variant
end

local function light(parent: Instance, color: Color3, brightness: number, range: number)
	local value = Instance.new("PointLight")
	value.Color = color
	value.Brightness = brightness
	value.Range = range
	value.Shadows = false
	value.Parent = parent
	return value
end

local function worldLabel(parent: BasePart, text: string, color: Color3, maxDistance: number, offset: Vector3?): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Name = "WorldLabel"
	gui.Size = UDim2.fromOffset(220, 44)
	gui.StudsOffset = offset or Vector3.new(0, 4.5, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = maxDistance
	gui.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Content.palette.panel
	label.BackgroundTransparency = 0.22
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.82
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label
	return label
end

local function surfaceLabel(parent: BasePart, text: string): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Sign"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 34
	gui.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Content.palette.cream
	label.TextStrokeTransparency = 0.65
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = gui
	return label
end

local function safeProp(topic: string, seed: number, at: Vector3, parent: Instance, heightScale: number?, solid: boolean?): Instance?
	local ok, model = pcall(function()
		return Place.put(Itch, {
			topic = topic,
			seed = seed,
			at = at,
			yaw = decorRng:number(0, math.pi * 2),
			parent = parent,
			jitter = heightScale or 1,
			solid = solid == true,
		})
	end)
	return ok and model or nil
end

local function makeBase(parent: Instance, index: number): Base
	local angle = ((index - 1) / Config.maxPlayers) * math.pi * 2
	local position = Vector3.new(math.cos(angle) * Config.baseRadius, 4, math.sin(angle) * Config.baseRadius)
	local cf = CFrame.lookAt(position, Vector3.new(0, 4, 0))
	local model = Instance.new("Model")
	model.Name = "Base" .. index
	model.Parent = parent

	local yard = part(model, "Yard", Vector3.new(88, 1.2, 70), cf * CFrame.new(0, -1.5, 2), Content.palette.ground2, Enum.Material.Ground)
	surface(yard, "DryGround", Enum.Material.Ground)

	local deck = part(model, "Platform", Vector3.new(70, 2, 50), cf, Content.palette.wood, Enum.Material.WoodPlanks)
	surface(deck, "PlankFloor", Enum.Material.WoodPlanks)

	local back = part(model, "BackWall", Vector3.new(70, 15, 2), cf * CFrame.new(0, 7.5, 23), Content.palette.cream, Enum.Material.Plaster)
	surface(back, "PlasterWall", Enum.Material.Plaster)

	local roof = part(model, "Awning", Vector3.new(72, 1.3, 18), cf * CFrame.new(0, 15.2, 16.5), Content.palette.rust, Enum.Material.Metal)
	surface(roof, "RustPlate", Enum.Material.Metal)
	roof.CFrame *= CFrame.Angles(math.rad(-5), 0, 0)

	for x = -30, 30, 60 do
		local post = part(model, "TimberPost", Vector3.new(2.4, 16, 2.4), cf * CFrame.new(x, 7.5, 16), Content.palette.wood, Enum.Material.Wood)
		surface(post, "BareWood", Enum.Material.Wood)
	end

	for slot = 1, 6 do
		local x = (slot - 3.5) * 10.5
		local stand = part(model, "DisplayPad", Vector3.new(8, 1, 8), cf * CFrame.new(x, 1.7, 4), Content.palette.cream, Enum.Material.WoodPlanks)
		surface(stand, "PlankFloor", Enum.Material.WoodPlanks)
		stand:SetAttribute("Slot", slot)
	end

	local spawn = part(model, "Spawn", Vector3.new(10, 1, 10), cf * CFrame.new(0, 2, 18), Content.palette.gold, Enum.Material.Sand)
	spawn.Transparency = 0.42
	spawn.CanCollide = false

	local decoder = part(model, "Decoder", Vector3.new(14, 11, 11), cf * CFrame.new(0, 6, -16), Content.palette.rust, Enum.Material.Metal)
	surface(decoder, "RustPlate", Enum.Material.Metal)

	local hopper = part(model, "DecoderHopper", Vector3.new(10, 4, 8), decoder.CFrame * CFrame.new(0, 7.2, 0), Content.palette.panel, Enum.Material.Metal)
	surface(hopper, "RustPlate", Enum.Material.Metal)
	hopper.CFrame *= CFrame.Angles(0, 0, math.rad(8))

	for x = -4, 4, 8 do
		local pipe = part(model, "Pipe", Vector3.new(1.2, 7, 1.2), decoder.CFrame * CFrame.new(x, 0, 5.7), Color3.fromRGB(91, 78, 64), Enum.Material.Metal)
		pipe.Shape = Enum.PartType.Cylinder
	end

	local lamp = part(model, "DecoderLamp", Vector3.new(2.7, 2.7, 0.8), decoder.CFrame * CFrame.new(0, 2, -5.8), Content.palette.gold, Enum.Material.Glass)
	lamp.CanCollide = false
	light(lamp, Content.palette.gold, 1.2, 13)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "DecodePrompt"
	prompt.ActionText = "Decode"
	prompt.ObjectText = "Meteor Decoder"
	prompt.HoldDuration = 0.35
	prompt.MaxActivationDistance = Config.decoderRadius
	prompt.RequiresLineOfSight = false
	prompt.Parent = decoder

	local sign = part(model, "OwnerSign", Vector3.new(20, 4, 0.9), cf * CFrame.new(0, 10, 22), Content.palette.wood, Enum.Material.Wood)
	surface(sign, "BareWood", Enum.Material.Wood)
	local ownerLabel = surfaceLabel(sign, "UNCLAIMED YARD")

	local displays = Instance.new("Folder")
	displays.Name = "Specimens"
	displays.Parent = model

	safeProp("barrel", index * 101 + 1, (cf * CFrame.new(-25, 0, -18)).Position, model, 1.1, false)
	safeProp("barrel", index * 101 + 2, (cf * CFrame.new(26, 0, -18)).Position, model, 1.0, false)
	safeProp("anvil", index * 101 + 3, (cf * CFrame.new(23, 0, 16)).Position, model, 1.0, false)
	safeProp("rock", index * 101 + 4, (cf * CFrame.new(-32, 0, 20)).Position, model, 1.25, false)

	deck:SetAttribute("BaseIndex", index)
	pcall(function() Mark.root(model, "lab", "salvage-yard") end)

	return {
		index = index,
		model = model,
		cf = cf,
		spawn = spawn,
		decoder = decoder,
		decoderPrompt = prompt,
		ownerLabel = ownerLabel,
		owner = nil,
		displays = displays,
	}
end

local function buildBeacon(arena: Folder): Model
	local model = Instance.new("Model")
	model.Name = "MeteorBeacon"
	model.Parent = arena

	local foundation = cylinder(model, "StoneBase", 24, 3, Vector3.new(0, 3.5, 0), Color3.fromRGB(128, 111, 88), Enum.Material.Slate)
	surface(foundation, "WarmStone", Enum.Material.Slate)

	for x = -8, 8, 16 do
		for z = -8, 8, 16 do
			local post = part(model, "Timber", Vector3.new(2, 24, 2), CFrame.new(x, 15, z), Content.palette.wood, Enum.Material.Wood)
			surface(post, "BareWood", Enum.Material.Wood)
		end
	end

	local cap = part(model, "Cap", Vector3.new(22, 1.8, 22), CFrame.new(0, 27.5, 0), Content.palette.rust, Enum.Material.Metal)
	surface(cap, "RustPlate", Enum.Material.Metal)

	local lantern = part(model, "Lantern", Vector3.new(6, 6, 6), CFrame.new(0, 23.5, 0), Content.palette.gold, Enum.Material.Glass)
	lantern.Shape = Enum.PartType.Ball
	lantern.CanCollide = false
	light(lantern, Color3.fromRGB(255, 183, 87), 2.1, 34)

	local sign = part(model, "FieldSign", Vector3.new(18, 4, 0.9), CFrame.new(0, 12, -9), Content.palette.wood, Enum.Material.Wood)
	surface(sign, "BareWood", Enum.Material.Wood)
	surfaceLabel(sign, "METEOR FIELD")

	return model
end

local function buildFieldPOI(parent: Folder, angle: number, radius: number, seed: number, variant: string)
	local p = Vector3.new(math.cos(angle) * radius, 3, math.sin(angle) * radius)
	local cf = CFrame.lookAt(p, Vector3.new(0, 3, 0))
	local poi = Instance.new("Model")
	poi.Name = variant
	poi.Parent = parent

	if variant == "SurveyCamp" then
		local floor = part(poi, "Platform", Vector3.new(28, 1, 20), cf, Content.palette.wood, Enum.Material.WoodPlanks)
		surface(floor, "PlankFloor", Enum.Material.WoodPlanks)
		local tableTop = part(poi, "Table", Vector3.new(10, 0.8, 5), cf * CFrame.new(0, 3, 0), Content.palette.wood, Enum.Material.Wood)
		surface(tableTop, "BareWood", Enum.Material.Wood)
		for x = -4, 4, 8 do
			for z = -1.8, 1.8, 3.6 do
				local leg = part(poi, "Leg", Vector3.new(0.7, 3, 0.7), cf * CFrame.new(x, 1.5, z), Content.palette.wood, Enum.Material.Wood)
				surface(leg, "BareWood", Enum.Material.Wood)
			end
		end
		local mast = part(poi, "SurveyMast", Vector3.new(1.1, 13, 1.1), cf * CFrame.new(-9, 6.5, -5), Content.palette.rust, Enum.Material.Metal)
		surface(mast, "RustPlate", Enum.Material.Metal)
		local vane = part(poi, "WindVane", Vector3.new(7, 0.5, 1.1), mast.CFrame * CFrame.new(0, 6.3, 0), Content.palette.gold, Enum.Material.Metal)
		vane.CanCollide = false
		safeProp("barrel", seed + 1, (cf * CFrame.new(-10, 0, 6)).Position, poi, 0.9, false)
		safeProp("anvil", seed + 2, (cf * CFrame.new(10, 0, 5)).Position, poi, 0.9, false)
	elseif variant == "OldQuarry" then
		local shelf = cylinder(poi, "QuarryShelf", 44, 2.4, p + Vector3.new(0, -0.2, 0), Color3.fromRGB(112, 96, 76), Enum.Material.Slate)
		surface(shelf, "WarmStone", Enum.Material.Slate)
		for x = -8, 8, 16 do
			local post = part(poi, "HoistPost", Vector3.new(2, 17, 2), cf * CFrame.new(x, 8.5, 0), Content.palette.wood, Enum.Material.Wood)
			surface(post, "BareWood", Enum.Material.Wood)
		end
		local beam = part(poi, "HoistBeam", Vector3.new(20, 2, 2), cf * CFrame.new(0, 17, 0), Content.palette.wood, Enum.Material.Wood)
		surface(beam, "BareWood", Enum.Material.Wood)
		local cable = part(poi, "Cable", Vector3.new(0.35, 10, 0.35), cf * CFrame.new(0, 11.5, 0), Color3.fromRGB(73, 69, 60), Enum.Material.Metal)
		cable.CanCollide = false
		local bucket = cylinder(poi, "OreBucket", 4.5, 4, (cf * CFrame.new(0, 6.2, 0)).Position, Content.palette.rust, Enum.Material.Metal)
		surface(bucket, "RustPlate", Enum.Material.Metal)
		for i = 1, 6 do
			local a = (i / 6) * math.pi * 2
			safeProp("rock", seed + i, p + Vector3.new(math.cos(a) * 16, 1, math.sin(a) * 16), poi, 1.25 + (i % 2) * 0.3, false)
		end
	elseif variant == "ScorchedGrove" then
		local patch = cylinder(poi, "BurntPatch", 54, 0.8, p + Vector3.new(0, -0.1, 0), Color3.fromRGB(82, 72, 52), Enum.Material.Ground)
		surface(patch, "DryGround", Enum.Material.Ground)
		for i = 1, 7 do
			local a = (i / 7) * math.pi * 2
			local r = 17 + (i % 2) * 5
			local trunk = part(
				poi,
				"BurntTrunk",
				Vector3.new(2.2, 14 + (i % 3) * 3, 2.2),
				CFrame.new(p + Vector3.new(math.cos(a) * r, 7, math.sin(a) * r))
					* CFrame.Angles(math.rad((i % 2) * 8), a, math.rad((i % 3 - 1) * 7)),
				Color3.fromRGB(70, 52, 38),
				Enum.Material.Wood
			)
			trunk.CanCollide = false
		end
		local ember = part(poi, "OldEmber", Vector3.new(4, 4, 4), CFrame.new(p + Vector3.new(0, 2, 0)), Content.palette.rust, Enum.Material.Glass)
		ember.Shape = Enum.PartType.Ball
		ember.CanCollide = false
		light(ember, Content.palette.accent, 0.55, 9)
		for i = 1, 5 do
			local a = (i / 5) * math.pi * 2
			safeProp("rock", seed + i, p + Vector3.new(math.cos(a) * 11, 1, math.sin(a) * 11), poi, 0.9, false)
		end
	end
end

function World.build()
	local old = Workspace:FindFirstChild("MeteorRush")
	if old then old:Destroy() end

	local root = Instance.new("Folder")
	root.Name = "MeteorRush"
	root.Parent = Workspace
	World.root = root

	local arena = Instance.new("Folder")
	arena.Name = "Arena"
	arena.Parent = root

	local ground = part(
		arena,
		"Ground",
		Vector3.new(Config.worldSize, 6, Config.worldSize),
		CFrame.new(0, -1, 0),
		Content.palette.ground,
		Enum.Material.Grass
	)
	surface(ground, "MeadowGrass", Enum.Material.Grass)

	local craterRim = cylinder(
		arena,
		"CraterRim",
		Config.craterRadius * 2 + 34,
		3,
		Vector3.new(0, 2.2, 0),
		Color3.fromRGB(126, 103, 74),
		Enum.Material.Slate
	)
	surface(craterRim, "WarmStone", Enum.Material.Slate)

	local crater = cylinder(
		arena,
		"Crater",
		Config.craterRadius * 2,
		1.8,
		Vector3.new(0, 3.5, 0),
		Content.palette.ground2,
		Enum.Material.Ground
	)
	surface(crater, "DryGround", Enum.Material.Ground)

	local innerScar = cylinder(
		arena,
		"OldImpact",
		72,
		0.7,
		Vector3.new(0, 4.5, 0),
		Color3.fromRGB(87, 71, 58),
		Enum.Material.Rock
	)
	surface(innerScar, "WarmStone", Enum.Material.Slate)

	local beacon = buildBeacon(arena)
	pcall(function()
		Mark.region(crater, "arena")
		Mark.landmark(beacon, "meteor-beacon")
		Mark.ringAnchors(beacon, "meteor-beacon", 8, 14)
	end)

	for i = 1, Config.maxPlayers do
		local angle = ((i - 1) / Config.maxPlayers) * math.pi * 2
		local startRadius = Config.craterRadius + 10
		local endRadius = Config.baseRadius - 38
		local midpointRadius = (startRadius + endRadius) * 0.5
		local midpoint = Vector3.new(math.cos(angle) * midpointRadius, 3.1, math.sin(angle) * midpointRadius)
		local target = Vector3.new(math.cos(angle) * startRadius, 3.1, math.sin(angle) * startRadius)
		local path = part(
			arena,
			"DirtTrack" .. i,
			Vector3.new(22, 0.7, endRadius - startRadius + 12),
			CFrame.lookAt(midpoint, target),
			Content.palette.ground2,
			Enum.Material.Ground
		)
		surface(path, "DryGround", Enum.Material.Ground)
	end

	-- Authored sub-landmarks break radial repetition without adding gameplay
	-- systems or content burden.
	buildFieldPOI(arena, math.rad(30), 160, 6100, "SurveyCamp")
	buildFieldPOI(arena, math.rad(150), 166, 6200, "OldQuarry")
	buildFieldPOI(arena, math.rad(270), 158, 6300, "ScorchedGrove")

	-- Crater berm: high enough to create a horizon, sparse enough to preserve
	-- six readable entrances from the player yards.
	for i = 1, 24 do
		local angle = (i / 24) * math.pi * 2
		local gateIndex = math.floor(((angle % (math.pi * 2)) / (math.pi * 2)) * 6 + 0.5) % 6
		local gateAngle = (gateIndex / 6) * math.pi * 2
		local delta = math.abs(math.atan2(math.sin(angle - gateAngle), math.cos(angle - gateAngle)))
		if delta > 0.14 then
			local radius = Config.craterRadius + decorRng:number(8, 18)
			safeProp(
				"rock",
				7000 + i,
				Vector3.new(math.cos(angle) * radius, 3.5, math.sin(angle) * radius),
				arena,
				decorRng:number(1.35, 2.15),
				false
			)
		end
	end

	for i = 1, 26 do
		local angle = (i / 26) * math.pi * 2 + decorRng:number(-0.08, 0.08)
		local radius = decorRng:number(172, 248)
		safeProp(
			"tree",
			8000 + i,
			Vector3.new(math.cos(angle) * radius, 2.2, math.sin(angle) * radius),
			arena,
			decorRng:number(1.0, 1.38),
			false
		)
	end

	for i = 1, 28 do
		local angle = decorRng:number(0, math.pi * 2)
		local radius = decorRng:number(145, 250)
		safeProp(
			"rock",
			9000 + i,
			Vector3.new(math.cos(angle) * radius, 2.3, math.sin(angle) * radius),
			arena,
			decorRng:number(0.75, 1.6),
			false
		)
	end

	local meteorFolder = Instance.new("Folder")
	meteorFolder.Name = "Meteors"
	meteorFolder.Parent = root
	World.meteors = meteorFolder

	local baseFolder = Instance.new("Folder")
	baseFolder.Name = "Bases"
	baseFolder.Parent = root
	World.bases = {}
	World.byPlayer = {}
	for i = 1, Config.maxPlayers do
		table.insert(World.bases, makeBase(baseFolder, i))
	end

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "FallbackSpawn"
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = CFrame.new(0, 7, Config.baseRadius + 55)
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.Parent = root
end

function World.assign(player: Player): Base?
	if World.byPlayer[player] then return World.byPlayer[player] end
	for _, base in World.bases do
		if base.owner == nil then
			base.owner = player
			World.byPlayer[player] = base
			base.model:SetAttribute("OwnerUserId", player.UserId)
			base.ownerLabel.Text = string.upper(player.DisplayName .. "'S YARD")
			base.decoderPrompt.ObjectText = player.DisplayName .. "'s Decoder"
			return base
		end
	end
	return nil
end

function World.release(player: Player)
	local base = World.byPlayer[player]
	if not base then return end
	base.owner = nil
	base.model:SetAttribute("OwnerUserId", 0)
	base.ownerLabel.Text = "UNCLAIMED YARD"
	base.decoderPrompt.ObjectText = "Meteor Decoder"
	base.displays:ClearAllChildren()
	World.byPlayer[player] = nil
end

function World.base(player: Player): Base?
	return World.byPlayer[player]
end

function World.teleportHome(player: Player)
	local base = World.byPlayer[player]
	local character = player.Character
	if not base or not character then return end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.CFrame = base.cf * CFrame.new(0, 6, 18)
	end
end

function World.randomMeteorPosition(random: Random): Vector3
	local angle = random:NextNumber(0, math.pi * 2)
	local radius = math.sqrt(random:NextNumber()) * (Config.arenaRadius - 22)
	return Vector3.new(math.cos(angle) * radius, 6.2, math.sin(angle) * radius)
end

local function meteorParticles(parent: BasePart, meteor: any)
	local attachment = Instance.new("Attachment")
	attachment.Name = "MeteorVFX"
	attachment.Parent = parent

	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Rate = if meteor.rarity >= 4 then 4 + meteor.rarity * 2 else 0
	smoke.Lifetime = NumberRange.new(1.1, 2.3)
	smoke.Speed = NumberRange.new(0.6, 2)
	smoke.SpreadAngle = Vector2.new(25, 25)
	smoke.RotSpeed = NumberRange.new(-20, 20)
	smoke.Color = ColorSequence.new(
		Color3.fromRGB(96, 78, 65),
		if meteor.style == "cosmic" then Color3.fromRGB(92, 48, 56) else Color3.fromRGB(136, 116, 89)
	)
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.8 * meteor.scale),
		NumberSequenceKeypoint.new(1, 4.8 * meteor.scale),
	})
	smoke.Parent = attachment

	local burst = Instance.new("ParticleEmitter")
	burst.Name = "ImpactBurst"
	burst.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	burst.Rate = 0
	burst.Lifetime = NumberRange.new(0.45, 1.1)
	burst.Speed = NumberRange.new(7, 17)
	burst.SpreadAngle = Vector2.new(180, 180)
	burst.Color = ColorSequence.new(meteor.core)
	burst.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55 * meteor.scale),
		NumberSequenceKeypoint.new(1, 0),
	})
	burst.Parent = attachment
	burst:Emit(10 + meteor.rarity * 5)
end

local function shard(parent: Instance, cf: CFrame, size: Vector3, color: Color3, material: Enum.Material): Part
	local p = part(parent, "Shard", size, cf, color, material)
	p.CanCollide = false
	return p
end

local function buildMeteorBody(model: Model, center: Vector3, meteor: any, serial: number): BasePart
	local scale = meteor.scale
	local main = safeProp("rock", 12000 + serial * 7 + meteor.rarity, Vector3.new(center.X, 4.15, center.Z), model, 1.65 * scale, false)

	local anchor = part(
		model,
		"Core",
		Vector3.new(3.3, 3.3, 3.3) * scale,
		CFrame.new(center + Vector3.new(0, 1.3 * scale, 0)),
		meteor.core,
		Enum.Material.Glass
	)
	anchor.Shape = Enum.PartType.Ball
	anchor.CanCollide = false

	if main then
		for _, descendant in main:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Color = meteor.rock
				if meteor.style == "iron" or meteor.style == "ancient" then
					descendant.Material = Enum.Material.Slate
				end
			end
		end
	end

	local random = Random.new(Config.seed + serial * 97 + meteor.rarity * 1009)
	for i = 1, meteor.fragments do
		local angle = (i / meteor.fragments) * math.pi * 2 + random:NextNumber(-0.25, 0.25)
		local radius = random:NextNumber(2.8, 5.4) * scale
		local y = random:NextNumber(-1.2, 2.6) * scale
		local size = Vector3.new(
			random:NextNumber(1.5, 3.4),
			random:NextNumber(1.5, 4),
			random:NextNumber(1.5, 3.4)
		) * scale
		local piece = part(
			model,
			"Fragment",
			size,
			CFrame.new(center + Vector3.new(math.cos(angle) * radius, y, math.sin(angle) * radius))
				* CFrame.Angles(random:NextNumber(0, math.pi), random:NextNumber(0, math.pi), random:NextNumber(0, math.pi)),
			meteor.rock,
			if meteor.style == "iron" then Enum.Material.Metal else Enum.Material.Rock
		)
		piece.Shape = Enum.PartType.Ball
		piece.CanCollide = false
	end

	if meteor.style == "iron" then
		for i = 1, 3 do
			local band = shard(
				model,
				CFrame.new(center + Vector3.new(0, (i - 2) * 2.1 * scale, 0))
					* CFrame.Angles(math.rad(15 * i), math.rad(35 * i), math.rad(12 * i)),
				Vector3.new(9.5, 0.65, 1.1) * scale,
				Color3.fromRGB(136, 95, 61),
				Enum.Material.Metal
			)
			band.Name = "IronVein"
		end
	elseif meteor.style == "crystal" then
		for i = 1, 6 do
			local angle = (i / 6) * math.pi * 2
			local spike = shard(
				model,
				CFrame.new(center + Vector3.new(math.cos(angle) * 4 * scale, 3.2 * scale, math.sin(angle) * 4 * scale))
					* CFrame.Angles(math.rad(-18), -angle, math.rad(18)),
				Vector3.new(1.15, 6.5, 1.15) * scale,
				meteor.core,
				Enum.Material.Glass
			)
			spike.Name = "Crystal"
		end
	elseif meteor.style == "molten" then
		for i = 1, 7 do
			local angle = (i / 7) * math.pi * 2
			local crack = shard(
				model,
				CFrame.new(center + Vector3.new(math.cos(angle) * 4.5 * scale, random:NextNumber(-1, 2) * scale, math.sin(angle) * 4.5 * scale))
					* CFrame.Angles(random:NextNumber(-0.6, 0.6), -angle, random:NextNumber(-0.5, 0.5)),
				Vector3.new(0.45, random:NextNumber(3.2, 5.8), 0.5) * scale,
				meteor.core,
				Enum.Material.Neon
			)
			crack.Name = "MagmaCrack"
		end
	elseif meteor.style == "ancient" then
		for i = 1, 4 do
			local angle = (i / 4) * math.pi * 2
			local plate = shard(
				model,
				CFrame.new(center + Vector3.new(math.cos(angle) * 5.5 * scale, 1.2 * scale, math.sin(angle) * 5.5 * scale))
					* CFrame.lookAt(Vector3.zero, Vector3.new(-math.cos(angle), 0, -math.sin(angle))).Rotation,
				Vector3.new(4.5, 5.5, 0.75) * scale,
				Color3.fromRGB(128, 93, 53),
				Enum.Material.Metal
			)
			plate.Name = "AncientPlate"
		end
		for i = 1, 3 do
			local ring = cylinder(
				model,
				"AncientRing",
				(7 + i * 1.2) * scale,
				0.45 * scale,
				center + Vector3.new(0, (i - 2) * 1.8 * scale, 0),
				meteor.core,
				Enum.Material.Metal
			)
			ring.CanCollide = false
		end
	elseif meteor.style == "cosmic" then
		for i = 1, 8 do
			local angle = (i / 8) * math.pi * 2
			local radius = (7 + (i % 2) * 2.5) * scale
			local orbit = shard(
				model,
				CFrame.new(center + Vector3.new(math.cos(angle) * radius, ((i % 3) - 1) * 2.4 * scale, math.sin(angle) * radius))
					* CFrame.Angles(math.rad(i * 19), angle, math.rad(i * 31)),
				Vector3.new(1.2, 3.5, 1.2) * scale,
				if i % 2 == 0 then meteor.core else Color3.fromRGB(75, 57, 61),
				if i % 2 == 0 then Enum.Material.Glass else Enum.Material.Slate
			)
			orbit.Name = "OrbitingShard"
		end
		local highlight = Instance.new("Highlight")
		highlight.FillTransparency = 0.9
		highlight.OutlineTransparency = 0.15
		highlight.OutlineColor = meteor.core
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = model
	end

	light(anchor, meteor.core, 0.8 + meteor.rarity * 0.32, 12 + meteor.rarity * 4)
	meteorParticles(anchor, meteor)
	return anchor
end

function World.spawnMeteor(id: string, position: Vector3, meteor: any): (Model, ProximityPrompt)
	assert(World.meteors, "World.build must run before spawnMeteor")
	local serial = tonumber(id) or 1
	local model = Instance.new("Model")
	model.Name = "Meteor_" .. id
	model:SetAttribute("MeteorId", id)
	model:SetAttribute("MeteorType", meteor.id)
	model:SetAttribute("MeteorName", meteor.name)
	model:SetAttribute("Rarity", meteor.rarity)
	model:SetAttribute("BurstMultiplier", meteor.burstMultiplier)
	model:SetAttribute("Claimed", false)
	model.Parent = World.meteors
	pcall(function() Mark.root(model, "meteor", meteor.id) end)

	local impact = cylinder(
		model,
		"ImpactScar",
		(16 + meteor.rarity * 3.5) * meteor.scale,
		0.45,
		position - Vector3.new(0, 1.65, 0),
		Color3.fromRGB(67, 57, 49),
		Enum.Material.Slate
	)
	impact.CanCollide = false

	for i = 1, 7 do
		local angle = (i / 7) * math.pi * 2
		local radius = (9 + meteor.rarity) * meteor.scale
		local debris = part(
			model,
			"Debris",
			Vector3.new(1.2 + (i % 3), 0.8 + (i % 2), 1.4 + ((i + 1) % 3)) * meteor.scale,
			CFrame.new(position + Vector3.new(math.cos(angle) * radius, -1.55, math.sin(angle) * radius))
				* CFrame.Angles(math.rad(i * 21), angle, math.rad(i * 13)),
			meteor.rock,
			Enum.Material.Rock
		)
		debris.CanCollide = false
	end

	local core = buildMeteorBody(model, position, meteor, serial)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CapturePrompt"
	prompt.ActionText = "Collect"
	prompt.ObjectText = meteor.name
	prompt.HoldDuration = math.clamp(0.18 + meteor.rarity * 0.045, 0.2, 0.48)
	prompt.MaxActivationDistance = Config.captureRadius
	prompt.RequiresLineOfSight = false
	prompt.Parent = core

	local rarity = Content.rarity(meteor.rarity)
	worldLabel(
		core,
		string.upper(rarity.name .. " • " .. meteor.name),
		rarity.color,
		if meteor.rarity == 1 then 34 elseif meteor.rarity == 2 then 42 elseif meteor.rarity == 3 then 54 elseif meteor.rarity == 4 then 68 elseif meteor.rarity == 5 then 90 else 110,
		Vector3.new(0, 5.4 * meteor.scale, 0)
	)
	return model, prompt
end

function World.attachCarriedCore(player: Player, meteor: any)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (character and root and root:IsA("BasePart")) then return end

	local old = character:FindFirstChild("CarriedMeteor")
	if old then old:Destroy() end

	local carrier = Instance.new("Model")
	carrier.Name = "CarriedMeteor"
	carrier.Parent = character

	local scale = math.clamp(0.78 + meteor.rarity * 0.08, 0.86, 1.22)
	local chunk = Instance.new("Part")
	chunk.Name = "Rock"
	chunk.Shape = Enum.PartType.Ball
	chunk.Size = Vector3.new(4.2, 3.6, 4) * scale
	chunk.Material = if meteor.style == "iron" then Enum.Material.Metal else Enum.Material.Rock
	chunk.Color = meteor.rock
	chunk.CanCollide = false
	chunk.Massless = true
	chunk.CFrame = root.CFrame * CFrame.new(0, 2.6, 3)
	chunk.Parent = carrier

	local core = Instance.new("Part")
	core.Name = "Glow"
	core.Shape = Enum.PartType.Ball
	core.Size = Vector3.new(1.4, 1.4, 1.4) * scale
	core.Material = Enum.Material.Glass
	core.Color = meteor.core
	core.CanCollide = false
	core.Massless = true
	core.CFrame = chunk.CFrame * CFrame.new(1.1, 0.5, -1.25)
	core.Parent = carrier
	light(core, meteor.core, 0.65 + meteor.rarity * 0.12, 8 + meteor.rarity)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = chunk
	weld.Parent = chunk

	local weldCore = Instance.new("WeldConstraint")
	weldCore.Part0 = chunk
	weldCore.Part1 = core
	weldCore.Parent = core

	if meteor.style == "crystal" or meteor.style == "cosmic" then
		for i = 1, 3 do
			local angle = (i / 3) * math.pi * 2
			local crystal = Instance.new("Part")
			crystal.Name = "CarryShard"
			crystal.Size = Vector3.new(0.5, 2.1, 0.5) * scale
			crystal.Material = Enum.Material.Glass
			crystal.Color = meteor.core
			crystal.CanCollide = false
			crystal.Massless = true
			crystal.CFrame = chunk.CFrame
				* CFrame.new(math.cos(angle) * 1.7, 1.4, math.sin(angle) * 1.7)
				* CFrame.Angles(math.rad(-20), -angle, 0)
			crystal.Parent = carrier
			local w = Instance.new("WeldConstraint")
			w.Part0 = chunk
			w.Part1 = crystal
			w.Parent = crystal
		end
	end
end

function World.clearCarriedCore(player: Player)
	local character = player.Character
	local carried = character and character:FindFirstChild("CarriedMeteor")
	if carried then carried:Destroy() end
end

local function specimenFigure(parent: Instance, cf: CFrame, id: string, color: Color3): Model
	local model = Instance.new("Model")
	model.Name = id

	local function piece(name: string, size: Vector3, localCf: CFrame, material: Enum.Material?): Part
		local p = part(model, name, size, cf * localCf, color, material or Enum.Material.SmoothPlastic)
		p.CanCollide = false
		return p
	end

	if id == "moon-pebble" then
		local body = piece("Body", Vector3.new(4.3, 3.1, 4.6), CFrame.new(), Enum.Material.Rock)
		body.Shape = Enum.PartType.Ball
	elseif id == "spark-mite" then
		local body = piece("Body", Vector3.new(3.4, 2.2, 3.8), CFrame.new(), Enum.Material.SmoothPlastic)
		body.Shape = Enum.PartType.Ball
		for x = -1, 1, 2 do
			for z = -0.9, 0.9, 1.8 do
				piece("Leg", Vector3.new(0.4, 1.7, 0.4), CFrame.new(x * 1.7, -1, z) * CFrame.Angles(0, 0, math.rad(x * 24)), Enum.Material.Wood)
			end
		end
	elseif id == "comet-pup" then
		local body = piece("Body", Vector3.new(4.6, 2.8, 5.4), CFrame.new(0, 0, 0.4), Enum.Material.SmoothPlastic)
		body.Shape = Enum.PartType.Ball
		local head = piece("Head", Vector3.new(2.9, 2.9, 2.9), CFrame.new(0, 1, -2.6), Enum.Material.SmoothPlastic)
		head.Shape = Enum.PartType.Ball
		piece("EarL", Vector3.new(0.8, 1.8, 0.8), CFrame.new(-0.9, 2.5, -2.6), Enum.Material.SmoothPlastic)
		piece("EarR", Vector3.new(0.8, 1.8, 0.8), CFrame.new(0.9, 2.5, -2.6), Enum.Material.SmoothPlastic)
	elseif id == "orbit-owl" then
		local body = piece("Body", Vector3.new(4, 5, 3.8), CFrame.new(), Enum.Material.SmoothPlastic)
		body.Shape = Enum.PartType.Ball
		for x = -1, 1, 2 do
			local eye = piece("Eye", Vector3.new(0.8, 0.8, 0.45), CFrame.new(x * 0.9, 0.9, -1.8), Enum.Material.Glass)
			eye.Color = Content.palette.gold
		end
	elseif id == "solar-fox" then
		local body = piece("Body", Vector3.new(4.5, 2.8, 5.1), CFrame.new(), Enum.Material.SmoothPlastic)
		body.Shape = Enum.PartType.Ball
		local head = piece("Head", Vector3.new(3.1, 2.8, 3), CFrame.new(0, 1, -2.6), Enum.Material.SmoothPlastic)
		head.Shape = Enum.PartType.Ball
		piece("Tail", Vector3.new(1.7, 1.7, 5.2), CFrame.new(2, 0.6, 2.8) * CFrame.Angles(math.rad(-15), math.rad(25), 0), Enum.Material.SmoothPlastic)
	elseif id == "nova-whale" then
		local body = piece("Body", Vector3.new(6.2, 3.4, 3.7), CFrame.new(), Enum.Material.SmoothPlastic)
		body.Shape = Enum.PartType.Ball
		piece("TailL", Vector3.new(2.4, 0.7, 2), CFrame.new(3.7, 0, 1) * CFrame.Angles(0, 0, math.rad(22)), Enum.Material.SmoothPlastic)
		piece("TailR", Vector3.new(2.4, 0.7, 2), CFrame.new(3.7, 0, -1) * CFrame.Angles(0, 0, math.rad(-22)), Enum.Material.SmoothPlastic)
	else
		local body = piece("Body", Vector3.new(4.6, 4.6, 4.6), CFrame.new(), Enum.Material.SmoothPlastic)
		body.Shape = Enum.PartType.Ball
		for i = 1, 4 do
			piece("Ring", Vector3.new(0.4, 5.8, 0.4), CFrame.Angles(0, 0, math.rad(i * 45)), Enum.Material.Metal)
		end
	end

	model.Parent = parent
	return model
end

function World.renderSpecimens(player: Player, specimens: { any })
	local base = World.byPlayer[player]
	if not base then return end
	base.displays:ClearAllChildren()

	local pads = {}
	for _, child in base.model:GetChildren() do
		if child:IsA("BasePart") and child.Name == "DisplayPad" then
			table.insert(pads, child)
		end
	end
	table.sort(pads, function(a, b)
		return (a:GetAttribute("Slot") or 0) < (b:GetAttribute("Slot") or 0)
	end)

	for index, entry in specimens do
		local pad = pads[index]
		if not pad then break end
		local specimen = Content.specimen(tostring(entry.id))
		if specimen then
			local rarity = Content.rarity(specimen.rarity)
			local color = if entry.mutation == "radiant"
				then Color3.fromRGB(244, 219, 147)
				elseif entry.mutation == "void"
				then Color3.fromRGB(116, 69, 81)
				else rarity.color
			local figure = specimenFigure(base.displays, pad.CFrame * CFrame.new(0, 4, 0), specimen.id, color)
			local anchor = figure:FindFirstChildWhichIsA("BasePart", true)
			if anchor then
				worldLabel(
					anchor,
					specimen.name .. (if entry.mutation and entry.mutation ~= "" then " • " .. string.upper(entry.mutation) else ""),
					Content.palette.cream,
					34,
					Vector3.new(0, 4, 0)
				)
			end
		end
	end
end

Players.PlayerRemoving:Connect(function(player)
	World.release(player)
end)

return World
