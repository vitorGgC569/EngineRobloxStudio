--!strict
-- Miner's Ridge: world assembly.
--
-- Composed from WorldKit rather than from literal coordinates. The previous
-- build was 454 lines of hand-placed parts producing a 171x170 stud map with
-- four 38x36 plots -- measured, and it read as a diorama. Everything structural
-- here comes from the shared library, so the next game inherits the primitives
-- and this file stays about *this* map's composition.
--
-- Layout: a spawn plaza at the origin, a hub district holding the exchange and
-- the lift, then eight plots in two columns flanking a central avenue that runs
-- to the mine face at the far end.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local FarmCatalog = require(ReplicatedStorage.Shared.FarmCatalog)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local WorldKit = require(ServerScriptService.WorldKit)

local Build = WorldKit.Build
local Conveyor = WorldKit.Conveyor
local Grid = WorldKit.Grid
local Nature = WorldKit.Nature
local Palette = WorldKit.Palette
local Sky = WorldKit.Sky
local Semantics = WorldKit.Semantics

local MapService = {}

local THEME = Palette.BrickFarm
local function swatch(key: string)
	return Palette.get(THEME, key)
end

local WORLD = GameConfig.World
local AVENUE_WIDTH = 58
local HUB_Z = -150
local GROUND_Y = 0

--- Accents cycle so neighbouring plots stay visually distinct.
local PLOT_ACCENTS = { "gold", "cyan", "pink", "green", "orange", "purple", "red", "blueSign" }

local function plotLayout()
	return Grid.layout(
		#GameConfig.PlotNames,
		WORLD.plotSize,
		WORLD.plotGap,
		WORLD.gridOrigin,
		WORLD.centreAisle,
		2 -- two columns either side of the avenue
	)
end

-- ---------------------------------------------------------------- ground

local function buildGround(map: Folder, slots: { Grid.Slot })
	local minZ, maxZ = math.huge, -math.huge
	local maxX = 0
	for _, slot in ipairs(slots) do
		minZ = math.min(minZ, slot.min.Z)
		maxZ = math.max(maxZ, slot.max.Z)
		maxX = math.max(maxX, math.abs(slot.min.X), math.abs(slot.max.X))
	end

	local pad = WORLD.groundPadding
	local depth = (maxZ - minZ) + pad * 2 + 260
	local width = maxX * 2 + pad * 2
	local centre = Vector3.new(0, GROUND_Y, (minZ + maxZ) / 2 - 60)

	Build.part(map, "Ground", Vector3.new(width, 4, depth), centre - Vector3.new(0, 2, 0), swatch("ground"))
	Build.part(map, "GroundBed", Vector3.new(width + 60, 26, depth + 60), centre - Vector3.new(0, 17, 0), swatch("grassDark"), { castShadow = false })

	-- A rim of rock so the plateau reads as terrain rather than a floating slab.
	local rim = Instance.new("Model")
	rim.Name = "RidgeRim"
	rim.Parent = map
	local random = Random.new(4821)
	for side = -1, 1, 2 do
		for step = 0, 14 do
			local z = centre.Z - depth / 2 + (depth / 14) * step
			local x = side * (width / 2 + random:NextNumber(2, 16))
			local height = random:NextNumber(18, 46)
			local rock = Build.part(rim, "RimRock", Vector3.new(random:NextNumber(28, 58), height, random:NextNumber(28, 58)), Vector3.new(x, height / 2 - 8, z), swatch("rock"))
			rock.Orientation = Vector3.new(0, random:NextNumber(0, 360), 0)
		end
	end
	for _, z in ipairs({ centre.Z - depth / 2 - 10, centre.Z + depth / 2 + 10 }) do
		for step = -3, 3 do
			local height = random:NextNumber(22, 52)
			local rock = Build.part(rim, "RimRock", Vector3.new(random:NextNumber(40, 70), height, random:NextNumber(30, 50)), Vector3.new(step * (width / 7), height / 2 - 8, z), swatch("grassDark"))
			rock.Orientation = Vector3.new(0, random:NextNumber(0, 360), 0)
		end
	end

	return centre, width, depth
end

-- ------------------------------------------------------------ spawn plaza

