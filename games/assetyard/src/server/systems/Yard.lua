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
	normalises nothing. `HEIGHTS` declares what each topic should measure and
	everything is scaled to reach it. Without it, three sofas tower over the
	world and nothing else is visible.

	**Thin topics repeat.** Nine topics have exactly one model published, so
	asking for four gives the same model four times. Where a topic is thin this
	leans on placement -- rotation, spacing, scale jitter -- to keep repetition
	from reading as copy-paste.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local InsertService = game:GetService("InsertService")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Itch = Forge.Catalog.ItchAssets
local Tint = Forge.Catalog.Tint
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
	What each topic should measure, in studs.

	Hand-written, and that is a stated limit: it covers the 67 topics published
	and would not survive 12,000 models. Measuring authored height and
	normalising per category automatically is the next step.
]]
local HEIGHTS: { [string]: number } = {
	--: Trees and buildings carry the silhouette, so they are sized against the
	--: hill and the horizon rather than against a player. At 24 studs a tree
	--: read as a shrub from the road; at 34 it reads as a tree.
	tree = 34, bush = 5, rock = 4, log = 3, flower = 1.6, ["grass patch"] = 1.4,
	house = 26, fence = 5, door = 8, window = 5, ["street lamp"] = 12,
	bench = 3, ["wooden sign"] = 4.5, barrel = 4, crate = 3, bridge = 12,
	wall = 20, road = 1, platform = 2,
	chair = 4, table = 3, bed = 3, sofa = 3, bookshelf = 7,
	["desk lamp"] = 2, rug = 1, ["kitchen counter"] = 4, refrigerator = 7,
	conveyor = 3, dropper = 6, furnace = 7, generator = 5,
	["storage tank"] = 12, pipe = 3, ["mine cart"] = 4, ore = 3,
	pickaxe = 3, ["factory machine"] = 8,
	--: The one landmark. Sized to be read from the far end of the road, which
	--: is the only reason to put a building on a hill.
	castle = 105, altar = 4, anvil = 3, sword = 4, shield = 3,
	potion = 1, ["magic staff"] = 5, ["treasure chest"] = 3, coffin = 3,
	candle = 1.5, coin = 1, gem = 1.4, egg = 2, armor = 6,
	torch = 4, campfire = 3, ladder = 8, ["shop stand"] = 7, portal = 10,
	watchtower = 34, barricade = 4, sandbag = 2, ["ammo box"] = 2,
	["military crate"] = 3, ["shooting target"] = 5, rifle = 4, pistol = 2,
}
local DEFAULT_HEIGHT = 5

--[[
	How wide a topic is allowed to be, as a multiple of its height.

	Normalising height alone is not enough, and the failure is spectacular: a
	bush modelled 1 unit tall and 20 wide, scaled until it is 5 studs tall,
	becomes 100 studs across. One of those filled a third of the frame and read
	as a hill.

	So each topic also declares a proportion, and whichever limit binds first
	wins. A squat model then stays squat instead of reaching its target height,
	which is the right answer -- the target is what a tree should measure, not
	a promise that every model is tree-shaped.
]]
local SPREAD: { [string]: number } = {
	road = 24, rug = 8, platform = 6, bridge = 5, wall = 3.5,
	fence = 4, house = 2.6, castle = 2.4, watchtower = 1.8,
	log = 6, ["grass patch"] = 3, ["shooting target"] = 3,
	bench = 4, sofa = 3.5, bed = 3, table = 3, ["kitchen counter"] = 4,
	conveyor = 5, pipe = 6, sword = 4, ["magic staff"] = 5,
	rifle = 5, pistol = 3, coin = 4, gem = 2.5, campfire = 3,
}
local DEFAULT_SPREAD = 2.2

--: Everything else is scenery you walk through. A mesh pack models a house
--: as a shell, and a shell given collision is a box you cannot enter -- so
--: only the things a player is meant to stand *on* get it.
local SOLID: { [string]: boolean } = { bridge = true, platform = true }

local function count(table_: { [any]: any }): number
	local n = 0
	for _ in table_ do
		n += 1
	end
	return n
end

-- ============================== fetching ====================================
--: One fetch per asset, cloned thereafter. `LoadAsset` yields and costs a round
--: trip; placing 400 props by calling it 400 times spends minutes re-fetching
--: models already in hand.
local loaded: { [number]: Instance } = {}
local missing: { [number]: boolean } = {}

--: One stream for the tint pass, so a world generated twice is coloured the
--: same way. Shared across every placement rather than derived per prop,
--: because the variation wanted here is between neighbours, not between runs.
local tintStream = Rng.stream("yard.tint")

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

