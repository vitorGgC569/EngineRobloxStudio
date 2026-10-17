--!strict
--[[
	Shrine — the AURA RIFT courtyard, built over the numbers in WorldSpec.

	Structure and presentation only. Systems read `Shrine.stations()` for the
	parts and find each ProximityPrompt by the name WorldSpec.prompts declares;
	that string is the client contract, so prompt names are applied in one
	helper rather than typed at five call sites. `build` is idempotent: a
	second call returns the first call's stations without touching the world.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local WorldSpec = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WorldSpec"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local WorldKit = ReplicatedStorage:WaitForChild("WorldKit")
local Palette = require(WorldKit.Palette)
local Build = require(WorldKit.Build)
local Props = require(WorldKit.Props)
local Interact = require(WorldKit.Interact)
local Sky = require(WorldKit.Sky)
local Tokens = require(WorldKit.Tokens)

local Rng = Forge.Core.Rng
local Debug = Forge.Debug

export type Stations = {
	altar: BasePart,
	tower: BasePart,
	dojo: BasePart,
	ascend: BasePart,
	ranks: BasePart,
	spawn: SpawnLocation,
}

local Shrine = {}
local swatches = Palette.BrickFarm.swatches

local SHRINE_FOLDER = "Shrine"
local TREE_COUNT = 12
local EDGE = WorldSpec.plazaSize.X * 0.5
local PROMPT_RANGE = 18
local LABEL_DISTANCE = 70

local built: Stations? = nil
local shrineWorld: Folder? = nil

--- Interact.prompt calls its instance "RQEPrompt"; the client keys on the
--- WorldSpec name instead, so the rename is what makes the station work.
local function stationPrompt(part: BasePart, name: string, objectText: string, actionText: string): ProximityPrompt
	local existing = part:FindFirstChild(name)
	if existing and existing:IsA("ProximityPrompt") then
		return existing
	end
	local prompt = Interact.prompt(part, {
		label = objectText,
		action = actionText,
		range = PROMPT_RANGE,
		holdTime = 0,
	})
	prompt.Name = name
	return prompt
end

--- maxDistance is passed on purpose: a label without one draws from across
--- the map and five of them bury the skyline.
local function stationLabel(part: BasePart, text: string, rise: number): BillboardGui
	return Interact.label(part, {
		text = text,
		rise = rise,
		size = 3,
		colour = swatches.white.color,
		maxDistance = LABEL_DISTANCE,
	})
end

--- Prop roles, derived from the same BrickFarm swatches the geometry uses:
--- aurarift has no TokenData module, and WorldKit props demand a TokenSet,
--- so hand-copying colours here would drift from the palette immediately.
local function roleDefinition(swatchKey: string, tier: string, usage: string): { [string]: any }
	local source = swatches[swatchKey]
	return {
		tier = tier,
		srgb = {
			math.round(source.color.R * 255),
			math.round(source.color.G * 255),
			math.round(source.color.B * 255),
		},
		material = source.material.Name,
		usage = usage,
	}
end

local function propTokens(): any
	local ok, result = pcall(Tokens.define, {
		schemaVersion = 1,
		tokenSetId = "aurarift.world",
		revision = 1,
		description = "BrickFarm palette re-expressed as tokens so WorldKit props match the shrine.",
		palette = {
			roles = {
				woodPrimary = roleDefinition("wood", "supporting", "Timber: crates and barrels"),
				woodSecondary = roleDefinition("woodDark", "supporting", "Timber shade and banner poles"),
				metalDark = roleDefinition("metalDark", "supporting", "Lamp posts and barrel hoops"),
				accentGold = roleDefinition("gold", "accent", "Lamp glow and finials"),
				accentDanger = roleDefinition("red", "accent", "Banner cloth"),
				stonePrimary = roleDefinition("rock", "dominant", "Rock clusters"),
				stoneSecondary = roleDefinition("rockDark", "supporting", "Rock shade"),
				vegetationBark = roleDefinition("bark", "supporting", "Tree trunks"),
				vegetationLeaf = roleDefinition("leaf", "dominant", "Canopy mass"),
				vegetationLeafDark = roleDefinition("leafDark", "supporting", "Ground cover"),
				accentPink = roleDefinition("pink", "accent", "Sakura canopy"),
			},
		},
		scale = {
			character = { maxStepUp = 2, height = 5 },
			grammar = { stairRise = 0.5, doorHeight = 7, ceilingHeight = 10 },
			legibility = { promptRange = PROMPT_RANGE, labelDistance = LABEL_DISTANCE },
		},
		spacing = { steps = { xs = 4, sm = 8, md = 16, lg = 32, xl = 64 } },
		typography = { steps = { caption = 14, body = 18, title = 32 }, weights = { regular = "Regular", bold = "Bold" } },
		motion = { durations = { quick = 0.15, calm = 0.4 }, easings = { calm = { style = "Sine", direction = "InOut" } } },
		moods = { goldenHour = { description = "Shrine courtyard at golden hour" } },
		cameras = { overview = { fieldOfView = 70 } },
		audio = { buses = { world = { volume = 0.6 } }, spatial = { falloff = 60 } },
	})
	if not ok then
		Debug.warn(string.format("[Shrine] prop dressing skipped, tokens unavailable: %s", tostring(result)))
		return nil
	end
	return result
end

--- A prop failure costs one prop, not the courtyard.
local function attempt(what: string, work: () -> ())
	local ok, err = pcall(work)
	if not ok then
		Debug.warn(string.format("[Shrine] %s failed: %s", what, tostring(err)))
	end
end

local EXCLUSIONS: { { x: number, z: number, radius: number } } = {
	{ x = 0, z = 0, radius = 26 }, -- altar court
	{ x = 0, z = -102, radius = 20 }, -- torii gate
	{ x = 74, z = -30, radius = 26 }, -- tower
	{ x = -74, z = -30, radius = 34 }, -- dojo
	{ x = 0, z = 68, radius = 30 }, -- ascension shrine
	{ x = 46, z = -66, radius = 18 }, -- ranks stone
	{ x = 0, z = -88, radius = 16 }, -- spawn pad
}

local function clearOfStations(x: number, z: number): boolean
	for _, zone in ipairs(EXCLUSIONS) do
		local dx, dz = x - zone.x, z - zone.z
		if dx * dx + dz * dz < zone.radius * zone.radius then
			return false
		end
	end
	-- The approach path and the spawn-to-gate walk stay open.
	if math.abs(x) < 13 and z > -96 and z < 74 then
		return false
	end
	return true
end

local function plantSakura(parent: Instance, tokens: any, stream: any)
	local placed: { { x: number, z: number } } = {}
	local tries = 0
	-- Rejection sampling with a hard bound: unbounded scatter hangs the build
	-- on an unlucky seed.
	while #placed < TREE_COUNT and tries < 900 do
		tries += 1
		local x = stream:number(-108, 108)
		local z = stream:number(-108, 108)
		local spacingOk = true
		for _, entry in ipairs(placed) do
			local dx, dz = x - entry.x, z - entry.z
			if dx * dx + dz * dz < 24 * 24 then
				spacingOk = false
				break
			end
		end
		if spacingOk and clearOfStations(x, z) then
			table.insert(placed, { x = x, z = z })
			Props.tree(parent, tokens, {
				position = Vector3.new(x, 0, z),
				rotation = stream:number(0, 360),
				scale = stream:number(0.6, 0.85),
				seed = stream:int(1, 1000000),
				secondary = "accentPink",
				accent = "accentPink",
			})
		end
	end
end

local EDGE_ACCENTS = {
	{ kind = "rock", x = -78, z = -116 },
	{ kind = "tuft", x = -38, z = -116 },
	{ kind = "rock", x = 36, z = -116 },
	{ kind = "tuft", x = 76, z = -116 },
	{ kind = "tuft", x = -116, z = -52 },
	{ kind = "rock", x = -116, z = 18 },
	{ kind = "rock", x = 116, z = -12 },
	{ kind = "tuft", x = 116, z = 44 },
	{ kind = "tuft", x = -16, z = 116 },
	{ kind = "rock", x = 28, z = 116 },
}

local function dressEdges(parent: Instance, tokens: any, stream: any)
	for _, spot in ipairs(EDGE_ACCENTS) do
		Props.build(spot.kind, parent, tokens, {
			position = Vector3.new(spot.x + stream:number(-2.5, 2.5), 0, spot.z + stream:number(-2.5, 2.5)),
			rotation = stream:number(0, 360),
			scale = if spot.kind == "rock" then stream:number(0.7, 1.1) else stream:number(1.1, 1.6),
			seed = stream:int(1, 1000000),
		})
	end
end

local function supplyProps(parent: Instance, tokens: any, stream: any)
	-- Deliveries staged behind the dojo: a working courtyard, not a diorama.
	Props.crate(parent, tokens, { position = Vector3.new(-54, 0, -40), rotation = stream:number(0, 360), scale = 0.9, seed = stream:int(1, 1000000) })
	Props.crate(parent, tokens, { position = Vector3.new(-50.5, 0, -43.5), rotation = stream:number(0, 360), scale = 0.7, seed = stream:int(1, 1000000) })
	Props.barrel(parent, tokens, { position = Vector3.new(-51, 0, -37), scale = 1, seed = stream:int(1, 1000000) })
end

local function wallRun(parent: Instance, name: string, centre: Vector3, length: number, alongX: boolean)
	local height = WorldSpec.wallHeight
	local body = if alongX then Vector3.new(length, height, 4) else Vector3.new(4, height, length)
	local base = if alongX then Vector3.new(length, 2.4, 5) else Vector3.new(5, 2.4, length)
	local cap = if alongX then Vector3.new(length, 1.6, 5.4) else Vector3.new(5.4, 1.6, length)
	Build.part(parent, name .. "Base", base, centre + Vector3.new(0, 1.2, 0), swatches.stoneDark)
	Build.part(parent, name, body, centre + Vector3.new(0, height * 0.5, 0), swatches.brick)
	Build.part(parent, name .. "Cap", cap, centre + Vector3.new(0, height + 0.8, 0), swatches.stone)
end

local function cornerTower(parent: Instance, index: number, x: number, z: number)
	local suffix = tostring(index)
	Build.cylinder(parent, "CornerBase" .. suffix, Vector3.new(16, 2.5, 16), Vector3.new(x, 1.25, z), swatches.stoneDark)
	Build.cylinder(parent, "CornerShaft" .. suffix, Vector3.new(11, 14, 11), Vector3.new(x, 9.5, z), swatches.brick)
	local cap = Build.part(parent, "CornerCap" .. suffix, Vector3.new(13, 2, 13), Vector3.new(x, 17.5, z), swatches.stone)
	local glow = Build.light(cap, swatches.gold.color, 2, 26)
	glow.Shadows = false
end

local function perimeter(parent: Instance)
	-- The north wall splits around the gate so the torii reads as a threshold.
	local gap = 17
	local segment = EDGE - gap
	wallRun(parent, "WallNorthEast", Vector3.new(gap + segment * 0.5, 0, -EDGE), segment, true)
	wallRun(parent, "WallNorthWest", Vector3.new(-(gap + segment * 0.5), 0, -EDGE), segment, true)
	wallRun(parent, "WallSouth", Vector3.new(0, 0, EDGE), EDGE * 2, true)
	wallRun(parent, "WallEast", Vector3.new(EDGE, 0, 0), EDGE * 2, false)
	wallRun(parent, "WallWest", Vector3.new(-EDGE, 0, 0), EDGE * 2, false)
	local corners = { { -EDGE, -EDGE }, { -EDGE, EDGE }, { EDGE, -EDGE }, { EDGE, EDGE } }
	for index, corner in ipairs(corners) do
		cornerTower(parent, index, corner[1], corner[2])
	end
end

local function plazaFloor(parent: Instance)
	Build.part(parent, "PlazaFloor", Vector3.new(WorldSpec.plazaSize.X, 2, WorldSpec.plazaSize.Z), Vector3.new(0, -1, 0), swatches.pavement)
	-- The court ring frames the altar. Z strips sit a hair lower than X strips
	-- so the corner overlaps never z-fight, and both sit under the path slabs.
	for _, offset in ipairs({ -32, 32 }) do
		local suffix = if offset < 0 then "North" else "South"
		Build.part(parent, "CourtRing" .. suffix .. "X", Vector3.new(64, 0.2, 2.4), Vector3.new(0, 0.1, offset), swatches.stone)
		local side = if offset < 0 then "West" else "East"
		Build.part(parent, "CourtRing" .. side .. "Z", Vector3.new(2.4, 0.2, 64), Vector3.new(offset, 0.09, 0), swatches.stone)
	end
	-- Gate to altar.
	for index = 1, 12 do
		local slab = if index % 2 == 0 then swatches.pathWhite else swatches.pavement
		Build.part(parent, string.format("Approach%02d", index), Vector3.new(8, 0.3, 5.2), Vector3.new(0, 0.15, -82 + (index - 1) * 6), slab)
	end
	-- Altar to ascension.
	for index = 1, 9 do
		local slab = if index % 2 == 0 then swatches.pathWhite else swatches.pavement
		Build.part(parent, string.format("Ascent%02d", index), Vector3.new(8, 0.3, 5.2), Vector3.new(0, 0.15, 14 + (index - 1) * 6), slab)
	end
end

local function toriiGate(parent: Instance): BasePart
	local centre = WorldSpec.gate
	Build.part(parent, "GateApproach", Vector3.new(30, 1, 10), centre + Vector3.new(0, 0.5, 0), swatches.stone)
	for _, side in ipairs({ -1, 1 }) do
		Build.pillar(parent, "GatePillar" .. tostring(side), centre + Vector3.new(side * 13, 1, 0), 24, 1.8, swatches.red, swatches.ink)
	end
	Build.part(parent, "GateNuki", Vector3.new(30, 1.8, 2.6), centre + Vector3.new(0, 25.2, 0), swatches.red)
	Build.part(parent, "GateGakuzuka", Vector3.new(2.4, 2.8, 2.4), centre + Vector3.new(0, 27.3, 0), swatches.ink)
	local kasagi = Build.part(parent, "GateKasagi", Vector3.new(36, 2.4, 4.6), centre + Vector3.new(0, 29.2, 0), swatches.ink)
	-- The plaza is at larger Z than the gate, and a part's Front face is -Z,
	-- so the face the player reads is Back.
	Interact.sign(kasagi, {
		text = Content.title .. "\n" .. Content.tagline,
		face = Enum.NormalId.Back,
		size = 0.85,
		colour = swatches.white.color,
		background = swatches.ink.color,
		transparency = 0.12,
	})
	return kasagi
end

--- A courtyard lantern from plain parts. Not Props.lamp: that one needs a
--- TokenSet, and a structural light should not blink out when tokens fail.
local function stoneLantern(parent: Instance, index: number, x: number, z: number)
	local suffix = tostring(index)
	Build.cylinder(parent, "LanternFoot" .. suffix, Vector3.new(3, 0.8, 3), Vector3.new(x, 0.4, z), swatches.stoneDark)
	Build.cylinder(parent, "LanternPost" .. suffix, Vector3.new(1.2, 6, 1.2), Vector3.new(x, 3.8, z), swatches.metalDark)
	local head = Build.part(parent, "LanternHead" .. suffix, Vector3.new(2.4, 2.2, 2.4), Vector3.new(x, 7.9, z), swatches.goldBright)
	head.Material = Enum.Material.Neon
	Build.part(parent, "LanternCap" .. suffix, Vector3.new(3.2, 0.7, 3.2), Vector3.new(x, 9.35, z), swatches.ink)
	local glow = Build.light(head, swatches.goldBright.color, 2.5, 24)
	glow.Shadows = false
end

local function altarCourt(parent: Instance): BasePart
	local centre = WorldSpec.altar
	Build.cylinder(parent, "AltarBase", Vector3.new(24, 1, 24), centre + Vector3.new(0, 0.5, 0), swatches.stoneDark)
	Build.cylinder(parent, "AltarMid", Vector3.new(18, 1, 18), centre + Vector3.new(0, 1.5, 0), swatches.stone)
	local top = Build.cylinder(parent, "AltarTop", Vector3.new(12, 1.6, 12), centre + Vector3.new(0, 2.8, 0), swatches.pavement)
	Build.cylinder(parent, "AltarPedestal", Vector3.new(4, 2.4, 4), centre + Vector3.new(0, 4.8, 0), swatches.metalDark)
	local crystal = Build.sphere(parent, "AuraCrystal", 5, centre + Vector3.new(0, 8.5, 0), swatches.pink, { transparency = 0.2, canCollide = false, castShadow = false })
	crystal.Material = Enum.Material.Neon
	local core = Build.sphere(parent, "AuraCore", 2.6, centre + Vector3.new(0, 8.5, 0), swatches.cyanBright, { canCollide = false, castShadow = false })
	core.Material = Enum.Material.Neon
	local glow = Build.light(crystal, swatches.pink.color, 4, 36)
	glow.Shadows = false
	local lampIndex = 0
	for _, dx in ipairs({ -13, 13 }) do
		for _, dz in ipairs({ -13, 13 }) do
			lampIndex += 1
			stoneLantern(parent, lampIndex, centre.X + dx, centre.Z + dz)
		end
	end
	stationPrompt(top, WorldSpec.prompts.altar, "Summon Altar", "Summon")
	stationLabel(crystal, "SUMMON ALTAR", 2.5)
	return top
end

local function auraTower(parent: Instance): BasePart
	local centre = WorldSpec.tower
	local l1 = Build.cylinder(parent, "TowerL1", Vector3.new(20, 10, 20), centre + Vector3.new(0, 5, 0), swatches.brick)
	Build.cylinder(parent, "TowerEave1", Vector3.new(23, 0.8, 23), centre + Vector3.new(0, 10.4, 0), swatches.slate)
	Build.cylinder(parent, "TowerL2", Vector3.new(16, 9, 16), centre + Vector3.new(0, 15.3, 0), swatches.brickDark)
	Build.cylinder(parent, "TowerEave2", Vector3.new(19, 0.8, 19), centre + Vector3.new(0, 20.2, 0), swatches.slate)
	Build.cylinder(parent, "TowerL3", Vector3.new(12, 8, 12), centre + Vector3.new(0, 24.6, 0), swatches.brick)
	Build.cylinder(parent, "TowerEave3", Vector3.new(15, 0.8, 15), centre + Vector3.new(0, 29, 0), swatches.slate)
	Build.cylinder(parent, "TowerSpire", Vector3.new(6, 6, 6), centre + Vector3.new(0, 32.4, 0), swatches.slate)
	local finial = Build.sphere(parent, "TowerFinial", 4, centre + Vector3.new(0, 37.4, 0), swatches.cyanBright, { canCollide = false, castShadow = false })
	finial.Material = Enum.Material.Neon
	local glow = Build.light(finial, swatches.cyanBright.color, 4, 40)
	glow.Shadows = false
	stationPrompt(l1, WorldSpec.prompts.tower, "Aura Tower", "Challenge")
	stationLabel(finial, "AURA TOWER", 2)
	return l1
end

local function summonDojo(parent: Instance): BasePart
	local centre = WorldSpec.dojo
	local hall = Build.part(parent, "DojoHall", Vector3.new(28, 12, 20), centre + Vector3.new(0, 6, 0), swatches.wood)
	-- Two opposed wedges make the gable: WedgePart tapers toward -Z, so the
	-- north half runs unrotated (tall face at the ridge) and the south half
	-- is turned to face it.
	Build.wedge(parent, "DojoRoofNorth", Vector3.new(30, 5, 11), CFrame.new(centre + Vector3.new(0, 14.5, -5)), swatches.slate)
	Build.wedge(parent, "DojoRoofSouth", Vector3.new(30, 5, 11), CFrame.new(centre + Vector3.new(0, 14.5, 5)) * CFrame.Angles(0, math.pi, 0), swatches.slate)
	Build.part(parent, "DojoRidge", Vector3.new(31, 0.9, 1.6), centre + Vector3.new(0, 17.4, 0), swatches.ink)
	for _, dx in ipairs({ -14.6, 14.6 }) do
		for _, dz in ipairs({ -10.6, 10.6 }) do
			Build.pillar(parent, "DojoPillar", centre + Vector3.new(dx, 0, dz), 12, 1.1, swatches.stone, swatches.slate)
		end
	end
	Build.part(parent, "DojoStep", Vector3.new(6, 0.8, 8), centre + Vector3.new(16.5, 0.4, 0), swatches.stone)
	Interact.sign(hall, {
		text = "SUMMON DOJO",
		face = Enum.NormalId.Right,
		size = 1.4,
		colour = swatches.pathWhite.color,
		background = swatches.woodDark.color,
		transparency = 0.1,
	})
	stationPrompt(hall, WorldSpec.prompts.dojo, "Summon Dojo", "Upgrades")
	stationLabel(hall, "SUMMON DOJO", 2)
	return hall
end

local function ascensionShrine(parent: Instance): BasePart
	local centre = WorldSpec.ascend
	Build.part(parent, "AscendBase", Vector3.new(36, 1.2, 36), centre + Vector3.new(0, 0.6, 0), swatches.stoneDark)
	Build.part(parent, "AscendMid", Vector3.new(26, 1.2, 26), centre + Vector3.new(0, 1.8, 0), swatches.stone)
	local top = Build.part(parent, "AscendTop", Vector3.new(18, 1.5, 18), centre + Vector3.new(0, 3.15, 0), swatches.gold)
	for _, dx in ipairs({ -7, 7 }) do
		for _, dz in ipairs({ -7, 7 }) do
			Build.pillar(parent, "AscendPillar", centre + Vector3.new(dx, 3.9, dz), 10, 0.9, swatches.stone, swatches.gold)
		end
	end
	local orb = Build.sphere(parent, "AscendOrb", 5, centre + Vector3.new(0, 18.5, 0), swatches.goldBright, { canCollide = false, castShadow = false })
	orb.Material = Enum.Material.Neon
	local glow = Build.light(orb, swatches.goldBright.color, 4, 40)
	glow.Shadows = false
	stationPrompt(top, WorldSpec.prompts.ascend, "Ascension Altar", "Ascend")
	stationLabel(orb, "ASCENSION", 2.5)
	return top
end

local function ranksStone(parent: Instance): BasePart
	local centre = WorldSpec.ranks
	Build.cylinder(parent, "RanksRing", Vector3.new(10, 0.8, 10), centre + Vector3.new(0, 0.4, 0), swatches.cyan)
	local body = Build.cylinder(parent, "RanksBody", Vector3.new(8, 5, 8), centre + Vector3.new(0, 3.3, 0), swatches.slate)
	Build.cylinder(parent, "RanksBand", Vector3.new(6, 5, 6), centre + Vector3.new(0, 8.3, 0), swatches.cyan)
	Build.cylinder(parent, "RanksHead", Vector3.new(4, 6, 4), centre + Vector3.new(0, 13.8, 0), swatches.slate)
	local tip = Build.sphere(parent, "RanksTip", 3, centre + Vector3.new(0, 18.3, 0), swatches.pink, { canCollide = false, castShadow = false })
	tip.Material = Enum.Material.Neon
	local glow = Build.light(tip, swatches.pink.color, 3, 30)
	glow.Shadows = false
	stationPrompt(body, WorldSpec.prompts.ranks, "Rankings", "View")
	stationLabel(tip, "RANKINGS", 2)
	return body
end

local function spawnPad(parent: Instance): SpawnLocation
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "ShrineSpawn"
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = CFrame.lookAt(WorldSpec.spawn, WorldSpec.spawnLookAt)
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.CanCollide = true
	spawn.Transparency = 0.55
	spawn.Material = swatches.pavement.material
	spawn.Color = swatches.pavement.color
	Build.cylinder(parent, "SpawnPad", Vector3.new(14, 1.5, 14), Vector3.new(WorldSpec.spawn.X, 0.75, WorldSpec.spawn.Z), swatches.stone)
	-- Rim tops stay below the path slab tops so the two never flicker.
	Build.cylinder(parent, "SpawnRim", Vector3.new(16, 0.2, 16), Vector3.new(WorldSpec.spawn.X, 0.1, WorldSpec.spawn.Z), swatches.gold)
	spawn.Parent = parent
	return spawn
end

--- Build the courtyard. Safe to call twice; the second call is a lookup.
function Shrine.build(parent: Instance?): Stations
	if built then
		return built
	end
	local host = parent
	if host == nil then
		host = workspace:FindFirstChild("World")
	end
	if host == nil then
		local created = Instance.new("Folder")
		created.Name = "World"
		created.Parent = workspace
		host = created
	end
	local stale = host:FindFirstChild(SHRINE_FOLDER)
	if stale then
		stale:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = SHRINE_FOLDER
	root.Parent = host
	root:SetAttribute("Palette", Palette.BrickFarm.name)

	Sky.apply(Sky.GoldenHour)
	local stream = Rng.stream("aurarift.world")
	local tokens = propTokens()

	plazaFloor(root)
	perimeter(root)
	toriiGate(root)
	local altar = altarCourt(root)
	local tower = auraTower(root)
	local dojo = summonDojo(root)
	local ascend = ascensionShrine(root)
	local ranks = ranksStone(root)
	local spawn = spawnPad(root)
	if tokens then
		attempt("sakura grove", function() plantSakura(root, tokens, stream) end)
		attempt("edge dressing", function() dressEdges(root, tokens, stream) end)
		attempt("supply props", function() supplyProps(root, tokens, stream) end)
	end

	built = { altar = altar, tower = tower, dojo = dojo, ascend = ascend, ranks = ranks, spawn = spawn }
	shrineWorld = root
	Debug.info(string.format("[Shrine] %s courtyard built: %d instances", Content.title, #root:GetDescendants()))
	return built
end

--- The interaction anchors, or nil before `build`.
function Shrine.stations(): Stations?
	return built
end

--- The folder the courtyard was built into, or nil before `build`.
function Shrine.world(): Folder?
	return shrineWorld
end

return Shrine