local function buildSpawnPlaza(map: Folder): SpawnLocation
	local plaza = Instance.new("Model")
	plaza.Name = "SpawnPlaza"
	plaza.Parent = map
	Semantics.root(plaza, "building", "spawn-plaza", "world.spawn-plaza")

	local centre = Vector3.new(0, GROUND_Y, 0)

	Build.cylinder(plaza, "PlazaDeck", Vector3.new(150, 2.4, 150), centre + Vector3.new(0, 1.2, 0), swatch("pathWhite"))
	Build.cylinder(plaza, "PlazaInlay", Vector3.new(118, 0.5, 118), centre + Vector3.new(0, 2.6, 0), swatch("brick"), { castShadow = false })
	Build.cylinder(plaza, "PlazaMedallion", Vector3.new(74, 0.4, 74), centre + Vector3.new(0, 2.95, 0), swatch("ink"), { castShadow = false })
	Build.cylinder(plaza, "PlazaRing", Vector3.new(56, 0.5, 56), centre + Vector3.new(0, 3.2, 0), swatch("orange"), { castShadow = false })
	Build.cylinder(plaza, "PlazaCore", Vector3.new(26, 0.6, 26), centre + Vector3.new(0, 3.4, 0), swatch("ore"), { transparency = 0.15, canCollide = false, castShadow = false })

	-- A landmark tall enough to navigate by from anywhere on the map.
	local beacon = Instance.new("Model")
	beacon.Name = "RidgeBeacon"
	beacon.Parent = plaza
	Semantics.landmark(beacon, "spawn")
	Build.cylinder(beacon, "BeaconBase", Vector3.new(34, 5, 34), centre + Vector3.new(0, 5.5, 0), swatch("stoneDark"))
	Build.cylinder(beacon, "BeaconColumn", Vector3.new(15, 78, 15), centre + Vector3.new(0, 47, 0), swatch("metal"))
	for ring = 1, 4 do
		Build.cylinder(beacon, "BeaconRing" .. ring, Vector3.new(19, 1.6, 19), centre + Vector3.new(0, 16 + ring * 17, 0), swatch("stone"), { castShadow = false })
	end
	local crystal = Build.sphere(beacon, "BeaconCrystal", 20, centre + Vector3.new(0, 92, 0), swatch("ore"), { transparency = 0.08, castShadow = false })
	Semantics.anchor(beacon, "spawn", centre + Vector3.new(0, 92, 0))
	Semantics.anchor(beacon, "spawn", centre + Vector3.new(0, 68, 0))
	Build.light(crystal, swatch("cyan").color, 2, 90)
	Build.billboard(crystal, "MINER'S RIDGE", swatch("gold").color, 460, 90, 22, 58, 900)

	for index = 1, 8 do
		local angle = (index / 8) * math.pi * 2
		local at = centre + Vector3.new(math.cos(angle) * 64, 0, math.sin(angle) * 64)
		Build.pillar(plaza, "PlazaPillar" .. index, at + Vector3.new(0, 2.4, 0), 16, 2.6, swatch("stone"), swatch("orange"))
		local lamp = Build.sphere(plaza, "PlazaLamp" .. index, 3.4, at + Vector3.new(0, 21, 0), swatch("gold"), { castShadow = false })
	end

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "SpawnPad"
	spawn.Size = Vector3.new(26, 1.2, 26)
	spawn.Position = centre + Vector3.new(0, 3.6, 34)
	spawn.Anchored = true
	spawn.Color = swatch("teal").color
	spawn.Material = Enum.Material.Neon
	spawn.Transparency = 0.15
	spawn.CanCollide = true
	spawn.Duration = 0
	spawn.Parent = plaza

	return spawn
end

-- --------------------------------------------------------------- avenue