-- ============================== measuring ===================================
--[[
	The true world box of a model, computed from its parts.

	Not `GetExtentsSize`, and this is the second time that call has cost a
	rebuild. It returns the box *in the pivot's frame*, and an imported mesh's
	pivot is wherever the pack's exporter left it -- often the modelling
	origin, which for a tree is under the roots and for a rock is the middle of
	the stone.

	Placing by `at + height/2` therefore assumes the pivot sits at the centre
	of the model. When it does not, the model floats above the ground by the
	offset, or sinks into it: a whole world of props hovering, from one
	assumption that reads as obviously true.

	This measures the axis-aligned box every part actually occupies, so the
	answer does not depend on where the pivot is or how the model is turned.
	`half` is the standard oriented-box projection: each local axis contributes
	its own length times how much of that axis points along world Y.
]]
local function bounds(model: Instance): (Vector3, Vector3)
	local low = Vector3.new(math.huge, math.huge, math.huge)
	local high = Vector3.new(-math.huge, -math.huge, -math.huge)

	local parts: { Instance } = if model:IsA("BasePart")
		then { model }
		else model:GetDescendants()

	for _, instance in parts do
		if not instance:IsA("BasePart") then
			continue
		end
		local part = instance :: BasePart
		local frame, size = part.CFrame, part.Size
		local right, up, look = frame.RightVector, frame.UpVector, frame.LookVector
		local half = Vector3.new(
			0.5 * (math.abs(right.X) * size.X + math.abs(up.X) * size.Y
				+ math.abs(look.X) * size.Z),
			0.5 * (math.abs(right.Y) * size.X + math.abs(up.Y) * size.Y
				+ math.abs(look.Y) * size.Z),
			0.5 * (math.abs(right.Z) * size.X + math.abs(up.Z) * size.Y
				+ math.abs(look.Z) * size.Z))
		low = low:Min(frame.Position - half)
		high = high:Max(frame.Position + half)
	end

	if low.X == math.huge then
		return Vector3.zero, Vector3.zero
	end
	return low, high
end

local function move(model: Instance, delta: Vector3)
	if model:IsA("Model") then
		local m = model :: Model
		m:PivotTo(m:GetPivot() + delta)
	else
		local part = model :: BasePart
		part.CFrame = part.CFrame + delta
	end
end

-- ============================== placing =====================================
local function put(topic: string, seed: number, at: Vector3, yaw: number,
                   parent: Instance, jitter: number?): Instance?
	--: The spawn's circle, refused here rather than cleaned up later. Checked
	--: before the asset is even chosen, because the cheapest rejection is the
	--: one that happens before the work.
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

	local assetId = Itch.pick(topic, seed, true) or Itch.pick(topic, seed, false)
	if not assetId then
		return nil
	end
	local source = template(assetId)
	if not source then
		return nil
	end

	local model = source:Clone()

	--: Turned first, then measured, then scaled, then measured again. Rotation
	--: changes the world box, so measuring before turning gives a number that
	--: no longer describes the thing being placed.
	if model:IsA("Model") then
		local m = model :: Model
		m:PivotTo(CFrame.new(m:GetPivot().Position) * CFrame.Angles(0, yaw, 0))
	else
		local part = model :: BasePart
		part.CFrame = CFrame.new(part.Position) * CFrame.Angles(0, yaw, 0)
	end

	local low, high = bounds(model)
	local raw = high - low
	local wanted = (HEIGHTS[topic] or DEFAULT_HEIGHT) * (jitter or 1)

	--: Whichever limit binds first. Height alone lets a wide flat model grow
	--: sideways without bound; width alone lets a tall thin one stay tiny.
	local byHeight = if raw.Y > 0.01 then wanted / raw.Y else 1
	local widest = math.max(raw.X, raw.Z)
	local allowed = wanted * (SPREAD[topic] or DEFAULT_SPREAD)
	local byWidth = if widest > 0.01 then allowed / widest else byHeight
	local factor = math.min(byHeight, byWidth)

	if model:IsA("Model") then
		(model :: Model):ScaleTo(factor)
	else
		local part = model :: BasePart
		part.Size = part.Size * factor
	end

	low, high = bounds(model)
	local size = high - low

	--: Now the placement is exact: put the box's *bottom* on the ground and
	--: its footprint's centre over the point, whatever the pivot thinks.
	--: Sunk very slightly, so an uneven base does not stand on a visible seam.
	local sink = math.min(size.Y * 0.04, 0.5)
	local centre = (low + high) * 0.5
	move(model, Vector3.new(
		at.X - centre.X,
		at.Y - low.Y - sink,
		at.Z - centre.Z))

	local solid = SOLID[topic] == true
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = solid
			part.CanTouch = false
			--: Shadows only where the silhouette is big enough to read one.
			part.CastShadow = size.Y > 6
		end
	end
	if model:IsA("BasePart") then
		local part = model :: BasePart
		part.Anchored = true
		part.CanCollide = solid
	end

	--: Two thirds of these models carry no colour: the packs modelled them
	--: with plain materials and the importer keeps geometry, not that. Without
	--: this pass the world is white -- and it is the structural topics (house,
	--: tree, castle, rock) that have no coloured member at all, so the gap is
	--: exactly where it shows most.
	Tint.applyVaried(model, topic, tintStream)

	model.Parent = parent
	return model
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
		total, counts.village, counts.keep, counts.crossing, counts.forest, count(loaded)))

	Debug.probe("yard", function()
		return {
			placed = total,
			byArea = counts,
			assetsFetched = count(loaded),
			assetsMissing = count(missing),
			catalogue = Itch.describe(),
		}
	end)
end

return Yard
