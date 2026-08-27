--!strict
--[[
	Yard — a composed place built from the CC0 models published to this account.

	Scatter is not a place
	----------------------

	The first version dropped 287 props into six themed circles. It proved the
	pipeline works and it looked like a warehouse floor, because nothing was
	*arranged*: houses at random angles, a castle standing in a field of chairs,
	no reason for the eye to travel anywhere.

	This one composes. The terrain gets a hill, a valley and two flats before
	anything is placed; the road is cut into the ground and the village lines
	it; the castle takes the high ground; the forest thins toward the road.
	Scatter still exists, but it fills between things rather than being the
	thing.

	Two constraints the models impose
	---------------------------------

	**No shared unit of scale.** A sofa arrives 271 studs tall and a fuel tank
	318, because every CC0 pack was modelled for its own engine and itch.io
	normalises nothing. `Forge.Catalog.Scale` classifies a topic by name and
	declares what a thing of that kind should measure; `SIZES` below is the four
	places this island disagrees. Without any of it, three sofas tower over the
	world and nothing else is visible.

	**Thin topics repeat.** Nine topics have exactly one model published, so
	asking for four gives the same model four times. Where a topic is thin this
	leans on placement -- rotation, spacing, scale jitter -- to keep repetition
	from reading as copy-paste.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Itch = Forge.Catalog.ItchAssets
local Place = Forge.Catalog.Place
local World = Forge.World
local Visual = Forge.Visual
local Material = Forge.Material
local Rng = Forge.Core.Rng
local Debug = Forge.Debug

local Yard = {}

--[[
	Small on purpose.

	The first pass ran 920 studs across with 202 props in it and looked like a
	green desert with objects on it. The count was not the problem by itself --
	920 studs is four minutes of walking, and any number of props divided by
	that area is sparse. Halving the world quadruples the density for free, and
	a place you can see the far side of reads as somewhere rather than as a
	terrain sample.
]]
local HALF = 300

--: The road is the spine. The village lines it and the castle looks down it,
--: so everything else is arranged against this.
local ROAD_Z = 0
local ROAD_FROM, ROAD_TO = -240, 240

--: High ground. A castle on a flat is a building; on a hill it is a landmark,
--: and it gives the eye somewhere to travel to.
local KEEP_AT = Vector2.new(0, -235)

--[[
	Low ground, filled and crossed. On the road, deliberately.

	It sat off to one side first, and the bridge stood in the middle of it like
	a monument: a lake nothing needed to cross and a crossing over nothing. Put
	the water where the road is and both earn their place -- the road has a
	reason to have been built, and the bridge is the thing that lets you keep
	walking.
]]
local WATER_AT = Vector2.new(0, ROAD_Z)
local SEA_LEVEL = 8

--: The bridge deck. Above the water, below the road's flats at either end, so
--: the causeway reads as a dip rather than a step.
local DECK_Y = SEA_LEVEL + 5

--: On the road, a little in from the end, so the first thing in view is the
--: village and the castle beyond it rather than the edge of the map.
local SPAWN_AT = Vector2.new(ROAD_FROM + 18, ROAD_Z)
local SPAWN_CLEAR = 24

--: How far the water goes. Only the island is authored; the rest is sea, and
--: it exists so the horizon is water rather than the edge of the terrain.
local SEA_EXTENT = HALF * 2.2

--[[
	Where this game disagrees with the engine about size.

	`Forge.Catalog.Scale` classifies a topic by name and hands back what a thing
	of that kind should measure. It is right about almost everything here, and
	these four are the exceptions this place needs:

	  * A castle is the one landmark, sized to be read from the far end of the
	    road -- which is the only reason to put a building on a hill.
	  * These walls are curtain wall around the keep, not room partitions.
	  * The bridge topic supplies piers standing in a lake, not spans.
	  * Street lamps line a village road, so they are shorter than a lamp
	    post on a highway.

	Four rows, against sixty-seven before. That is the whole point of moving the
	knowledge into categories: a game states what is unusual about *it*, not the
	size of everything it might place.
]]
local SIZES: { [string]: any } = {
	castle = { height = 105, spread = 2.4 },
	wall = { height = 20, spread = 3.5 },
	bridge = { height = 12, spread = 5 },
	["street lamp"] = { height = 12, spread = 1.6 },
}

--: Everything else is scenery you walk through. A mesh pack models a house as
--: a shell, and a shell given collision is a box you cannot enter -- so only
--: the things a player is meant to stand *on* get it.
local SOLID: { [string]: boolean } = { bridge = true, platform = true }

--: One stream for the tint pass, so a world generated twice is coloured the
--: same way. Shared across every placement rather than derived per prop,
--: because the variation wanted here is between neighbours, not between runs.
local tintStream = Rng.stream("yard.tint")

-- ============================== placing =====================================
--[[
	This game's rules about *where*; the engine's about everything else.

	Measuring the model, normalising its size, standing it on the ground,
	colouring what arrived grey and caching the fetch are all in
	`Forge.Catalog.Place` now. What is left here is the two refusals that are
	about this island in particular -- and that is the right split. A layout is
	worth authoring. None of what this used to contain was.
]]
local function put(topic: string, seed: number, at: Vector3, yaw: number,
                   parent: Instance, jitter: number?): Instance?
	--: The spawn's circle, refused before the asset is even chosen, because the
	--: cheapest rejection is the one that happens before the work.
	if (Vector2.new(at.X, at.Z) - SPAWN_AT).Magnitude < SPAWN_CLEAR then
		return nil
	end

	--: Nothing under the water, except the one thing that belongs there.
	--: `World.surface` ignores water and returns the lake bed, so a scatter
	--: point near the shore comes back as a perfectly valid position three
	--: studs under the surface -- and a barrel down there looks like a bug,
	--: because it is one. Piers are the exception and say so by topic.
	if at.Y < SEA_LEVEL - 0.5 and topic ~= "bridge" then
		return nil
	end

	return Place.put(Itch, {
		topic = topic,
		seed = seed,
		at = at,
		yaw = yaw,
		parent = parent,
		jitter = jitter,
		solid = SOLID[topic] == true,
		stream = tintStream,
		sizes = SIZES,
	})
end

-- ============================== the ground ==================================
local function ground()
	local field = World.heightfield({
		size = HALF * 2,
		seed = 20260819,
		--: A wider range and more weight on the finer layer. The first pass had
		--: 27 studs of relief over 920 and rendered as a putting green: at that
		--: ratio the noise is there in the data and invisible in the frame.
		range = { 4, 46 },
		base = {
			{ frequency = 0.0038, octaves = 4, weight = 0.55 },
			{ frequency = 0.0130, octaves = 3, weight = 0.45 },
		},
		--[[
			An island, because a world has to end somewhere.

			Without this the ground stops at a vertical wall the height of
			whatever noise happened to be there -- and a cliff face with sky
			behind it is the single clearest way to tell a player they have
			reached the edge of a test map. Falling to the shoreline instead
			ends the world in something that looks chosen.
		]]
		falloff = { power = 3.2, radius = HALF * 1.06 },
		features = {
			--: The hill, then a flat on top: a mound alone puts a castle on a
			--: slope, and a building on a slope reads as a mistake.
			{ kind = "mound", center = KEEP_AT, radius = 165, amount = 62, sharpness = 1.7 },
			{ kind = "flat", center = KEEP_AT, radius = 66, height = 68, blend = 1.25 },
			--: Deep and wide enough to actually hold water. The first pass sank
			--: 38 studs over a 118 radius and produced a puddle you could step
			--: over, because only the ground *below* sea level becomes lake.
			{ kind = "basin", center = WATER_AT, radius = 132, amount = 58, sharpness = 1.3 },
			--: The two halves of the village stand on these. Pulled outward and
			--: shrunk from the first pass so the basin between them has room to
			--: fill -- a flat listed after a basin overwrites it, and at the
			--: old radius the two pads met in the middle and drained the lake.
			{ kind = "flat", center = Vector2.new(-178, ROAD_Z), radius = 88,
			  height = 16, blend = 1.6 },
			{ kind = "flat", center = Vector2.new(178, ROAD_Z), radius = 84,
			  height = 17, blend = 1.6 },
		},
		floor = 0,
	})

	local report = World.paint(field, {
		resolution = 4,
		chunk = 96,
		clear = true,
		seaLevel = SEA_LEVEL,
		--[[
			Painted well past the island, so the sea has somewhere to be.

			The falloff ends the land; without this the *water* also ended, at
			the paint region's square edge, and the whole place read as a
			diorama floating on a slab. Beyond the falloff radius the field
			returns its minimum height, which is below sea level, so every one
			of these extra chunks is two voxels of water and costs almost
			nothing to write.
		]]
		bounds = {
			min = Vector2.new(-SEA_EXTENT, -SEA_EXTENT),
			max = Vector2.new(SEA_EXTENT, SEA_EXTENT),
		},
		material = function(x, z, height, slope)
			--: Material reads the shape rather than a zone table: a steep face
			--: is rock wherever it is, a shoreline is sand wherever it is. The
			--: road is the one exception, drawn rather than derived.
			if math.abs(z - ROAD_Z) < 13 and x > ROAD_FROM and x < ROAD_TO then
				return Enum.Material.Ground
			end
			if height < SEA_LEVEL + 3 then
				return Enum.Material.Sand
			end
			if slope < 0.62 then
				return Enum.Material.Rock
			end
			if height > 56 then
				return Enum.Material.Slate
			end
			--: A band of a second green above the meadow. One material over a
			--: whole hillside is the flattest a landscape can look, and this is
			--: the cheapest thing that breaks it up.
			if height > 34 then
				return Enum.Material.LeafyGrass
			end
			return Enum.Material.Grass
		end,
	})
	Debug.info(string.format("ground: %d of %d chunks",
		report.written or 0, report.attempted or 0))
	return field
end

-- ============================== the village =================================
--[[
	Houses along the road, facing it.

	The arrangement is the whole difference between a village and four houses.
	They alternate sides, sit back a consistent margin, and turn to look at the
	road -- which is what makes a road read as a street rather than as a stripe
	of different-coloured ground.
]]
local function village(parent: Instance, stream: any): number
	local placed = 0
	local spots = { -215, -180, -145, -110, 105, 140, 175, 210 }

	for index, x in spots do
		local side = if index % 2 == 0 then 1 else -1
		local backFrom = ROAD_Z + side * stream:number(30, 40)
		local at = World.surface(x, backFrom)
		if at then
			--: A model's front is -Z, so a house on the +Z side turns half a
			--: turn to face back across the road.
			local yaw = (if side > 0 then math.pi else 0) + stream:number(-0.12, 0.12)
			if put("house", index * 31, at, yaw, parent, stream:number(0.85, 1.15)) then
				placed += 1
			end

			--[[
				A yard around each house.

				The single largest thing separating a village from eight houses
				in a field. A house with a barrel by the door, a crate against
				the wall and a bench out front reads as lived in; the same house
				alone reads as a placed asset, however good the model is.
			]]
			local yard = { "barrel", "crate", "bench", "wooden sign", "fence",
				"bush", "flower", "log", "rock" }
			for _ = 1, 7 do
				local spot = World.surface(
					x + stream:number(-26, 26),
					backFrom + side * stream:number(-16, 22))
				if spot then
					local topic = yard[stream:int(1, #yard)]
					if put(topic, math.floor(stream:number(1, 9999)), spot,
							stream:number(0, 6.28), parent,
							stream:number(0.8, 1.25)) then
						placed += 1
					end
				end
			end
		end

		--: The front fence, on the road's own line so the plots read as plots.
		for step = -1, 1 do
			local fenceAt = World.surface(x + step * 13, ROAD_Z + side * 21)
			if fenceAt and put("fence", index + step, fenceAt,
					if side > 0 then math.pi else 0, parent) then
				placed += 1
			end
		end
		local lampAt = World.surface(x + 22, ROAD_Z + side * 16)
		if lampAt and put("street lamp", index, lampAt, 0, parent) then
			placed += 1
		end
	end

	--: Roadside furniture on the road's own line, so it reads as placed rather
	--: than as scatter that happened to land there.
	for index = 1, 26 do
		local x = stream:number(ROAD_FROM + 30, ROAD_TO - 30)
		local side = if stream:number(0, 1) > 0.5 then 1 else -1
		local at = World.surface(x, ROAD_Z + side * stream:number(15, 19))
		if at then
			local topic = ({ "bench", "barrel", "crate", "wooden sign",
				"flower", "bush" })[stream:int(1, 6)]
			if put(topic, index * 17, at, stream:number(0, 6.28), parent) then
				placed += 1
			end
		end
	end
	return placed
end

-- =============================== the keep ===================================
local function keep(parent: Instance, stream: any): number
	local placed = 0
	local at = World.surface(KEEP_AT.X, KEEP_AT.Y)
	if at and put("castle", 3, at, 0, parent) then
		placed += 1
	end

	--[[
		A wall ring facing outward, with towers on the diagonals.

		Sixteen segments rather than eight: at eight the gaps were wider than
		the segments and the ring read as scattered stones, not as a wall. The
		towers are what stop a continuous ring from reading as a fence.
	]]
	for index = 1, 16 do
		local angle = (index / 16) * math.pi * 2
		local wallAt = World.surface(
			KEEP_AT.X + math.sin(angle) * 84,
			KEEP_AT.Y + math.cos(angle) * 84)
		if wallAt and put("wall", index, wallAt, angle, parent) then
			placed += 1
		end
	end
	for index = 1, 4 do
		local angle = (index / 4) * math.pi * 2 + math.pi / 4
		local towerAt = World.surface(
			KEEP_AT.X + math.sin(angle) * 84,
			KEEP_AT.Y + math.cos(angle) * 84)
		if towerAt and put("watchtower", index, towerAt, angle, parent) then
			placed += 1
		end
	end

	for index = 1, 34 do
		local angle = stream:number(0, math.pi * 2)
		local radius = stream:number(18, 74)
		local inside = World.surface(
			KEEP_AT.X + math.sin(angle) * radius,
			KEEP_AT.Y + math.cos(angle) * radius)
		if inside then
			--: Every name here is a topic the catalogue actually has. It is
			--: worth checking: `put` returns nil for an unknown topic and the
			--: loop counts it as "nothing fit", so a typo like `treasure` for
			--: `treasure chest` empties a third of the courtyard silently.
			local topic = ({ "altar", "anvil", "armor", "sword", "shield",
				"treasure chest", "coffin", "candle", "barrel", "torch",
				"crate", "campfire", "rock", "ladder", "shop stand",
				"magic staff", "gem" })[stream:int(1, 17)]
			if put(topic, index * 13, inside, stream:number(0, 6.28), parent) then
				placed += 1
			end
		end
	end
	return placed
end

-- ============================== the crossing ================================
local function crossing(parent: Instance, stream: any): number
	local placed = 0

	--[[
		The deck is built, not placed.

		Every model under the `bridge` topic is a *section* -- and the one the
		catalogue ranks first is a pier column, which put seven grey posts in
		the lake and nothing to walk on. There is no model in 295 that spans
		two hundred studs, and pretending otherwise produces exactly that.

		So the deck is authored geometry: planks, kerbs, rails. Six parts. The
		catalogue's job here is the dressing -- the piers standing in the water
		under it, which is the part a pack does model well.

		This is the honest division generally. Bought models are furniture;
		anything load-bearing, sized to the world rather than to itself, has to
		come from the world.
	]]
	local span = 122
	local deckWide = 15

	local function slab(name: string, size: Vector3, at: Vector3,
	                    colour: Color3, material: Enum.Material)
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size
		part.CFrame = CFrame.new(at)
		part.Anchored = true
		part.CanCollide = true
		part.Color = colour
		part.Material = material
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = parent
		placed += 1
	end

	slab("Deck", Vector3.new(span * 2, 1.4, deckWide),
		Vector3.new(WATER_AT.X, DECK_Y, WATER_AT.Y),
		Color3.fromRGB(126, 96, 62), Enum.Material.WoodPlanks)

	for _, side in { -1, 1 } do
		slab("Kerb", Vector3.new(span * 2, 1.2, 1.6),
			Vector3.new(WATER_AT.X, DECK_Y + 1.3,
				WATER_AT.Y + side * (deckWide / 2 - 0.8)),
			Color3.fromRGB(104, 78, 50), Enum.Material.Wood)
		slab("Rail", Vector3.new(span * 2, 0.5, 0.5),
			Vector3.new(WATER_AT.X, DECK_Y + 4.2,
				WATER_AT.Y + side * (deckWide / 2 - 0.8)),
			Color3.fromRGB(112, 86, 56), Enum.Material.Wood)
	end

	--: Ramps at both ends, so the deck meets the shore instead of ending in a
	--: step the height of the water.
	for _, side in { -1, 1 } do
		local ramp = Instance.new("WedgePart")
		ramp.Name = "Approach"
		ramp.Size = Vector3.new(deckWide, 5, 18)
		ramp.CFrame = CFrame.new(WATER_AT.X + side * (span + 9), DECK_Y - 2.6,
			WATER_AT.Y) * CFrame.Angles(0, side * math.pi / 2, 0)
		ramp.Anchored = true
		ramp.Color = Color3.fromRGB(122, 106, 84)
		ramp.Material = Enum.Material.Ground
		ramp.Parent = parent
		placed += 1
	end

	--: The piers. Model work, sized to the gap between deck and water, which
	--: is what these were modelled for.
	local piers = 7
	for index = 0, piers - 1 do
		local x = -span * 0.86 + (index / (piers - 1)) * span * 1.72
		for _, side in { -1, 1 } do
			--: Standing on the lake bed and reaching the deck: `put` sets a
			--: model's *bottom* at the point given, so a pier asked to be at
			--: deck height would sit on top of the road.
			if put("bridge", 5,
					Vector3.new(WATER_AT.X + x, SEA_LEVEL - 3,
						WATER_AT.Y + side * (deckWide / 2 - 1)),
					0, parent, 0.78) then
				placed += 1
			end
		end
	end

	--: Lamps along it. A crossing at night with nothing on it is a plank; the
	--: lamps are what make it read as built rather than dropped.
	for index = 0, 3 do
		local x = -span * 0.7 + (index / 3) * span * 1.4
		if put("street lamp", index, Vector3.new(WATER_AT.X + x, DECK_Y + 0.7,
				WATER_AT.Y + (if index % 2 == 0 then -1 else 1) * (deckWide / 2 - 2)),
				0, parent, 0.85) then
			placed += 1
		end
	end

	--: A shoreline. Rocks and reeds at the waterline are what stop a lake from
	--: reading as a hole somebody filled in.
	--:
	--: Tried far more times than it will place: the filter is a height band a
	--: few studs wide, and most rolls land outside it. Counting attempts as
	--: results is how the first pass ended up with a bare shore.
	for index = 1, 600 do
		local angle = stream:number(0, math.pi * 2)
		local radius = stream:number(52, 138)
		local x = WATER_AT.X + math.sin(angle) * radius
		local z = WATER_AT.Y + math.cos(angle) * radius
		--: The causeway's own corridor stays clear, or the crossing ends in
		--: reeds and the road stops looking like a road.
		if math.abs(z - ROAD_Z) < 15 then
			continue
		end
		local shore = World.surface(x, z)
		if shore and shore.Y > SEA_LEVEL - 2 and shore.Y < SEA_LEVEL + 12 then
			local topic = ({ "rock", "bush", "log", "grass patch", "flower",
				"grass patch", "bush" })[stream:int(1, 7)]
			if put(topic, index * 7, shore, stream:number(0, 6.28), parent,
					stream:number(0.7, 1.4)) then
				placed += 1
			end
		end
	end
	return placed
end

-- =============================== the forest =================================
--[[
	Trees, thinning toward the road.

	Falling density near the road is what makes the road feel cut through the
	forest rather than drawn on top of it, and it keeps the village visible,
	which a uniform forest would not.
]]
local function forest(parent: Instance, stream: any): number
	local placed = 0
	--: 1200 rolls for perhaps 500 trees. Most are rejected -- the road corridor,
	--: the keep, the lake, water level, the thinning roll -- so the number that
	--: matters is what survives, and the only way to find it is to run it.
	for index = 1, 1200 do
		local x = stream:number(-HALF + 30, HALF - 30)
		local z = stream:number(-HALF + 30, HALF - 30)

		if math.abs(z - ROAD_Z) < 26 and x > ROAD_FROM and x < ROAD_TO then
			continue
		end
		if (Vector2.new(x, z) - KEEP_AT).Magnitude < 96 then
			continue
		end
		if (Vector2.new(x, z) - WATER_AT).Magnitude < 74 then
			continue
		end

		local at = World.surface(x, z)
		if not at or at.Y < SEA_LEVEL + 2 then
			continue
		end

		--: Thicker further from the road. Rolled on position, not on index, so
		--: the thinning is about where a tree is rather than when it was tried.
		local fromRoad = math.min(math.abs(z - ROAD_Z) / 150, 1)
		if stream:number(0, 1) > 0.30 + fromRoad * 0.62 then
			continue
		end

		--: Undergrowth outnumbers trees, which is what a forest floor looks
		--: like and what keeps the ground from being a green sheet between
		--: trunks.
		--: One rock in fourteen. The topic has four models and they are boxy;
		--: at one in eight the forest floor read as scattered grey crates.
		local topic = ({ "tree", "tree", "tree", "tree", "tree", "bush",
			"bush", "bush", "log", "flower", "flower", "grass patch",
			"grass patch", "rock" })[stream:int(1, 14)]
		if put(topic, index * 7919, at, stream:number(0, 6.28), parent,
				stream:number(0.75, 1.35)) then
			placed += 1
		end
	end
	return placed
end

-- ================================= start ====================================
function Yard.start()
	Visual.defineLook("yard", {
		--: Late morning, warm and clear: bright enough that the stylised
		--: palette reads, hazy enough that the far rim is distance.
		ambient = Color3.fromRGB(112, 116, 128),
		outdoorAmbient = Color3.fromRGB(184, 190, 204),
		brightness = 3.0,
		clockTime = 10.2,
		geographicLatitude = 28,
		--: Short enough that the far rim of the sea is haze rather than a line.
		--: Fog is doing the work a skybox would do in a finished game.
		fogStart = 420,
		fogEnd = 1150,
		fogColor = Color3.fromRGB(178, 210, 238),
		atmosphere = {
			density = 0.22, haze = 0.9, glare = 0.2,
			color = Color3.fromRGB(216, 232, 248),
			decay = Color3.fromRGB(130, 152, 182),
		},
		bloom = { intensity = 0.5, size = 22, threshold = 1.6 },
		colorCorrection = { contrast = 0.09, saturation = 0.16,
			tint = Color3.fromRGB(255, 252, 246) },
	})
	Visual.apply("yard")
	Material.palette("stylised")
	Material.water(Color3.fromRGB(60, 140, 170),
		{ reflectance = 0.35, transparency = 0.55, waveSize = 0.12, waveSpeed = 8 })

	local parent = Workspace:FindFirstChild("Props") or Workspace
	ground()

	--[[
		The spawn goes down before anything else, and claims its ground.

		A player arriving inside a tree is the first thing they see, so it
		outranks every other placement -- and the only way to guarantee it is to
		reserve the circle before the scatter runs rather than to clean up
		afterwards.
	]]
	local spawnAt = World.surface(SPAWN_AT.X, SPAWN_AT.Y)
	if spawnAt then
		local pad = Instance.new("SpawnLocation")
		pad.Name = "Start"
		pad.Size = Vector3.new(16, 1, 16)
		pad.CFrame = CFrame.new(spawnAt + Vector3.new(0, 0.5, 0))
		pad.Anchored = true
		pad.Material = Enum.Material.Concrete
		pad.Color = Color3.fromRGB(198, 202, 210)
		pad.TopSurface = Enum.SurfaceType.Smooth
		pad.Parent = Workspace
	end

	local stream = Rng.stream("yard.compose")
	local counts = {
		village = village(parent, stream),
		keep = keep(parent, stream),
		crossing = crossing(parent, stream),
		forest = forest(parent, stream),
	}

	local total = counts.village + counts.keep + counts.crossing + counts.forest
	Debug.info(string.format(
		"yard: %d props (village %d, keep %d, crossing %d, forest %d), %d assets",
		total, counts.village, counts.keep, counts.crossing, counts.forest,
		Place.fetched()))

	Debug.probe("yard", function()
		return {
			placed = total,
			byArea = counts,
			assets = Place.describe(),
			catalogue = Itch.describe(),
		}
	end)
end

return Yard