local function buildAvenue(map: Folder, fromZ: number, toZ: number)
	local avenue = Instance.new("Model")
	avenue.Name = "MainAvenue"
	avenue.Parent = map

	Build.road(avenue, "Roadbed", Vector3.new(0, GROUND_Y, fromZ), Vector3.new(0, GROUND_Y, toZ), AVENUE_WIDTH, swatch("pathRed"), 0.4)
	for side = -1, 1, 2 do
		Build.road(avenue, "Kerb", Vector3.new(side * (AVENUE_WIDTH / 2 + 1.5), GROUND_Y, fromZ), Vector3.new(side * (AVENUE_WIDTH / 2 + 1.5), GROUND_Y, toZ), 3.4, swatch("stone"), 0.7)
		Build.road(avenue, "GuideLine", Vector3.new(side * (AVENUE_WIDTH / 2 - 4), GROUND_Y, fromZ), Vector3.new(side * (AVENUE_WIDTH / 2 - 4), GROUND_Y, toZ), 0.9, swatch("pathTrim"), 0.75)
	end

	local lamps = math.floor(math.abs(toZ - fromZ) / 62)
	for index = 0, lamps do
		local z = fromZ + (toZ - fromZ) * (index / math.max(lamps, 1))
		for side = -1, 1, 2 do
			local base = Vector3.new(side * (AVENUE_WIDTH / 2 + 5), GROUND_Y, z)
			Build.cylinder(avenue, "LampPost", Vector3.new(1.6, 22, 1.6), base + Vector3.new(0, 11, 0), swatch("stoneDark"))
			Build.part(avenue, "LampArm", Vector3.new(6, 0.9, 0.9), base + Vector3.new(-side * 3, 22, 0), swatch("stoneDark"), { castShadow = false })
			local head = Build.part(avenue, "LampHead", Vector3.new(3.4, 1.4, 3.4), base + Vector3.new(-side * 5.5, 21.2, 0), swatch("gold"), { canCollide = false, castShadow = false })
		end
	end
end

-- ------------------------------------------------------------ hub district

local function buildExchange(map: Folder): ProximityPrompt
	local store = Instance.new("Model")
	store.Name = "BasicPackStore"
	store.Parent = map
	Semantics.landmark(store, "shop")

	local origin = Vector3.new(-118, GROUND_Y, HUB_Z)

	Build.part(store, "Forecourt", Vector3.new(112, 1.4, 96), origin + Vector3.new(0, 0.7, 0), swatch("pathWhite"))
	local hall = Build.building(store, "Hall", {
		size = Vector3.new(86, 34, 62),
		wallSwatch = swatch("brick"),
		trimSwatch = swatch("stoneDark"),
		glassSwatch = swatch("glass"),
		roofSwatch = swatch("orange"),
		doorWidth = 18,
		doorFacing = "+X",
	}, origin + Vector3.new(-8, 1.4, 0))
	Semantics.root(hall, "building", "ridge-exchange", "world.ridge-exchange")
	Semantics.anchor(store, "shop", origin + Vector3.new(34, 9, 0))
	Semantics.anchor(store, "shop", origin + Vector3.new(-8, 46, -32))

	local sign = Build.part(store, "StoreSign", Vector3.new(52, 9, 1.4), origin + Vector3.new(-8, 46, -32), swatch("ink"), { canCollide = false })
	Build.billboard(sign, "RIDGE EXCHANGE", swatch("gold").color, 420, 80, 8, 54, 260)
	Build.part(store, "SignGlow", Vector3.new(50, 0.8, 0.8), origin + Vector3.new(-8, 41, -32), swatch("gold"), { canCollide = false, castShadow = false })

	local counter = Build.part(store, "Counter", Vector3.new(22, 6, 9), origin + Vector3.new(34, 4.4, 0), swatch("wood"))
	Semantics.root(counter, "interactive", "shop-counter", "interaction.purchase.basic-pack")
	Build.part(store, "CounterTop", Vector3.new(24, 0.9, 11), origin + Vector3.new(34, 7.7, 0), swatch("wood"), { castShadow = false })
	local glow = Build.part(store, "CounterGlow", Vector3.new(20, 0.4, 0.6), origin + Vector3.new(34, 8.2, -5), swatch("ore"), { canCollide = false, castShadow = false })

	for index, offset in ipairs({ Vector3.new(28, 0, -26), Vector3.new(28, 0, 26) }) do
		Build.pillar(store, "StorePillar" .. index, origin + offset + Vector3.new(0, 1.4, 0), 26, 2.4, swatch("stone"), swatch("orange"))
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PurchasePrompt"
	prompt.ActionText = "Buy mining pack"
	prompt.ObjectText = string.format("Basic Pack - $%d", GameConfig.BasicPackPrice)
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt.Parent = counter

	return prompt
