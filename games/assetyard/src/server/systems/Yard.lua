--!strict
--[[
	Yard — a world built from the CC0 models published to this account.

	What this is for
	----------------

	Answering one question before spending two days on the next batch: **is 295
	models enough variety to build a game out of?**

	So it is not a museum with one of everything on a plinth. It is a generated
	world -- terrain, zones, scatter, a place you can walk -- because variety
	looks different when things are repeated across a landscape than when they
	are lined up for inspection. Four trees look like plenty in a row and like
	four trees when they are the only trees in a forest.

	How the models get here
	-----------------------

	`Catalog.ItchAssets` holds asset ids, not geometry: these were published to
	this account, so `InsertService:LoadAsset` will fetch them. That call works
	for exactly the reason it fails for the open Creator Store -- the signed-in
	account owns them.

	**Each asset is fetched once and cloned after that.** `LoadAsset` yields and
	costs a network round trip; a world placing 400 props by calling it 400
	times spends minutes doing what a cache does in seconds, and the models are
	identical anyway.

	Textured first, always
	----------------------

	A model published from a `.glb` carries its images; one from an `.fbx` does
	not. 221 of the 295 have colour, and where a topic has any textured model
	this asks for one -- a grey prop beside a coloured one reads as a bug rather
	than as variety.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local InsertService = game:GetService("InsertService")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Itch = Forge.Catalog.ItchAssets
local World = Forge.World
local Visual = Forge.Visual
local Material = Forge.Material
local Rng = Forge.Core.Rng
local Debug = Forge.Debug

local Yard = {}

--: Half-width of the ground. Big enough that scatter reads as a landscape
--: rather than as a crowded table.
local HALF = 420

--[[
	Zones, so related things stand together.

	A world where a sofa sits between two boulders is a world that tests
	nothing: the eye reads it as noise and cannot judge whether the trees are
	repetitive. Grouping by theme is what makes repetition visible, which is
	the entire point of this build.

	`density` is props per zone. `spread` is how far from the zone centre they
	scatter.
]]
local ZONES = {
	{ name = "forest", at = Vector2.new(-240, -200), spread = 170, density = 90,
	  topics = { "tree", "bush", "rock", "log", "flower", "grass patch" } },
	{ name = "village", at = Vector2.new(230, -190), spread = 150, density = 55,
	  topics = { "house", "fence", "door", "window", "street lamp", "bench",
	             "wooden sign", "barrel", "crate" } },
	{ name = "interior", at = Vector2.new(-250, 210), spread = 140, density = 50,
	  topics = { "chair", "table", "bed", "sofa", "bookshelf", "desk lamp",
	             "rug", "kitchen counter", "refrigerator" } },
	{ name = "works", at = Vector2.new(240, 220), spread = 150, density = 50,
	  topics = { "conveyor", "dropper", "furnace", "generator", "storage tank",
	             "pipe", "mine cart", "ore", "pickaxe", "factory machine" } },
	{ name = "keep", at = Vector2.new(0, -340), spread = 130, density = 40,
	  topics = { "castle", "altar", "anvil", "sword", "shield", "potion",
	             "magic staff", "treasure", "coffin", "tombstone" } },
	{ name = "outpost", at = Vector2.new(0, 340), spread = 140, density = 40,
	  topics = { "watchtower", "barricade", "sandbag", "ammo box",
	             "military crate", "shooting target", "rifle", "pistol" } },
}

local function _count(table_: { [any]: any }): number
	local n = 0
	for _ in table_ do
		n += 1
	end
	return n
end

--: One fetch per asset id, reused for every placement.
local loaded: { [number]: Instance } = {}
local missing: { [number]: boolean } = {}

local function template(assetId: number): Instance?
	if loaded[assetId] then
		return loaded[assetId]
	end
	if missing[assetId] then
		return nil
	end

	local ok, container = pcall(function()
		return InsertService:LoadAsset(assetId)
	end)
	if not ok or typeof(container) ~= "Instance" then
		--: Remembered, so a world placing this topic forty times does not make
		--: forty failing network calls to learn the same thing.
		missing[assetId] = true
		return nil
	end

	local first = container:GetChildren()[1]
	if not first then
		missing[assetId] = true
		container:Destroy()
		return nil
	end
	first.Parent = ReplicatedStorage
	loaded[assetId] = first
	container:Destroy()
	return first
end

--[[
	How tall each kind of thing should stand, in studs.

	**CC0 packs share no unit.** This is the finding that shaped this function
	and it is not solvable by publishing more assets: a sofa from one author
	arrives 271 studs tall and a fuel tank from another 318, because each pack
	was modelled for its own engine at its own scale and nothing on itch.io
	normalises that. Placed as authored, three sofas tower over a 420-stud
	world and everything else is invisible beside them.

	So nothing is placed at its authored size. Each topic declares what it
	should measure, and the model is scaled to reach it.
]]
local HEIGHTS: { [string]: number } = {
	tree = 22, bush = 3, rock = 4, log = 2, flower = 1, ["grass patch"] = 1,
	house = 18, fence = 4, door = 7, window = 5, ["street lamp"] = 9,
	bench = 3, ["wooden sign"] = 4, barrel = 4, crate = 3,
	chair = 4, table = 3, bed = 3, sofa = 3, bookshelf = 7,
	["desk lamp"] = 2, rug = 1, ["kitchen counter"] = 4, refrigerator = 7,
	conveyor = 3, dropper = 6, furnace = 7, generator = 5,
	["storage tank"] = 12, pipe = 3, ["mine cart"] = 4, ore = 3,
	pickaxe = 3, ["factory machine"] = 8,
	castle = 45, altar = 4, anvil = 3, sword = 4, shield = 3,
	potion = 1, ["magic staff"] = 5, treasure = 3, coffin = 3, tombstone = 3,
	watchtower = 20, barricade = 4, sandbag = 2, ["ammo box"] = 2,
	["military crate"] = 3, ["shooting target"] = 5, rifle = 4, pistol = 2,
}
local DEFAULT_HEIGHT = 5

--[[
	Stand a model on the ground at the size its topic asks for.

	`PivotTo` puts a model's centre at the point, which sinks half of everything
	into the terrain, so the lift is half the *scaled* height.
]]
local function place(model: Instance, at: Vector3, yaw: number, topic: string)
	if not model:IsA("Model") and not model:IsA("BasePart") then
		return
	end

	local size = if model:IsA("Model")
		then (model :: Model):GetExtentsSize()
		else (model :: BasePart).Size

	--: Scale from the authored height to the wanted one. Uniform, because a
	--: per-axis fit distorts anything that is not a box.
	local wanted = HEIGHTS[topic] or DEFAULT_HEIGHT
	local factor = if size.Y > 0.01 then wanted / size.Y else 1
	if model:IsA("Model") then
		(model :: Model):ScaleTo(factor)
		size = (model :: Model):GetExtentsSize()
	else
		local part = model :: BasePart
		part.Size = part.Size * factor
		size = part.Size
	end

	local frame = CFrame.new(at + Vector3.new(0, size.Y * 0.5, 0))
		* CFrame.Angles(0, yaw, 0)

	if model:IsA("Model") then
		(model :: Model):PivotTo(frame)
	else
		(model :: BasePart).CFrame = frame
	end

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			--: Scenery is looked at, not walked into. Four hundred props each
			--: querying the broadphase is a frame budget spent on nothing.
			part.CanCollide = false
			part.CanTouch = false
		end
	end
	if model:IsA("BasePart") then
		(model :: BasePart).Anchored = true
		;(model :: BasePart).CanCollide = false
	end
end

local function lay(container: Instance)
	local field = World.heightfield({
		size = HALF * 2,
		seed = 20260819,
		range = { 2, 26 },
		base = { { frequency = 0.0022, octaves = 4, weight = 1 } },
		features = {
			{ kind = "flat", center = Vector2.new(0, 0), radius = 120,
			  height = 12, blend = 1.6 },
		},
		floor = 0,
	})

	local report = World.paint(field, {
		resolution = 4,
		chunk = 96,
		clear = true,
		material = function(_x, _z, _height, slope)
			return if slope < 0.75 then Enum.Material.Rock else Enum.Material.Grass
		end,
	})
	Debug.info(string.format("ground: %d of %d chunks written",
		report.written or 0, report.attempted or 0))
	return field
end

function Yard.start()
	Visual.defineLook("yard", {
		ambient = Color3.fromRGB(108, 112, 124),
		outdoorAmbient = Color3.fromRGB(180, 186, 200),
		brightness = 3.0,
		clockTime = 10.5,
		fogEnd = 2400,
		fogColor = Color3.fromRGB(180, 212, 238),
		colorCorrection = { contrast = 0.08, saturation = 0.14 },
	})
	Material.palette("stylised")

	local container = Workspace:FindFirstChild("Props") or Workspace
	local field = lay(container)

	local stream = Rng.stream("yard.scatter")
	local placed, skipped = 0, 0
	local usedTopics: { [string]: number } = {}

	for _, zone in ZONES do
		for index = 1, zone.density do
			local topic = zone.topics[stream:int(1, #zone.topics)]
			--: Seeded from the placement, so the same world twice is the same
			--: world -- and so a topic's four models all get used rather than
			--: one being picked forty times.
			local seed = index * 7919 + placed
			local assetId = Itch.pick(topic, seed, true) or Itch.pick(topic, seed, false)
			if not assetId then
				skipped += 1
				continue
			end

			local source = template(assetId)
			if not source then
				skipped += 1
				continue
			end

			local x = zone.at.X + stream:number(-zone.spread, zone.spread)
			local z = zone.at.Y + stream:number(-zone.spread, zone.spread)
			local ground = World.surface(x, z)
			if not ground then
				skipped += 1
				continue
			end

			local clone = source:Clone()
			place(clone, ground, stream:number(0, math.pi * 2), topic)
			clone.Parent = container
			placed += 1
			usedTopics[topic] = (usedTopics[topic] or 0) + 1
		end
	end

	local distinct = 0
	for _ in usedTopics do
		distinct += 1
	end

	Debug.info(string.format(
		"yard: %d props placed, %d skipped, %d topics, %d assets fetched",
		placed, skipped, distinct, _count(loaded)))

	Debug.probe("yard", function()
		return {
			placed = placed,
			skipped = skipped,
			topics = distinct,
			assetsFetched = _count(loaded),
			assetsMissing = _count(missing),
			catalogue = Itch.describe(),
		}
	end)
end

return Yard
