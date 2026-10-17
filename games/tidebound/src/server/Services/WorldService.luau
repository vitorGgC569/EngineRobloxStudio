--!strict
--[[
	WorldService — the sea, the isles, and everything that marks them.

	One heightfield is the plan and one `World.paint` writes it. Islands are
	features on that field, not separate objects: the beach where a pier
	starts exists because the pier's islet feature is there, which means the
	geometry can never disagree with the placement.

	The catalogue dresses the land, but nothing load-bearing comes from it.
	A tree that fails to fetch leaves a fallback tree built from parts, and
	that is the difference between a worse island and a missing one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local World = Forge.World
local Debug = Forge.Debug
local Rng = Forge.Core.Rng
local Place = Forge.Catalog.Place
--: The Quality Engine's vocabulary: every prop this service builds says what
--: it is, so the release gate can measure a world instead of an absence.
local Mark = Forge.Mark

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local SeaPlan = require(Shared.SeaPlan)
local AssetPicks = require(Shared.AssetPicks)

--: The dressing eye: which models each topic may use. See AssetPicks.
local dress = AssetPicks.catalogue

local BuildKit = require(script.Parent.Parent.Lib.BuildKit)

local WorldService = {}

local SEA = Config.waterLevel

WorldService.docks = {} -- zoneId -> Vector3 (the islet centre, on land)
WorldService.piers = {} -- zoneId -> Vector3 (the pier tip, over water once start refines it)

WorldService.field = nil

-- ================================== field ===================================
local function buildField(): any
	local field = World.heightfield(SeaPlan.heightfieldConfig())

	for _, zone in Config.zones do
		local dock = SeaPlan.dockPoint(zone)
		WorldService.docks[zone.id] = Vector3.new(dock.X, field:height(dock.X, dock.Y), dock.Y)
		WorldService.piers[zone.id] = Vector3.new(
			zone.center.X,
			SEA,
			zone.center.Y)
	end
	return field
end

-- ================================== paint ===================================
local function materialFor(x: number, z: number, height: number, slope: number): Enum.Material
	local abyss = Config.zone("abyss")
	local toAbyss = (Vector2.new(x, z) - abyss.center).Magnitude
	if toAbyss < abyss.radius + 100 and height < SEA + 4 then
		return Enum.Material.Slate
	end
	if height <= SEA + 1.7 then
		return Enum.Material.Sand
	end
	if slope < 0.7 then
		return Enum.Material.Rock
	end
	if height > SEA + 30 then
		return Enum.Material.Rock
	end
	if height > SEA + 18 then
		return Enum.Material.LeafyGrass
	end
	return Enum.Material.Grass
end

-- ============================== dressing ====================================
--[[
	Terrain reads as material first and colour second, and Roblox's defaults
	are cartoon-bright: the ground shipped as flat lemon-green in the first
	live capture, sand as near-white. These tints are the whole fix; Water
	is deliberately absent because it has its own properties (the client
	sets those in AmbienceController).
]]
local TERRAIN_TINT: { [Enum.Material]: Color3 } = {
	[Enum.Material.Grass] = Color3.fromRGB(94, 122, 76),
	[Enum.Material.LeafyGrass] = Color3.fromRGB(82, 112, 70),
	[Enum.Material.Sand] = Color3.fromRGB(198, 180, 138),
	[Enum.Material.Rock] = Color3.fromRGB(122, 118, 111),
	[Enum.Material.Slate] = Color3.fromRGB(72, 76, 84),
	[Enum.Material.Ground] = Color3.fromRGB(126, 118, 100),
	[Enum.Material.Mud] = Color3.fromRGB(96, 86, 68),
}

local function tintTerrain()
	for material, color in TERRAIN_TINT do
		pcall(function()
			Workspace.Terrain:SetMaterialColor(material, color)
		end)
	end
end

local function foliageTone(stream: any): Color3
	local greens = {
		Color3.fromRGB(74, 118, 64),
		Color3.fromRGB(88, 132, 70),
		Color3.fromRGB(64, 104, 60),
		Color3.fromRGB(102, 140, 78),
	}
	return greens[math.floor(stream:number(1, #greens + 0.999))]
end

--[[
	Two foliage families, one deterministic choice per tree.

	Everything green in the catalogue arrives materialled `Grass`, and the
	measured consequence was a measured region whose parts were 89% Grass --
	the variety rule read the harbor as one green mass, and a reviewer would
	read it the same way. Splitting each placement between `Grass` and its
	leafier sibling costs nothing, keeps a grove varied at the material level
	rather than only in colour, and takes the dominant material of every
	region well under its ceiling.
]]
local function varyFoliage(model: Instance, leafy: boolean)
	if not leafy then
		return
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Material == Enum.Material.Grass then
			descendant.Material = Enum.Material.LeafyGrass
		end
	end
end

local function dressTrees(field: any, folder: Instance)
	World.scatter(field, {
		id = "tidebound.trees",
		step = 13,
		budget = 460,
		place = function(at: Vector3, stream: any)
			local scale = stream:number(0.75, 1.7)
			local leafy = stream:number() < 0.5
			local built = Place.put(dress, {
				topic = "tree",
				seed = stream:number(1, 100000),
				at = at - Vector3.new(0, 0.6, 0),
				parent = folder,
				yaw = stream:number(0, math.pi * 2),
				stream = stream,
			})
			if built then
				varyFoliage(built, leafy)
				Mark.root(built, "tree", built.Name, "catalogue")
			else
				local fallback = BuildKit.tree(at, scale, foliageTone(stream), folder)
				varyFoliage(fallback, leafy)
				Mark.root(fallback, "tree", "kit-tree", "buildkit")
			end
			return true
		end,
		--: Density answers "is this a forest", which includes "is this even
		--: land near one of the five waters". A place callback cannot skip
		--: cells -- it runs after the dice -- so the geography has to live
		--: here or the budget drains into open ocean.
		density = function(x: number, z: number, height: number, slope: number): number
			if height < SEA + 2.6 or slope < 0.86 then
				return 0
			end
			local point = Vector2.new(x, z)
			for _, zone in Config.zones do
				local toZone = (point - zone.center).Magnitude
				if toZone < zone.radius + 140 then
					if (point - SeaPlan.dockPoint(zone)).Magnitude < 40 then
						return 0
					end
					if height > SEA + 34 then
						return 0.12
					end
					return 0.5
				end
			end
			return 0
		end,
	})
end

local function dressShore(field: any, folder: Instance)
	World.scatter(field, {
		id = "tidebound.shore",
		step = 15,
		budget = 360,
		place = function(at: Vector3, stream: any)
			local kind = stream:number()
			if kind < 0.42 then
				local built = Place.put(dress, {
					topic = "rock",
					seed = stream:number(1, 100000),
					at = at,
					parent = folder,
					yaw = stream:number(0, math.pi * 2),
					stream = stream,
				})
				if built then
					Mark.root(built, "rock", built.Name, "catalogue")
				else
					local tone = Color3.fromRGB(120, 118, 112):Lerp(Color3.new(0.3, 0.32, 0.34), stream:number() * 0.4)
					Mark.root(BuildKit.rock(at, stream:number(0.7, 1.5), tone, folder), "rock", "kit-rock", "buildkit")
				end
			else
				local built = Place.put(dress, {
					topic = "bush",
					seed = stream:number(1, 100000),
					at = at,
					parent = folder,
					yaw = stream:number(0, math.pi * 2),
					stream = stream,
				})
				if built then
					Mark.root(built, "plant", built.Name, "catalogue")
				else
					Mark.root(BuildKit.bush(at, stream:number(0.8, 1.5), foliageTone(stream), folder), "plant", "kit-bush", "buildkit")
				end
			end
			return true
		end,
		density = function(x: number, z: number, height: number, slope: number): number
			if height < SEA + 1.0 or height > SEA + 11 then
				return 0
			end
			if slope < 0.72 then
				return 0.45
			end
			return 0.28
		end,
	})
end

--[[
	A garden for the harbor islet.

	The scatter passes answer "is this a world"; the first live capture
	answered "yes, and the square outside the market is a green table".
	This ring is the bit a player stands in: flowers, grass tufts and low
	bushes between the market clearway and the tree line, placed against
	the hub dock so no other zone competes for the budget.
]]
local function dressGarden(field: any, folder: Instance)
	local hub = WorldService.docks.shallows
	World.scatter(field, {
		id = "tidebound.garden",
		step = 11,
		budget = 110,
		place = function(at: Vector3, stream: any)
			local kind = stream:number()
			local topic = if kind < 0.32 then "flower" else "bush"
			local built = Place.put(dress, {
				topic = topic,
				seed = stream:number(1, 100000),
				at = at,
				parent = folder,
				yaw = stream:number(0, math.pi * 2),
				jitter = stream:number(0.85, 1.5),
				stream = stream,
			})
			if built then
				Mark.root(built, "plant", built.Name, "catalogue")
			elseif topic == "bush" then
				Mark.root(BuildKit.bush(at, stream:number(0.6, 1.1), foliageTone(stream), folder), "plant", "kit-bush", "buildkit")
			end
			return true
		end,
		density = function(x: number, z: number, height: number, slope: number): number
			local flat = Vector2.new(x - hub.X, z - hub.Z).Magnitude
			if flat < 42 or flat > 130 then
				return 0
			end
			if height < SEA + 2 or height > SEA + 20 or slope < 0.8 then
				return 0
			end
			return 0.55
		end,
	})
end

-- =============================== structures =================================
--[[
	Walk out of an islet until the ground is about to go under, and build the
	pier from there.

	Placing a pier at a fixed offset from the islet's centre buried its near
	end in the hill: the flat is seven studs above the waterline and the deck
	was not. The waterline is a measurement, so this makes it one.
]]
local function shoreline(from: Vector3, direction: Vector3, parent: Instance?): Vector3
	local point = from
	for _ = 1, 60 do
		local hit = World.surface(point.X, point.Z, { ignoreWater = true, from = SEA + 60 })
		if hit and hit.Y <= SEA + 2.0 then
			return Vector3.new(point.X, SEA + 1.5, point.Z)
		end
		point += direction * 4
	end
	return Vector3.new(point.X, SEA + 1.5, point.Z)
end

local function buildHub(root: Instance)
	local hubDock = WorldService.docks.shallows
	local ground = Vector3.new(hubDock.X, hubDock.Y, hubDock.Z)

	local seaward = Vector3.new(0, 0, 1)
	local deck = shoreline(ground, seaward)
	local pierTip = Vector3.new(deck.X + 6, deck.Y, deck.Z + 84)
	WorldService.piers.shallows = pierTip
	Mark.root(BuildKit.pier(deck, pierTip, 9, root), "structure", "pier", "buildkit")

	-- Market row: three stalls facing the walkway, lamps between them.
	local facing = Vector3.new(0, 0, 1)
	for index = -1, 1 do
		local at = Vector3.new(ground.X + index * 16, ground.Y - 0.2, ground.Z - 34)
		Mark.root(BuildKit.stall(at, facing, root), "structure", "market-stall", "buildkit")
	end
	Mark.root(BuildKit.lamp(Vector3.new(ground.X - 24, ground.Y, ground.Z - 22), root), "structure", "lamp", "buildkit")
	Mark.root(BuildKit.lamp(Vector3.new(ground.X + 24, ground.Y, ground.Z - 22), root), "structure", "lamp", "buildkit")
	Mark.root(BuildKit.lamp(Vector3.new(ground.X - 24, ground.Y, ground.Z + 4), root), "structure", "lamp", "buildkit")
	Mark.root(BuildKit.lamp(Vector3.new(ground.X + 24, ground.Y, ground.Z + 4), root), "structure", "lamp", "buildkit")

	Mark.root(BuildKit.crates(Vector3.new(ground.X - 12, ground.Y, ground.Z - 44), root, Rng.at("hub.crates", ground.X - 12, ground.Z - 44)), "structure", "crates", "buildkit")
	Mark.root(BuildKit.crates(Vector3.new(ground.X + 13, ground.Y, ground.Z - 40), root, Rng.at("hub.crates", ground.X + 13, ground.Z - 40)), "structure", "crates", "buildkit")
	Mark.root(BuildKit.barrel(Vector3.new(ground.X + 17, ground.Y, ground.Z - 30), root), "structure", "barrel", "buildkit")
	Mark.root(BuildKit.barrel(Vector3.new(ground.X + 19.5, ground.Y, ground.Z - 32), root), "structure", "barrel", "buildkit")

	Mark.root(BuildKit.sign("TIDEBOUND HARBOR",
		"Cast from the pier. Sell at the stalls. The sea does the rest.",
		Vector3.new(ground.X, ground.Y, ground.Z + 8), Vector3.new(0, 0, -1), root), "structure", "sign", "buildkit")

	-- Moorings along the west edge of the islet.
	for index = 0, 3 do
		Mark.root(BuildKit.mooring(Vector3.new(ground.X - 34, SEA + 1.2, ground.Z - 6 + index * 12), root), "structure", "mooring", "buildkit")
	end
	Mark.root(BuildKit.mooring(Vector3.new(ground.X + 34, SEA + 1.2, ground.Z - 6), root), "structure", "mooring", "buildkit")

	-- The spawn, placed on the flat rather than reasoned about.
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "HarborSpawn"
	spawn.Size = Vector3.new(10, 1, 10)
	spawn.CFrame = CFrame.new(ground.X, ground.Y + 0.6, ground.Z - 6)
	spawn.Anchored = true
	spawn.CanCollide = true
	spawn.Neutral = true
	spawn.Color = Color3.fromRGB(206, 168, 96)
	spawn.Material = Enum.Material.WoodPlanks
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = root
	Mark.root(spawn, "structure", "harbor-spawn", "buildkit")
end

local ZONE_COLORS: { [string]: Color3 } = {
	shallows = Color3.fromRGB(120, 220, 255),
	kelp = Color3.fromRGB(110, 230, 150),
	coral = Color3.fromRGB(255, 170, 200),
	storm = Color3.fromRGB(255, 210, 120),
	abyss = Color3.fromRGB(190, 140, 255),
}

local function buildZoneMarks(root: Instance)
	for _, zone in Config.zones do
		local dock = WorldService.docks[zone.id]
		local zoneColor = ZONE_COLORS[zone.id] or Color3.fromRGB(220, 220, 220)

		if zone.id ~= "shallows" then
			-- Every outer dock gets its own short pier and a name board,
			-- pointing at the water it serves.
			local seaward = Vector3.new(zone.center.X - dock.X, 0, zone.center.Y - dock.Z).Unit
			local deck = shoreline(Vector3.new(dock.X, dock.Y, dock.Z), seaward, root)
			local tip = Vector3.new(deck.X + seaward.X * 64, deck.Y, deck.Z + seaward.Z * 64)
			WorldService.piers[zone.id] = tip
			Mark.root(BuildKit.pier(deck, tip, 7, root), "structure", "zone-pier", "buildkit")
			Mark.root(BuildKit.sign(zone.name, zone.blurb, Vector3.new(dock.X + 10, dock.Y, dock.Z + 4),
				Vector3.new(-0.6, 0, -1).Unit, root), "structure", "zone-sign", "buildkit")
			Mark.root(BuildKit.lamp(Vector3.new(dock.X - 10, dock.Y, dock.Z + 6), root), "structure", "lamp", "buildkit")
			Mark.root(BuildKit.mooring(Vector3.new(deck.X + 9, SEA + 1.2, deck.Z + 10), root), "structure", "mooring", "buildkit")
			Mark.root(BuildKit.mooring(Vector3.new(deck.X - 9, SEA + 1.2, deck.Z + 10), root), "structure", "mooring", "buildkit")
		end

		-- A ring of buoys marks the water itself. It is also the thing that
		-- tells a player at sea, with no UI open, whose water they are in.
		local ring = math.floor(zone.radius * 0.8)
		for step = 0, 9 do
			local angle = (step / 10) * math.pi * 2
			local x = zone.center.X + math.cos(angle) * ring
			local z = zone.center.Y + math.sin(angle) * ring
			Mark.root(BuildKit.buoy(Vector3.new(x, SEA + 0.4, z), zoneColor, root), "structure", "buoy-" .. zone.id, "buildkit")
		end
	end
end

-- ================================ regions ===================================
--[[
	The measurable boxes. The quality engine reads a region as an oriented
	box and measures density, height and materials of every tagged root
	whose centre falls inside it -- so the boxes have to sit where the
	content actually is, invisible and out of every query. The harbour box
	covers the hub islet and its garden; each wild zone gets one box over
	its islet, wild enough to hold the outer ring of dressing.
]]
local function markRegions(root: Instance)
	local function box(name: string, center: Vector3, size: Vector3, profile: string)
		local part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 1
		part.Size = size
		part.CFrame = CFrame.new(center)
		part.Parent = root
		Mark.region(part, profile)
	end

	local hub = WorldService.docks.shallows
	-- The harbour box reaches east across the basin mouth.  It used to stop
	-- at the islet edge, which left the sea-arch standing outside its own
	-- harbour: seen from the harbour the arch subtended an 89-degree window,
	-- so no threshold on blind spots could ever pass.  Enclosing the water
	-- the arch stands in gives the harbour samples all the way around it.
	-- West edge stays on the islet garden; the abyss dock's north rim now
	-- overlaps the south-east corner, which only adds roots the harbour
	-- density can carry.
	box("Region_harbor", Vector3.new(hub.X + 80, hub.Y + 60, hub.Z), Vector3.new(340, 160, 180), "harbor")

	for _, zone in Config.zones do
		if zone.id ~= "shallows" then
			local dock = WorldService.docks[zone.id]
			box("Region_wilds_" .. zone.id, Vector3.new(dock.X, dock.Y + 60, dock.Z), Vector3.new(240, 180, 240), "wilds")
		end
	end
end

-- ================================ startup ===================================
function WorldService.start()
	local started = os.clock()
	local root = Workspace:FindFirstChild("Tidebound")
	if not root then
		root = Instance.new("Folder")
		root.Name = "Tidebound"
		root.Parent = Workspace
	end

	WorldService.field = buildField()
	World.paint(WorldService.field, {
		seaLevel = SEA,
		material = materialFor,
	})
	tintTerrain()

	-- The hub is exactly on its feature, so it stands on the plan rather than
	-- on an approximation of it.
	local hubDock = WorldService.docks.shallows
	local surface = World.surface(hubDock.X, hubDock.Z, { ignoreWater = true, from = 400 })
	if surface then
		WorldService.docks.shallows = Vector3.new(hubDock.X, surface.Y, hubDock.Z)
		for _, zone in Config.zones do
			local dock = WorldService.docks[zone.id]
			local hit = World.surface(dock.X, dock.Z, { ignoreWater = true, from = 400 })
			if hit then
				WorldService.docks[zone.id] = Vector3.new(dock.X, hit.Y, dock.Z)
			end
		end
	end

	buildHub(root)
	buildZoneMarks(root)
	markRegions(root)
	dressTrees(WorldService.field, root)
	dressShore(WorldService.field, root)
	dressGarden(WorldService.field, root)

	Debug.count("world.props", #root:GetDescendants())
	Debug.info(string.format("world built in %.1fs", os.clock() - started))
end

-- ================================= queries ==================================
function WorldService.dock(zoneId: string): Vector3
	return WorldService.docks[zoneId] or WorldService.docks.shallows
end

--: Where a summoned boat appears: just off the pier, and wet by
--: construction -- the first point along the pier's bearing that is
--: actually deep water, not an offset that merely looks like one.
function WorldService.boatSpawn(zoneId: string): Vector3
	local zone = Config.zone(zoneId) or Config.zone("shallows")
	local pier = WorldService.piers[zoneId] or WorldService.piers.shallows
	local seaward = Vector3.new(zone.center.X - pier.X, 0, zone.center.Y - pier.Z)
	if seaward.Magnitude > 0 then
		seaward = seaward.Unit
	end
	for step = 8, 96, 4 do
		local at = pier + seaward * step
		local point = Vector3.new(at.X, SEA + 1.4, at.Z)
		if WorldService.isWater(point) and WorldService.depthAt(point) >= 1.5 then
			return point
		end
	end
	return Vector3.new(pier.X, SEA + 1.4, pier.Z)
end

--: Is there open water at this point? Ground below the waterline, and no
--: land at the surface. Used to validate a cast before anything exists.
--: The cast starts high above anything the field can build: a ray that
--: begins inside a mound returns no hit, which used to read as "open water".
function WorldService.isWater(position: Vector3): boolean
	if position.Y > SEA + 6 then
		return false
	end
	local ground = World.surface(position.X, position.Z, { ignoreWater = true, from = 400 })
	if not ground then
		return true
	end
	return ground.Y < SEA - 1.2
end

function WorldService.depthAt(position: Vector3): number
	local ground = World.surface(position.X, position.Z, { ignoreWater = true, from = 400 })
	if not ground then
		return 0
	end
	return math.max(0, SEA - ground.Y)
end

--[[
	Where a person may stand near `desired`: walk back toward the dock
	until the ground is above the waterline, and stand there. An NPC offset
	that looks right on a map can land in open water on the field -- the
	first abyss fisher did exactly that -- so the ground answers, not the
	arithmetic.
]]
function WorldService.groundSpot(desired: Vector3, base: Vector3): Vector3
	local toward = base - desired
	local direction = if toward.Magnitude > 0.001 then toward.Unit else Vector3.zero
	for step = 0, 24 do
		local point = desired + direction * (step * 2)
		local hit = World.surface(point.X, point.Z, { ignoreWater = true, from = 400 })
		if hit and hit.Y >= SEA + 1 then
			return Vector3.new(point.X, hit.Y, point.Z)
		end
	end
	return Vector3.new(base.X, base.Y, base.Z)
end

--: A random castable point inside a zone, for tests and for adventurous NPC
--: placement.
function WorldService.waterPoint(zoneId: string, stream: any): Vector3
	local zone = Config.zone(zoneId) or Config.zone("shallows")
	for _ = 1, 60 do
		local angle = stream:number(0, math.pi * 2)
		local radius = stream:number(zone.radius * 0.25, zone.radius * 0.8)
		local point = Vector3.new(
			zone.center.X + math.cos(angle) * radius,
			SEA - 1,
			zone.center.Y + math.sin(angle) * radius)
		if WorldService.isWater(point) and WorldService.depthAt(point) >= 1 then
			return point
		end
	end
	--: The pier tip is the one point known to sit seaward of that zone's
	--: shoreline, so the search walks from it across the water the pier
	--: points at rather than guessing again. (The old fallback was an
	--: offset from the hub dock that had never been tested against the
	--: water it claimed to be.)
	local pier = WorldService.piers[zoneId]
	if pier then
		local from = Vector3.new(pier.X, SEA - 1, pier.Z)
		local toCentre = Vector3.new(zone.center.X, SEA - 1, zone.center.Y) - from
		for step = 0, 1, 0.025 do
			local point = from + toCentre * step
			if WorldService.isWater(point) and WorldService.depthAt(point) >= 1 then
				return point
			end
		end
		return from
	end
	return Vector3.new(zone.center.X, SEA - 1, zone.center.Y)
end

return WorldService