end

local function buildLift(map: Folder): ProximityPrompt
	local lift = Instance.new("Model")
	lift.Name = "FloorLift"
	lift.Parent = map
	Semantics.root(lift, "building", "ridge-lift", "world.ridge-lift")

	local origin = Vector3.new(118, GROUND_Y, HUB_Z)

	Build.part(lift, "Pad", Vector3.new(96, 1.4, 96), origin + Vector3.new(0, 0.7, 0), swatch("pathWhite"))
	Build.part(lift, "Shaft", Vector3.new(34, 74, 34), origin + Vector3.new(6, 38, 0), swatch("stoneDark"))
	for ring = 1, 5 do
		Build.part(lift, "ShaftBand" .. ring, Vector3.new(37, 1.6, 37), origin + Vector3.new(6, 8 + ring * 13, 0), swatch("orange"), { castShadow = false })
	end
	local cage = Build.part(lift, "Cage", Vector3.new(24, 22, 24), origin + Vector3.new(6, 14, 0), swatch("teal"), { transparency = 0.55, castShadow = false })

	local terminal = Build.part(lift, "FloorTerminal", Vector3.new(12, 8, 6), origin + Vector3.new(-26, 5.4, 0), swatch("brick"))
	Semantics.root(terminal, "interactive", "floor-terminal", "interaction.floor.purchase")
	Build.part(lift, "TerminalScreen", Vector3.new(10, 5, 0.5), origin + Vector3.new(-26, 6.4, -3.2), swatch("ore"), { canCollide = false, castShadow = false })

	local sign = Build.part(lift, "LiftSign", Vector3.new(40, 8, 1.4), origin + Vector3.new(6, 84, 0), swatch("ink"), { canCollide = false })
	Build.billboard(sign, "RIDGE LIFT", swatch("teal").color, 360, 70, 7, 50, 260)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PurchaseFloorPrompt"
	prompt.ActionText = "Buy next floor"
	prompt.ObjectText = "Ridge Lift"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt.Parent = terminal

	return prompt
end

local function buildMineFace(map: Folder, z: number)
	local mine = Instance.new("Model")
	mine.Name = "OldLanternMine"
	mine.Parent = map
	Semantics.root(mine, "building", "old-lantern-mine", "world.old-lantern-mine")
	Semantics.region(mine, "mine", "mine")
	Semantics.landmark(mine, "mine")

	local origin = Vector3.new(0, GROUND_Y, z)
	local random = Random.new(99)

	for index = 1, 9 do
		local height = random:NextNumber(50, 105)
		local width = random:NextNumber(50, 92)
		local x = (index - 5) * 62 + random:NextNumber(-12, 12)
		local rock = Build.part(mine, "CliffBlock" .. index, Vector3.new(width, height, random:NextNumber(50, 80)), origin + Vector3.new(x, height / 2 - 6, random:NextNumber(-14, 14)), if index % 2 == 0 then swatch("rock") else swatch("grassDark"))
		rock.Orientation = Vector3.new(0, random:NextNumber(-14, 14), 0)
	end

	Build.part(mine, "Portal", Vector3.new(40, 34, 14), origin + Vector3.new(0, 17, -26), swatch("ink"))
	Build.part(mine, "PortalMouth", Vector3.new(30, 26, 4), origin + Vector3.new(0, 14, -33), swatch("ink"), { transparency = 0.25, canCollide = false })
	for side = -1, 1, 2 do
		Build.part(mine, "PortalBeam", Vector3.new(5, 36, 5), origin + Vector3.new(side * 21, 18, -33), swatch("wood"))
	end
	Build.part(mine, "PortalLintel", Vector3.new(50, 5, 7), origin + Vector3.new(0, 37, -33), swatch("wood"))
	local lantern = Build.sphere(mine, "PortalLantern", 5, origin + Vector3.new(0, 32, -37), swatch("gold"), { castShadow = false })
	Semantics.anchor(mine, "mine", origin + Vector3.new(0, 32, -37))
	Semantics.anchor(mine, "mine", origin + Vector3.new(0, 50, -20))
	Build.billboard(lantern, "OLD LANTERN MINE", swatch("white").color, 400, 70, 12, 46, 400)

	-- Ore seams glinting in the rock face give the wall depth and a reason to look.
	for index = 1, 14 do
		local at = origin + Vector3.new(random:NextNumber(-230, 230), random:NextNumber(8, 60), random:NextNumber(-24, -4))
		local seam = Build.part(mine, "OreSeam" .. index, Vector3.new(random:NextNumber(4, 11), random:NextNumber(3, 7), 3), at, swatch("ore"), { transparency = 0.15, canCollide = false, castShadow = false })
	end
