--!strict
--[[
	Grove — the yard as a place you can stand in.

	`Yard` decides what a chop means; this builds the thing you walk up to and
	chop. Keeping those apart is what let the whole economy be played through
	in a second, forty simulated minutes at a time, before a single Part
	existed.

	One yard per player, laid out on its own island
	----------------------------------------------

	Six players share a server and each gets a plot of land far enough from the
	others that nothing overlaps and near enough that you can see somebody
	else's Amberheart from yours. Seeing a stranger's rare tree is most of why
	a tycoon is multiplayer at all.

	Trees are the catalogue's, scaled by the engine
	-----------------------------------------------

	`Catalog.Place` fetches, normalises and grounds the model; `Catalog.Tint`
	colours it, because two thirds of these models arrive grey. The species'
	own colours are pushed in afterwards so an Ebony reads as Ebony rather than
	as the generic green every tree in the pack shares.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Trees = require(ReplicatedStorage.Shared.Trees)
local Yard = require(script.Parent.Yard)
local Timber = require(script.Parent.Timber)

local Place = Forge.Catalog.Place
local Itch = Forge.Catalog.ItchAssets
local Tint = Forge.Catalog.Tint
local Rng = Forge.Core.Rng

local Grove = {}

--: Yard spacing. Wide enough that a twelve-plot yard never touches its
--: neighbour, close enough to see one.
--[[
	One island, not seven.

	The first layout gave the plaza a 58-stud pad and each yard a 96-stud pad
	on a 120-stud ring, and everything between them was sky. You could see your
	neighbour's yard and there was no ground to walk to it on -- six separate
	worlds sharing a skybox. A tycoon's whole social claim is that the person
	next to you is real, and a void between you contradicts it.

	So: one continuous base, yards standing on it further apart than before,
	and a boardwalk that physically connects every yard to the middle.
]]
local BASE_SIZE = 530
local YARD_SPAN = 158
local YARD_PAD = 104
local PLAZA_RADIUS = 46
local PATH_WIDTH = 14
local PLOT_GAP = 25
local GROUND_Y = 0

local yards: { [Player]: any } = {}
local bySlot: { [number]: any } = {}
local stream = Rng.stream("carvewood.grove")

-- ================================ the ground ================================
local function slab(name: string, size: Vector3, at: Vector3, colour: Color3,
                    material: Enum.Material, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(at)
	part.Anchored = true
	part.Color = colour
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[
	Where a player's yard sits.

	Laid out on a ring rather than a row. A row makes the first and last
	players neighbours of one person each and everybody else neighbours of
	two, and the player at the end of a row feels like an afterthought.
]]
--[[
	Where a player's shop building stands on their yard.

	Behind the plots and off to one side, so it is between the yard and the
	boardwalk: a customer walking in from the ring reaches the shop without
	crossing the trees, and the owner sees their own shelves from where they
	chop.
]]
--[[
	The edge of the world, as cliffs.

	The base is a flat slab and beyond it was sky. A player who walks to the
	edge of a tycoon and finds nothing there has been shown the seams, and
	fixing it with an invisible wall shows them twice: they stop walking for no
	visible reason.

	So the island ends in rock. Chunky blocks at uneven heights and angles --
	cartoon cliff, not terrain -- capped with the same grass as the lawn so the
	ground appears to run over the edge and stop. They collide, so the wall is
	the thing that stops you and you can see why.
]]
local RIM_STONE = {
	Color3.fromRGB(146, 140, 130), Color3.fromRGB(128, 122, 114),
	Color3.fromRGB(160, 152, 140),
}

function Grove.rim(parent: Instance)
	local radius = BASE_SIZE / 2 - 6
	local segments = 56
	for index = 0, segments - 1 do
		local angle = (index / segments) * math.pi * 2
		local dir = Vector3.new(math.sin(angle), 0, math.cos(angle))
		local at = dir * radius

		--: Uneven on purpose. A ring of identical blocks reads as a fence and
		--: the whole point is that it reads as land.
		local height = stream:number(16, 30)
		local width = (math.pi * 2 * radius / segments) * stream:number(1.5, 2.1)
		local lean = stream:number(-0.09, 0.09)

		local rock = Instance.new("Part")
		rock.Name = "Cliff"
		rock.Size = Vector3.new(width, height, stream:number(14, 22))
		rock.Anchored = true
		rock.Color = RIM_STONE[stream:int(1, #RIM_STONE)]
		rock.Material = Enum.Material.Slate
		rock.TopSurface = Enum.SurfaceType.Smooth
		rock.BottomSurface = Enum.SurfaceType.Smooth
		rock.CFrame = CFrame.lookAt(
			Vector3.new(at.X, GROUND_Y + height / 2 - 5, at.Z),
			Vector3.new(at.X, GROUND_Y + height / 2 - 5, at.Z) + dir)
			* CFrame.Angles(lean, 0, lean * 0.6)
		rock.Parent = parent

		--: A grass cap, so the lawn appears to run over the lip rather than
		--: stopping at a stone kerb.
		local cap = Instance.new("Part")
		cap.Name = "CliffTop"
		cap.Size = Vector3.new(width, 2.2, rock.Size.Z)
		cap.Anchored = true
		cap.CanCollide = false
		cap.Color = Color3.fromRGB(118, 168, 78)
		cap.Material = Enum.Material.Grass
		cap.TopSurface = Enum.SurfaceType.Smooth
		cap.CFrame = rock.CFrame * CFrame.new(0, height / 2 + 0.4, 0)
		cap.Parent = parent
	end

	--[[
		And a sea to fall into, rather than through.

		Purely cosmetic -- the cliffs already stop the player. It is here so
		that looking out from the top of a five-storey shop shows a horizon
		instead of the inside of a skybox.
	]]
	local sea = Instance.new("Part")
	sea.Name = "Sea"
	sea.Size = Vector3.new(2600, 8, 2600)
	sea.CFrame = CFrame.new(0, GROUND_Y - 26, 0)
	sea.Anchored = true
	sea.CanCollide = false
	sea.Color = Color3.fromRGB(44, 122, 162)
	sea.Material = Enum.Material.Glass
	sea.Reflectance = 0.28
	sea.Transparency = 0.1
	sea.TopSurface = Enum.SurfaceType.Smooth
	sea.Parent = parent
end

function Grove.shopAnchor(anchor: Vector3): Vector3
	return anchor + Vector3.new(0, 0, 34)
end

function Grove.anchorFor(slot: number): Vector3
	local angle = (slot - 1) * (math.pi * 2 / 6)
	return Vector3.new(math.sin(angle) * YARD_SPAN, GROUND_Y,
		math.cos(angle) * YARD_SPAN)
end

-- ================================== a tree ==================================
local grown: { [number]: Instance } = {}

--[[
	A plot tree is built, not fetched; scenery is fetched, not built.

	The two want opposite things. On a plot the species has to be legible from
	across the yard -- the whole progression is "this one is rarer" -- and it
	has to be readable at half size as a sapling. `Timber` gives both: six
	silhouettes that differ on purpose, and one scale argument.

	Scenery wants the opposite: variety, detail, and no meaning at all. That is
	exactly what a catalogue of two dozen published tree models is good for,
	and none of it has to be distinguishable.
]]
local function treeModel(species: Trees.Species, at: Vector3, parent: Instance,
                         ready: boolean): Instance?
	return Timber.grow(species, at, parent, {
		--: A sapling is the same tree small. Growth legible from a distance is
		--: what makes a player walk over at the right moment.
		scale = if ready then 1.35 else 0.55,
		yaw = stream:number(0, math.pi * 2),
	})
end

--[[
	The forest the yards sit in.

	Six mown squares on a plain is a spreadsheet with grass on it. The ring is
	planted outside the yards, so every direction a player looks from their own
	plot has trees in it, and the horizon is not the edge of the world.
]]
--[[
	Two tones, by part name.

	Twenty-three of the catalogue's twenty-five trees arrive with no texture,
	so `Place`'s tint paints each one a single flat colour -- and a tree that
	is one colour from root to crown is a brown stick or a green blob. The
	trunk is separated out by name and the rest takes a leaf colour, which is
	the entire difference between the forest in the first screenshot and a
	forest.

	Anything that *does* carry a texture is an artist's decision and is left
	alone.
]]
--[[
	Bright, and flat-shaded on purpose.

	The first pass used `LeafyGrass` with these greens twenty per cent darker,
	and under `Future` lighting with global shadows the canopies came out
	almost black -- a night forest around a sunlit lawn. A leaf material that
	self-shadows is the wrong choice for a cartoon: the look wants a flat
	colour that stays the colour it is written as.
]]
local LEAF = {
	Color3.fromRGB(126, 194, 96), Color3.fromRGB(148, 210, 108),
	Color3.fromRGB(104, 178, 88), Color3.fromRGB(170, 216, 118),
}
local BARK = {
	Color3.fromRGB(108, 78, 52), Color3.fromRGB(92, 68, 46),
	Color3.fromRGB(126, 96, 64),
}

local function leafy(model: Instance, leaf: Color3, bark: Color3)
	local parts: { Instance } = if model:IsA("BasePart") then { model }
		else model:GetDescendants()
	for _, instance in parts do
		if not instance:IsA("BasePart") then
			continue
		end
		local part = instance :: BasePart
		if part:IsA("MeshPart") and (part :: MeshPart).TextureID ~= "" then
			continue
		end
		local name = string.lower(part.Name)
		local wood = string.find(name, "trunk", 1, true)
			or string.find(name, "bark", 1, true)
			or string.find(name, "stem", 1, true)
			or string.find(name, "branch", 1, true)
			or string.find(name, "wood", 1, true)
		part.Color = if wood then bark else leaf
		part.Material = if wood then Enum.Material.Wood
			else Enum.Material.SmoothPlastic
	end
end

--: The models worth showing. The catalogue also holds graveyard and desert
--: trees, and a bare grey trunk in the middle of a bright yard reads as a
--: bug rather than as variety.
local SCENERY_TREES = { "Tree Forest", "Tree01", "Tree02", "Tree03", "Tree04",
	"Tree05", "Tree06", "Tree07", "Tree08", "Tree 001", "Tree 01", "Tree 02",
	"Tree 04", "Tree 05" }

local function scenery(parent: Instance)
	local trees, props = 0, 0
	for index = 1, 110 do
		local angle = (index / 110) * math.pi * 2 + stream:number(-0.04, 0.04)
		--: Outside the yards, in a band rather than on a line: a perfect
		--: circle of trees reads as a fence.
		--: Outside the base entirely, so nothing in the forest can be walked
		--: into or mistaken for a plot.
		--[[
			Beyond the shops, inside the cliffs.

			A shop reaches 204 studs from the middle, and a treeline starting at
			196 put a trunk through a shelf. The band has to begin where the
			buildings end, which is also why the island grew: there was no room
			between them otherwise.
		]]
		local radius = stream:number(218, 250)
		local at = Vector3.new(math.sin(angle) * radius, GROUND_Y,
			math.cos(angle) * radius)
		local wanted = SCENERY_TREES[(index % #SCENERY_TREES) + 1]
		local assetId = Itch.named("tree", wanted)
		local model = if assetId
			then Place.build({
				--: `assetId` says which model; `topic` is still what tells
				--: `Scale` how big a tree is meant to be. Naming one does not
				--: excuse you from the other.
				assetId = assetId, topic = "tree", at = at, parent = parent,
				yaw = stream:number(0, math.pi * 2),
				--[[
					Smaller than the catalogue thinks a tree is.

					`Scale` normalises this topic to about 35 studs, which is
					honest for a real tree and wrong for this game: the trees a
					player grows are 8 to 17 studs, so a normalised forest
					stood three times their height and the gameplay disappeared
					into scenery. The backdrop has to lose that argument.
				]]
				jitter = stream:number(0.5, 0.72), tint = false })
			else Place.put(Itch, { topic = "tree", seed = index * 31 + 7,
				at = at, yaw = stream:number(0, math.pi * 2), parent = parent,
				jitter = stream:number(0.5, 0.72), tint = false })
		if model then
			leafy(model, LEAF[stream:int(1, #LEAF)], BARK[stream:int(1, #BARK)])
			trees += 1
		end
	end

--[[
		Undergrowth, and nowhere a building stands.

		Scattered by angle and radius alone the first time, which put bushes
		through the shop floor and a tree growing out of a shelf. A yard is a
		claim on the ground and the scatter has to respect it -- so anything
		landing inside one is dropped rather than nudged, because a nudge just
		moves the collision somewhere else.
	]]
	local function clearOfYards(at: Vector3): boolean
		for slot = 1, 6 do
			local anchor = Grove.anchorFor(slot)
			local flat = Vector3.new(at.X - anchor.X, 0, at.Z - anchor.Z)
			if math.abs(flat.X) < YARD_PAD / 2 + 14
					and math.abs(flat.Z) < YARD_PAD / 2 + 14 then
				return false
			end
			--: And the shop, which stands beyond the yard's own pad.
			local shop = Grove.shopAnchor(anchor)
			if (Vector3.new(at.X - shop.X, 0, at.Z - shop.Z)).Magnitude < 34 then
				return false
			end
		end
		--: The plaza and the boardwalk ring are walked on, not planted.
		local fromCentre = Vector3.new(at.X, 0, at.Z).Magnitude
		return fromCentre > PLAZA_RADIUS + 12
	end

	for index = 1, 90 do
		local angle = stream:number(0, math.pi * 2)
		local radius = stream:number(56, 190)
		local topic = stream:pick({ "bush", "bush", "rock", "log", "flower",
			"grass patch" }) or "bush"
		local at = Vector3.new(math.sin(angle) * radius, GROUND_Y,
			math.cos(angle) * radius)
		if not clearOfYards(at) then
			continue
		end
		local model = Place.put(Itch, {
			topic = topic, seed = index * 17 + 3, at = at,
			yaw = stream:number(0, math.pi * 2), parent = parent,
			jitter = stream:number(0.6, 1.0),
		})
		if model then
			props += 1
		end
	end
	return trees, props
end

-- ================================= building =================================
--[[
	Build one plot: a patch of soil, a prompt, and whatever is growing on it.

	The prompt's text is the interface for most of the game. It says what the
	action is *and* what it will cost or yield, because a player standing in
	front of a tree should not have to open a panel to find out what chopping
	does.
]]
local function buildPlot(yard: any, index: number)
	local origin = yard.anchor + Vector3.new(
		((index - 1) % 4 - 1.5) * PLOT_GAP,
		0,
		(math.floor((index - 1) / 4) - 1) * PLOT_GAP)

	local soil = slab("Plot" .. index, Vector3.new(17, 1.2, 17),
		origin + Vector3.new(0, 0.5, 0),
		Color3.fromRGB(96, 72, 48), Enum.Material.Ground, yard.folder)
	soil:SetAttribute("plot", index)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Act"
	prompt.ActionText = "Plant"
	prompt.ObjectText = "Plot " .. index
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = soil

	yard.plots[index] = { soil = soil, prompt = prompt, origin = origin,
		model = nil, species = nil, ready = nil }
	return yard.plots[index]
end

--: The two stations. A bench turns logs into carvings; a counter turns
--: carvings into cash. They are separate places on purpose: walking between
--: them is the rhythm of the game, and a single "sell everything" button
--: standing next to the trees would collapse it.
local function buildStations(yard: any)
	local benchAt = yard.anchor + Vector3.new(-30, 0, 0)
	local bench = slab("Bench", Vector3.new(10, 4, 6),
		benchAt + Vector3.new(0, 2, 0),
		Color3.fromRGB(126, 94, 62), Enum.Material.WoodPlanks, yard.folder)
	local carve = Instance.new("ProximityPrompt")
	carve.Name = "Carve"
	carve.ActionText = "Carve"
	carve.ObjectText = "Workbench"
	carve.HoldDuration = 0
	carve.MaxActivationDistance = 14
	carve.RequiresLineOfSight = false
	carve.Parent = bench
	yard.bench, yard.carvePrompt = bench, carve

	--[[
		The quick-sale counter, at 60%.

		It used to be the only way to sell and it paid full price. Now the shop
		is where the money is and this is the impatient option -- somewhere to
		dump a pile of Rough the crew produced while you were out, rather than
		a shelf you would ever choose.
	]]
	local counterAt = yard.anchor + Vector3.new(30, 0, 0)
	local counter = slab("Counter", Vector3.new(10, 4, 6),
		counterAt + Vector3.new(0, 2, 0),
		Color3.fromRGB(150, 120, 78), Enum.Material.Wood, yard.folder)
	local sell = Instance.new("ProximityPrompt")
	sell.Name = "Sell"
	sell.ActionText = "Quick sell"
	sell.ObjectText = "Counter"
	sell.HoldDuration = 0
	sell.MaxActivationDistance = 14
	sell.RequiresLineOfSight = false
	sell.Parent = counter
	yard.counter, yard.sellPrompt = counter, sell
end

--[[
	The world is built before anybody is in it.

	This used to run per player, from `arrive`, behind a `Save.await` that
	blocks for up to twelve seconds. A player joins in well under twelve
	seconds, so they arrived into a Workspace holding a Camera and nothing
	else, fell past `FallenPartsDestroyHeight`, and were deleted -- the first
	screenshot of this game is a character in freefall against an empty sky
	with a working HUD drawn over it. The HUD is why no error was raised: the
	client was fine, the server was fine, and there was simply no floor.

	So the six yards are geometry, not player state. They exist at t=0, they
	are claimed and released, and the profile only ever decides what grows on
	one.
]]
local plaza: Folder? = nil

--[[
	The shop in the middle, which is a building before it is a menu.

	The rail buttons already open these panels, so a hut at the centre is not
	strictly required -- and it is the thing that makes the middle of the map
	somewhere rather than a roundabout. A tycoon's centre is where you go to
	spend, and a player who has just sold their first carvings should have a
	direction to walk in.

	The prompts fire the same panels the rail does. Two doors into one room is
	correct here: one is where your thumb is, the other is where your eyes are.
]]
function Grove.shop(parent: Instance)
	local hut = Instance.new("Model")
	hut.Name = "Shop"
	hut.Parent = parent

	local FLOOR_Y = GROUND_Y + 0.4
	slab("Deck", Vector3.new(34, 1.2, 26), Vector3.new(0, FLOOR_Y, 0),
		Color3.fromRGB(176, 134, 88), Enum.Material.WoodPlanks, hut)

	--: Four posts and a roof rather than four walls: a player has to be able
	--: to see the counter from outside, or the building is an obstacle.
	for _, corner in { Vector3.new(-15, 0, -11), Vector3.new(15, 0, -11),
			Vector3.new(-15, 0, 11), Vector3.new(15, 0, 11) } do
		local post = slab("Post", Vector3.new(1.6, 12, 1.6),
			corner + Vector3.new(0, FLOOR_Y + 6, 0),
			Color3.fromRGB(122, 88, 58), Enum.Material.Wood, hut)
		post.CanCollide = false
	end

	local roof = slab("Roof", Vector3.new(40, 1.4, 32),
		Vector3.new(0, FLOOR_Y + 12.6, 0),
		Color3.fromRGB(168, 86, 62), Enum.Material.WoodPlanks, hut)
	roof.CanCollide = false
	local ridge = slab("Ridge", Vector3.new(42, 1.6, 6),
		Vector3.new(0, FLOOR_Y + 13.8, 0),
		Color3.fromRGB(142, 68, 50), Enum.Material.WoodPlanks, hut)
	ridge.CanCollide = false

	local sign = slab("Sign", Vector3.new(26, 5, 0.8),
		Vector3.new(0, FLOOR_Y + 15.6, 0),
		Color3.fromRGB(122, 88, 58), Enum.Material.Wood, hut)
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.CanvasSize = Vector2.new(1040, 200)
		gui.Parent = sign
		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.Text = "CARVE WOOD"
		text.TextScaled = true
		text.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json",
			Enum.FontWeight.Heavy)
		text.TextColor3 = Color3.fromRGB(248, 226, 170)
		text.Parent = gui
	end

	--: Two counters, facing out of opposite sides, so the hut is approachable
	--: from either half of the ring without walking around it.
	local function counter(name: string, action: string, object: string,
	                       at: Vector3, panel: string)
		local desk = slab(name, Vector3.new(12, 4.4, 4),
			at + Vector3.new(0, FLOOR_Y + 2.8, 0),
			Color3.fromRGB(150, 112, 72), Enum.Material.Wood, hut)
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "Open"
		prompt.ActionText = action
		prompt.ObjectText = object
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Parent = desk
		prompt:SetAttribute("panel", panel)
		return prompt
	end

	Grove.shopPrompts = {
		counter("Seeds", "Browse", "Seed Stall", Vector3.new(-9, 0, -11), "seeds"),
		counter("Upgrades", "Browse", "Upgrades", Vector3.new(9, 0, 11), "shop"),
	}
	return hut
end

function Grove.foundation()
	if plaza then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "Grove"
	folder.Parent = Workspace
	plaza = folder

	--[[
		The ground everything else stands on.

		One slab, wide enough to hold the plaza, the six yards and the walk
		between them. Everything above it is decoration on a floor that already
		exists -- which is the opposite of the first attempt, where each piece
		of the world brought its own floor and the gaps were sky.
	]]
	slab("Base", Vector3.new(BASE_SIZE, 4, BASE_SIZE),
		Vector3.new(0, GROUND_Y - 3, 0),
		Color3.fromRGB(108, 156, 72), Enum.Material.Grass, folder)

	--: The middle of the ring. Somewhere to land that is nobody's yard, and
	--: the vantage point the six yards were arranged around in the first
	--: place -- a tycoon whose neighbours are invisible is a single-player
	--: game with extra latency.
	local plaza = slab("Plaza", Vector3.new(PLAZA_RADIUS * 2, 1.4,
		PLAZA_RADIUS * 2), Vector3.new(0, GROUND_Y - 0.3, 0),
		Color3.fromRGB(198, 170, 122), Enum.Material.Sand, folder)
	local rim = Instance.new("SpecialMesh")
	rim.MeshType = Enum.MeshType.Cylinder
	rim.Scale = Vector3.new(1, 1, 1)
	rim.Parent = plaza
	plaza.Shape = Enum.PartType.Cylinder
	plaza.Size = Vector3.new(1.4, PLAZA_RADIUS * 2, PLAZA_RADIUS * 2)
	plaza.CFrame = CFrame.new(0, GROUND_Y - 0.3, 0) * CFrame.Angles(0, 0, math.pi / 2)
	rim:Destroy()

	--[[
		Boardwalks, because "you can see it" is not the same as "you can get
		there".

		Six spokes out to the yards and a ring joining them. The ring is what
		makes the neighbours reachable without crossing the middle every time,
		and it is the line a new player follows to discover that the other five
		yards exist at all.
	]]
	local function plank(name: string, from: Vector3, to: Vector3, width: number)
		local span = (to - from)
		local length = span.Magnitude
		if length < 1 then
			return
		end
		local board = Instance.new("Part")
		board.Name = name
		board.Anchored = true
		board.Size = Vector3.new(width, 0.6, length)
		board.CFrame = CFrame.lookAt(from + span / 2, to) 
		board.Color = Color3.fromRGB(168, 128, 82)
		board.Material = Enum.Material.WoodPlanks
		board.TopSurface = Enum.SurfaceType.Smooth
		board.BottomSurface = Enum.SurfaceType.Smooth
		board.Position = Vector3.new(board.Position.X, GROUND_Y + 0.2,
			board.Position.Z)
		board.Parent = folder
	end

	local RING_RADIUS = 92
	for slot = 1, 6 do
		local angle = (slot - 1) * (math.pi * 2 / 6)
		local dir = Vector3.new(math.sin(angle), 0, math.cos(angle))
		plank("Spoke" .. slot, dir * (PLAZA_RADIUS - 2),
			dir * (YARD_SPAN - YARD_PAD / 2 + 4), PATH_WIDTH)
	end
	--: The ring as a polygon. Twenty-four straight boards read as a curve and
	--: cost nothing; an actual torus mesh would have to come from somewhere.
	local SEGMENTS = 24
	for index = 0, SEGMENTS - 1 do
		local a = (index / SEGMENTS) * math.pi * 2
		local b = ((index + 1) / SEGMENTS) * math.pi * 2
		plank("Ring" .. index,
			Vector3.new(math.sin(a), 0, math.cos(a)) * RING_RADIUS,
			Vector3.new(math.sin(b), 0, math.cos(b)) * RING_RADIUS,
			PATH_WIDTH - 3)
	end

	Grove.shop(folder)

	--: The fallback spawn. Never removed, never claimed: whatever else goes
	--: wrong, there is always a floor under an arriving player.
	local pad = Instance.new("SpawnLocation")
	pad.Name = "PlazaSpawn"
	pad.Size = Vector3.new(12, 1, 12)
	pad.CFrame = CFrame.new(0, GROUND_Y + 0.5, 0)
	pad.Anchored = true
	pad.Neutral = true
	pad.Material = Enum.Material.WoodPlanks
	pad.Color = Color3.fromRGB(150, 120, 78)
	pad.Parent = folder

	for slot = 1, 6 do
		Grove.raise(slot)
	end

	Grove.rim(folder)

	local trees, props = scenery(folder)
	Grove.planted = { trees = trees, props = props }
end

--: One yard, unowned. Everything here is the same for every player; only the
--: sign and what grows on the plots ever differ.
function Grove.raise(slot: number): any
	local folder = Instance.new("Folder")
	folder.Name = "Yard" .. slot
	folder.Parent = plaza

	local anchor = Grove.anchorFor(slot)
	local yard = { player = nil, anchor = anchor, folder = folder,
		plots = {}, slot = slot }
	bySlot[slot] = yard

	--: Raised a little above the base so a yard reads as a plot of land rather
	--: than as a differently-coloured patch of the same lawn.
	slab("Ground", Vector3.new(YARD_PAD, 3, YARD_PAD),
		anchor + Vector3.new(0, GROUND_Y - 0.9, 0),
		Color3.fromRGB(126, 176, 84), Enum.Material.Grass, folder)
	slab("Kerb", Vector3.new(YARD_PAD + 5, 2, YARD_PAD + 5),
		anchor + Vector3.new(0, GROUND_Y - 1.6, 0),
		Color3.fromRGB(146, 110, 70), Enum.Material.WoodPlanks, folder)

	--: Behind the spawn pad, not through it. The pad sits at -42 and the sign
	--: was at -44 on all six yards -- two studs apart, so a player arrived
	--: standing inside their own nameplate.
	local sign = slab("Sign", Vector3.new(18, 7, 1),
		anchor + Vector3.new(0, 3.5, -56),
		Color3.fromRGB(126, 94, 62), Enum.Material.Wood, folder)
	local label = Instance.new("SurfaceGui")
	label.Face = Enum.NormalId.Front
	label.CanvasSize = Vector2.new(560, 240)
	label.Parent = sign
	local text = Instance.new("TextLabel")
	text.Name = "Owner"
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = "Open Yard"
	text.TextScaled = true
	text.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json",
		Enum.FontWeight.Bold)
	text.TextColor3 = Color3.fromRGB(244, 238, 226)
	text.Parent = label
	yard.sign = text

	--: One plot to start. `refresh` raises the rest as they are bought, so a
	--: yard never has to know how far its owner got before they arrived.
	buildPlot(yard, 1)
	buildStations(yard)

	local spawnPad = Instance.new("SpawnLocation")
	spawnPad.Name = "Spawn"
	spawnPad.Size = Vector3.new(8, 1, 8)
	--[[
		Facing the yard, not away from it.

		`CFrame.new(position)` faces +Z, and the plots are at -Z from here, so
		a player arrived looking at the treeline with their whole farm behind
		them. The first thing a tycoon has to show you is the thing you own.
	]]
	--[[
		On the plaza side, looking across the yard at the shop.

		It used to sit at `anchor + 34Z`, which is exactly where the shop was
		later built -- so a player spawned *inside* their own building, facing
		its back wall. From here the plots are in front of them and the shop's
		open front is beyond, which is the whole loop laid out in one view.
	]]
	spawnPad.CFrame = CFrame.lookAt(anchor + Vector3.new(0, 0.5, -42), anchor)
	spawnPad.Anchored = true
	--[[
		Neutral, and that is not cosmetic.

		A `SpawnLocation` with `Neutral = false` in a game with no Teams accepts
		nobody at all: the check is "does the player's team match my
		TeamColor", and a player with no team never matches. This pad was
		written that way and so was unusable by the one player it was built
		for. Ownership is `player.RespawnLocation`, which is the property that
		actually means "this player spawns here".
	]]
	spawnPad.Neutral = true
	spawnPad.Enabled = false
	spawnPad.Material = Enum.Material.WoodPlanks
	spawnPad.Color = Color3.fromRGB(140, 108, 74)
	spawnPad.Parent = folder
	yard.spawnPad = spawnPad

	return yard
end

--[[
	Hand a standing yard to a player.

	Claiming is a rename and a respawn point, not a construction. That is the
	whole reason for the split: a player who joins during a lag spike gets the
	same solid ground as one who joins on an idle server.
]]
function Grove.claim(player: Player, slot: number, state: Yard.State): any
	local yard = bySlot[slot]
	if not yard then
		return nil
	end
	yard.player = player
	yards[player] = yard
	yard.folder.Name = "Yard_" .. player.Name
	yard.sign.Text = player.DisplayName .. "'s Yard"
	yard.spawnPad.Enabled = true
	player.RespawnLocation = yard.spawnPad

	for index = #yard.plots + 1, state.slots do
		buildPlot(yard, index)
	end

	--: Already standing on the plaza, so move them rather than waiting for a
	--: death. Walking to your own yard past five strangers' is the tour, but
	--: only once you know which one is yours.
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.CFrame = yard.spawnPad.CFrame + Vector3.new(0, 4, 0)
	end
	return yard
end

--[[
	Give the yard back, standing.

	Only what the leaver grew comes down. Destroying the island would take the
	floor out from under the next player to be handed this slot, which is the
	same defect as building it late, arriving from the other direction.
]]
function Grove.release(player: Player)
	local yard = yards[player]
	yards[player] = nil
	if not yard then
		return
	end
	for _, view in yard.plots do
		if view.model then
			view.model:Destroy()
			view.model = nil
		end
		view.species, view.ready = nil, nil
		view.prompt.ActionText = "Plant"
		view.prompt.ObjectText = "Empty plot"
		view.prompt.Enabled = false
	end
	yard.player = nil
	yard.folder.Name = "Yard" .. yard.slot
	yard.sign.Text = "Open Yard"
	yard.spawnPad.Enabled = false
	if player.RespawnLocation == yard.spawnPad then
		player.RespawnLocation = nil
	end
end

function Grove.of(player: Player): any
	return yards[player]
end

-- ================================= redraw ===================================
--[[
	Make the world agree with the state.

	Called after every action rather than on a tick, so what a player sees is
	always the answer the server just gave. A yard redrawn on a timer shows the
	previous answer for up to a tick, and that is exactly long enough for a
	player to press chop twice.
]]
function Grove.refresh(player: Player, state: Yard.State)
	local yard = yards[player]
	if not yard then
		return
	end

	--: Plots bought since the last redraw.
	for index = #yard.plots + 1, state.slots do
		buildPlot(yard, index)
	end

	for index = 1, state.slots do
		local view = yard.plots[index]
		local plot = state.plots[index]
		if not view or not plot then
			continue
		end
		local ready = Yard.ready(plot)
		local changed = view.species ~= plot.species or view.ready ~= ready

		if changed then
			if view.model then
				view.model:Destroy()
				view.model = nil
			end
			if plot.species then
				local species = Trees.get(plot.species)
				if species then
					--: A sapling is the same model, small. Growth is legible
					--: from across the yard that way, which is what makes a
					--: player walk over at the right moment.
					local scale = if ready then 1 else 0.45
					local model = treeModel(species,
						view.origin + Vector3.new(0, 1, 0), yard.folder)
					if model and not ready and model:IsA("Model") then
						(model :: Model):ScaleTo(scale)
						local low = (model :: Model):GetPivot().Position
						;(model :: Model):PivotTo(CFrame.new(
							view.origin + Vector3.new(0, 1, 0)))
					end
					view.model = model
				end
			end
			view.species, view.ready = plot.species, ready
		end

		--: The prompt is the instruction. It changes with the plot's state, so
		--: standing in front of it always says the true next action.
		if not plot.species then
			view.prompt.ActionText = "Plant"
			view.prompt.ObjectText = "Empty plot"
			view.prompt.Enabled = true
		elseif ready then
			local species = Trees.get(plot.species)
			--: The prompt counts the swings down. A tree that takes fifteen
			--: hits and says nothing reads as a tree that is not responding.
			local hits = if species
				then math.max(1, math.ceil((plot.hp or species.toughness)
					/ Yard.axePower(state.axe)))
				else 1
			view.prompt.ActionText = "Chop"
			view.prompt.ObjectText = string.format("%s -- %d swing%s",
				(species and species.name or "Tree"), hits,
				if hits == 1 then "" else "s")
			view.prompt.Enabled = true
		else
			local species = Trees.get(plot.species)
			view.prompt.ActionText = "Growing"
			view.prompt.ObjectText = string.format("%s -- %ds",
				species and species.name or "Tree",
				math.ceil(Yard.remaining(plot)))
			view.prompt.Enabled = false
		end
	end

	local logs, carved = Yard.counts(state)
	yard.carvePrompt.ObjectText = string.format("Workbench -- %d logs", logs)
	yard.carvePrompt.Enabled = logs > 0
	yard.sellPrompt.ObjectText = string.format("%d pieces at 60%%", carved)
	yard.sellPrompt.Enabled = carved > 0
end

function Grove.describe(): { [string]: any }
	local count = 0
	for _ in yards do
		count += 1
	end
	return { yards = count, scenery = Grove.planted }
end

return Grove