end

-- ----------------------------------------------------------------- plots

--- How many card slots each deck carries. Buying a floor is what unlocks the
--- next ten, which ties the two progression systems into one readable shape:
--- a taller plot is literally a bigger farm.
local SLOTS_PER_FLOOR = 10

--- One deck: a floor plate, its pillars, and the card slots standing on it.
---
--- Open on every side. The reference builds upward as bare decks on columns,
--- and that is not only a style choice -- walls hide the cards, and the cards
--- are the thing a collector wants to look at.
function MapService.buildFloor(plot: Model, centre: Vector3, level: number, accentKey: string, slotsFolder: Folder?): Model
	local existing = plot:FindFirstChild("Floor" .. level)
	if existing then
		return existing :: Model
	end

	local accent = swatch(accentKey)
	local deckSize = 108
	local height = WORLD.floorHeight
	local deckY = centre.Y + (level - 1) * height

	local floor = Instance.new("Model")
	floor.Name = "Floor" .. level
	floor:SetAttribute("Level", level)
	floor.Parent = plot

	-- The deck.
	Build.part(floor, "Deck", Vector3.new(deckSize, 2, deckSize), Vector3.new(centre.X, deckY + 1, centre.Z), swatch("pathWhite"))
	Build.part(floor, "DeckTrim", Vector3.new(deckSize + 4, 0.8, deckSize + 4), Vector3.new(centre.X, deckY + 0.4, centre.Z), accent, { castShadow = false })

	-- Columns carrying the next deck. Corners plus mid-span, so a wide plate
	-- does not read as floating.
	local half = deckSize / 2 - 4
	for _, offset in ipairs({
		Vector3.new(-half, 0, -half), Vector3.new(half, 0, -half),
		Vector3.new(-half, 0, half), Vector3.new(half, 0, half),
		Vector3.new(0, 0, -half), Vector3.new(0, 0, half),
		Vector3.new(-half, 0, 0), Vector3.new(half, 0, 0),
	}) do
		Build.part(floor, "Column", Vector3.new(4, height, 4), Vector3.new(centre.X, deckY + height / 2 + 2, centre.Z) + offset, swatch("brick"))
	end

	-- A low kerb instead of walls: it reads as an edge without hiding anything.
	for _, edge in ipairs({
		{ Vector3.new(deckSize, 1.6, 2), Vector3.new(0, 0, -half - 2) },
		{ Vector3.new(deckSize, 1.6, 2), Vector3.new(0, 0, half + 2) },
		{ Vector3.new(2, 1.6, deckSize), Vector3.new(-half - 2, 0, 0) },
		{ Vector3.new(2, 1.6, deckSize), Vector3.new(half + 2, 0, 0) },
	}) do
		Build.part(floor, "Kerb", edge[1], Vector3.new(centre.X, deckY + 2.8, centre.Z) + edge[2], swatch("brickDark"), { castShadow = false })
	end

	local marker = Build.part(floor, "LevelMarker", Vector3.new(10, 1, 10), Vector3.new(centre.X - half, deckY + 2.6, centre.Z - half), accent, { canCollide = false, castShadow = false })
	Build.billboard(marker, "FLOOR " .. level, accent.color, 160, 36, 4, 26, 55)

	-- The slots this deck carries.
	if slotsFolder then
		local columns = 5
		local pitch = 20
		local firstIndex = (level - 1) * SLOTS_PER_FLOOR + 1
		local originX = centre.X - ((columns - 1) * pitch) / 2
		local originZ = centre.Z - pitch / 2

		for offset = 0, SLOTS_PER_FLOOR - 1 do
			local index = firstIndex + offset
			if index > FarmCatalog.MaxSlots then
				break
			end
			local column = offset % columns
			local row = math.floor(offset / columns)
			local at = Vector3.new(originX + column * pitch, deckY + 2.2, originZ + row * pitch)
			local unlocked = index <= FarmCatalog.StartingSlots

			local slotModel = Instance.new("Model")
			slotModel.Name = string.format("Slot%02d", index)
			slotModel:SetAttribute("SlotIndex", index)
			slotModel:SetAttribute("Unlocked", unlocked)
			slotModel:SetAttribute("Floor", level)
			slotModel.Parent = slotsFolder

			-- A recessed pad the card stands on. Flat and quiet when empty: a
			-- plot full of glowing empty holders is what made the farm look
			-- broken rather than unbuilt.
			local pad = Build.part(slotModel, "Pad", Vector3.new(14, 0.5, 14), at, if unlocked then swatch("pathWhite") else swatch("stone"), { castShadow = false })
			pad.Transparency = if unlocked then 0 else 0.55
			Build.part(slotModel, "PadRim", Vector3.new(15.4, 0.3, 15.4), at - Vector3.new(0, 0.22, 0), if unlocked then accent else swatch("stoneDark"), { castShadow = false })

			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = "SlotPrompt"
			prompt.ActionText = if unlocked then "Place card" else "Unlock slot"
			prompt.ObjectText = string.format("Slot %d", index)
			prompt.HoldDuration = 0
			prompt.MaxActivationDistance = 12
			prompt.RequiresLineOfSight = false
			prompt.Parent = pad
		end
	end

	return floor
end

local function buildPlot(map: Folder, slot: Grid.Slot, accentKey: string): Model
	local plot = Instance.new("Model")
	plot.Name = slot.name
	plot:SetAttribute("Purpose", "PlayerClaim")
	plot:SetAttribute("SlotIndex", slot.index)
	plot.Parent = map
	Semantics.root(plot, "building", "player-plot", "world.player-plot")
	Semantics.region(plot, "plot", "plot-" .. tostring(slot.index))
	Semantics.landmark(plot, "plot")

	local accent = swatch(accentKey)
	local size = WORLD.plotSize
	local centre = slot.centre
	local half = size / 2

	-- The ground the whole claim sits on.
	Build.part(plot, "Foundation", Vector3.new(size, 2, size), centre + Vector3.new(0, 1, 0), swatch("grassDark"))
	Build.part(plot, "Border", Vector3.new(size + 3, 0.8, size + 3), centre + Vector3.new(0, 0.4, 0), accent, { castShadow = false })

	local slotsFolder = Instance.new("Folder")
	slotsFolder.Name = "Slots"
	slotsFolder.Parent = plot

	-- Floor 1 is built now and sits on the ground. Buying a floor raises the
	-- next deck on top of this one.
	local deckCentre = Vector3.new(centre.X, 2, centre.Z)
	MapService.buildFloor(plot, deckCentre, 1, accentKey, slotsFolder)

	-- Locked decks are outlined but not built, so a player can see what the
	-- plot becomes without the space being cluttered by things they cannot use.
	for level = 2, math.ceil(FarmCatalog.MaxSlots / SLOTS_PER_FLOOR) do
		local ghostY = deckCentre.Y + (level - 1) * WORLD.floorHeight
		local ghost = Build.part(plot, "FloorGhost" .. level, Vector3.new(108, 0.6, 108), Vector3.new(centre.X, ghostY + 1, centre.Z), swatch("stone"), { canCollide = false, castShadow = false })
		ghost.Transparency = 0.88
	end

	-- The belt runs along the front edge, outside the deck, so a player walks
	-- up to it rather than through their own farm.
	local frontZ = centre.Z - half + 22
	local beltOrigin = Vector3.new(centre.X - 40, 4.4, frontZ)
	local conveyor = Conveyor.build(plot, "CardConveyor", {
		origin = beltOrigin,
		direction = Vector3.new(1, 0, 0),
		length = 30,
		width = 9,
		speed = 5,
		theme = THEME,
		accentSwatch = accentKey,
	})

	local dispenser = Build.part(plot, "CardDispenser", Vector3.new(12, 13, 12), beltOrigin + Vector3.new(-11, 3, 0), swatch("brick"))
	Semantics.root(dispenser, "interactive", "card-dispenser", "interaction.pack.spawn")
	Build.part(plot, "DispenserHead", Vector3.new(14, 2.4, 14), beltOrigin + Vector3.new(-11, 10.5, 0), accent, { castShadow = false })
	Build.billboard(dispenser, "SPAWN PACK", accent.color, 260, 52, 11, 38, 90)

	local pullPrompt = Instance.new("ProximityPrompt")
	pullPrompt.Name = "PullCardPrompt"
	pullPrompt.ActionText = "Spawn pack"
	pullPrompt.ObjectText = "Card Belt"
	pullPrompt.HoldDuration = 0
	pullPrompt.MaxActivationDistance = 18
	pullPrompt.RequiresLineOfSight = false
	pullPrompt.Parent = dispenser

	local collector = Build.part(plot, "CardCollector", Vector3.new(13, 8, 13), beltOrigin + Vector3.new(34, 2, 0), swatch("brickDark"))
	Semantics.root(collector, "interactive", "card-collector", "interaction.belt.upgrade")
	Build.part(plot, "CollectorRim", Vector3.new(15, 1, 15), beltOrigin + Vector3.new(34, 6.5, 0), accent, { castShadow = false })
	Build.billboard(collector, "UPGRADE BELT", accent.color, 250, 48, 7, 34, 70)

	local luckPrompt = Instance.new("ProximityPrompt")
	luckPrompt.Name = "UpgradeLuckPrompt"
	luckPrompt.ActionText = "Upgrade belt luck"
	luckPrompt.ObjectText = "Sorter"
	luckPrompt.HoldDuration = 0.3
	luckPrompt.MaxActivationDistance = 18
	luckPrompt.RequiresLineOfSight = false
	luckPrompt.Parent = collector

	-- Where boxes become cash, on the opposite front corner from the belt.
	local shop = Instance.new("Model")
	shop.Name = "BoxShop"
	shop.Parent = plot
	Semantics.root(shop, "interactive", "box-shop", "interaction.boxes.sell")
	local shopAt = Vector3.new(centre.X + half - 24, 2, frontZ)
	Build.part(shop, "Counter", Vector3.new(18, 7, 12), shopAt + Vector3.new(0, 3.5, 0), swatch("wood"))
	Build.part(shop, "CounterTop", Vector3.new(20, 0.9, 14), shopAt + Vector3.new(0, 7.5, 0), accent, { castShadow = false })
	Build.billboard(shop:FindFirstChild("CounterTop") :: BasePart, "SELL CARD BOXES", accent.color, 300, 54, 5, 38, 110)

	local sellPrompt = Instance.new("ProximityPrompt")
	sellPrompt.Name = "SellBoxesPrompt"
	sellPrompt.ActionText = "Sell card boxes"
	sellPrompt.ObjectText = "Box Shop"
	sellPrompt.HoldDuration = 0
	sellPrompt.MaxActivationDistance = 16
	sellPrompt.RequiresLineOfSight = false
	sellPrompt.Parent = shop:FindFirstChild("Counter")

	-- A single sign facing the avenue, rather than a gate arch and a beacon.
	local gateX = if centre.X < 0 then half else -half
	local sign = Build.part(plot, "PlotSign", Vector3.new(2, 12, 22), centre + Vector3.new(gateX, 8, 0), swatch("brickDark"))
	Semantics.anchor(plot, "plot", centre + Vector3.new(gateX, 15, 0))
	Build.billboard(sign, string.upper(slot.name), accent.color, 300, 58, 8, 42, 150)

	plot:SetAttribute("LuckLevel", 1)
	plot:SetAttribute("SlotsPerFloor", SLOTS_PER_FLOOR)
	return plot, conveyor, pullPrompt, luckPrompt, slotsFolder, sellPrompt
end


-- ----------------------------------------------------------------- build

function MapService.build()
	Sky.apply(Sky.BrightDay)

	local map = Instance.new("Folder")
	map.Name = "Map"
	map:SetAttribute("WorldStyle", "Copperridge")
	map:SetAttribute("WorldKitVersion", WorldKit.VERSION)
	map.Parent = workspace

	-- Explicit OBB for the shared hub. Validators measure this marker but it is
	-- excluded from visual-root density and never rendered.
	local qualityRegions = Instance.new("Folder")
	qualityRegions.Name = "QualityRegions"
	qualityRegions.Parent = map
	local hubRegion = Build.part(
		qualityRegions,
		"HubRegion",
		Vector3.new(360, 40, 300),
		Vector3.new(0, 20, -75),
		swatch("ground"),
		{ transparency = 1, canCollide = false, castShadow = false }
	)
	hubRegion.CanQuery = false
	Semantics.region(hubRegion, "hub", "hub")
	Semantics.exclude(hubRegion)

	local layout = plotLayout()
	local problems = Grid.validate(layout, #GameConfig.PlotNames)
	if #problems > 0 then
		warn("[MapService] plot layout problems: " .. table.concat(problems, "; "))
	end
	local slots = Grid.slots(layout, #GameConfig.PlotNames, GameConfig.PlotNames)

	local groundCentre, groundWidth, groundDepth = buildGround(map, slots)

	local farZ = math.huge
	for _, slot in ipairs(slots) do
		farZ = math.min(farZ, slot.min.Z)
	end

	buildSpawnPlaza(map)
	buildAvenue(map, 70, farZ - 70)

	local purchasePrompt = buildExchange(map)
	local floorPrompt = buildLift(map)
	buildMineFace(map, farZ - 150)

	local plotRigs = {}
	for index, slot in ipairs(slots) do
		local accentKey = PLOT_ACCENTS[((index - 1) % #PLOT_ACCENTS) + 1]
		local plot, conveyor, pullPrompt, luckPrompt, slotsFolder, sellPrompt = buildPlot(map, slot, accentKey)
		plotRigs[slot.name] = {
			model = plot,
			conveyor = conveyor,
			pullPrompt = pullPrompt,
			luckPrompt = luckPrompt,
			slotsFolder = slotsFolder,
			sellPrompt = sellPrompt,
			accentKey = accentKey,
			centre = slot.centre,
		}
		-- A spur from the avenue to each gate, so no plot is reached across grass.
		local gateX = if slot.centre.X < 0 then slot.centre.X + WORLD.plotSize / 2 else slot.centre.X - WORLD.plotSize / 2
		local avenueX = if slot.centre.X < 0 then -AVENUE_WIDTH / 2 else AVENUE_WIDTH / 2
		Build.road(map, "Spur" .. slot.name, Vector3.new(gateX, GROUND_Y, slot.centre.Z), Vector3.new(avenueX, GROUND_Y, slot.centre.Z), 16, swatch("pathRed"), 0.5)
	end

	-- Vegetation last: it needs to know what to keep clear of.
	local exclusions = {
		{ centre = Vector3.new(0, 0, 0), size = Vector2.new(190, 190) },
		{ centre = Vector3.new(0, 0, groundCentre.Z), size = Vector2.new(AVENUE_WIDTH + 60, groundDepth) },
		{ centre = Vector3.new(-118, 0, HUB_Z), size = Vector2.new(150, 130) },
		{ centre = Vector3.new(118, 0, HUB_Z), size = Vector2.new(140, 130) },
	}
	for _, slot in ipairs(slots) do
		table.insert(exclusions, { centre = slot.centre, size = Vector2.new(WORLD.plotSize + 30, WORLD.plotSize + 30) })
	end

	Nature.scatter(map, THEME, {
		centre = groundCentre,
		size = Vector2.new(groundWidth - 40, groundDepth - 40),
		count = 150,
		seed = 20260811,
		exclusions = exclusions,
		minSpacing = 16,
	}, 0.68)

	return map, purchasePrompt, floorPrompt, plotRigs
end

return MapService
