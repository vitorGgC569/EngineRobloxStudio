--!strict
--[[
	World — a valley of dead forest, and the things you fight around in it.

	A bounded arena rather than an open world, on purpose and for now: the
	riskiest thing about this game is whether the shooting feels right, and
	that question is answered in a hundred metres of ground with cover on it.
	A map built before the combat is scenery for a game that does not exist.

	Terrain, not a slab
	-------------------

	The ground is real Roblox terrain. That costs a few seconds at boot and buys
	three things a flat part cannot: it undulates, so cover and sightlines exist
	without anybody placing them; it takes grass decoration, which is most of
	what makes a forest floor read as ground; and a player can be *below* a
	shooter, which is the whole reason a valley is the shape.

	Density is the atmosphere
	-------------------------

	Six hundred trees rather than sixty. A shooter's forest is not decoration --
	it is the thing that breaks line of sight, and a sparse one reads as a park.
	The trees come from the catalogue and are tinted dead, because a bright
	green wood and a heavy sky are two different games.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Place = Forge.Catalog.Place
local Itch = Forge.Catalog.ItchAssets
local Textures = Forge.Catalog.Textures
local Rng = Forge.Core.Rng

local World = {}

World.RADIUS = 460
--: Wind, in studs per second. Drives terrain grass, the foliage cards and
--: anything else that should agree with them.
World.WIND = Vector3.new(9, 0, 5)
World.TUFTS = 900
World.FLOOR = 0
World.TREES = 620
World.ROCKS = 90

local stream = Rng.stream("holdout.world")
local root: Folder? = nil

-- ================================== ground ==================================
--[[
	A valley floor, carved rather than placed.

	`FillBlock` in a grid with a height field: cheaper to write than a mesh, and
	the voxel edges are hidden by the grass. The bowl shape means the middle is
	overlooked from every side, so standing in the open is a decision.
]]
local function carve()
	local terrain = Workspace.Terrain
	terrain:Clear()

	--[[
		Grass on the ground, and wind through it.

		`Terrain.Decoration` grows real blades on any grass-family voxel and
		Roblox animates them against `Workspace.GlobalWind` for free -- which
		is a moving forest floor for two properties and no per-frame cost. It
		is off by default and every game in this project has left it off.

		The wind is a real vector, not a toggle: the same one moves the
		foliage cards below, so the ground and the cards lean the same way.
		A forest where they disagree reads as broken in a way nobody can name.
	]]
	--: `Decoration` itself is set in the place file -- it is plugin-gated and a
	--: server that assigns it throws, which a pcall turns into a silent bald
	--: floor. Only the wind is writable from here.
	Workspace.GlobalWind = World.WIND

	local step = 32
	local reach = World.RADIUS + step * 2
	for x = -reach, reach, step do
		for z = -reach, reach, step do
			local distance = math.sqrt(x * x + z * z)
			if distance > reach then
				continue
			end
			--: A shallow bowl with noise on it. The noise is what stops the
			--: valley reading as a bowl.
			local bowl = (distance / World.RADIUS) ^ 2 * 34
			local rough = math.noise(x / 220, z / 220) * 16
				+ math.noise(x / 70, z / 70) * 5
			local top = World.FLOOR + bowl + rough
			local depth = 40

			--: Rock under the soil, so a shot that digs shows rock and the
			--: cliffs at the rim are not floating grass.
			terrain:FillBlock(
				CFrame.new(x, top - depth / 2 - 3, z),
				Vector3.new(step + 2, depth, step + 2),
				Enum.Material.Rock)
			terrain:FillBlock(
				CFrame.new(x, top - 1.5, z),
				Vector3.new(step + 2, 5, step + 2),
				if distance > World.RADIUS * 0.86 then Enum.Material.Slate
				elseif rough < -3 then Enum.Material.Mud
				else Enum.Material.LeafyGrass)
		end
	end
end

--: Where the ground is, at a point. Terrain is voxel and a model dropped at a
--: guessed height either floats or sinks, which is the most common way a
--: scattered forest looks wrong.
local function groundAt(x: number, z: number): number
	local distance = math.sqrt(x * x + z * z)
	local bowl = (distance / World.RADIUS) ^ 2 * 34
	local rough = math.noise(x / 220, z / 220) * 16 + math.noise(x / 70, z / 70) * 5
	return World.FLOOR + bowl + rough
end

World.groundAt = groundAt

-- ================================== forest ==================================
--[[
	Dead wood, in three tones.

	The catalogue's trees are lit for a bright game. Recolouring them is what
	makes the wood read as late autumn rather than as a park -- and it is one
	pass over the parts, which is cheaper than sourcing a second set of models.
]]
local BARK = {
	Color3.fromRGB(64, 56, 48), Color3.fromRGB(78, 68, 56),
	Color3.fromRGB(52, 46, 42),
}
local CANOPY = {
	Color3.fromRGB(74, 78, 56), Color3.fromRGB(96, 92, 60),
	Color3.fromRGB(62, 66, 50), Color3.fromRGB(88, 76, 48),
}

local function deaden(model: Instance, bark: Color3, canopy: Color3)
	local parts: { Instance } = if model:IsA("BasePart") then { model }
		else model:GetDescendants()
	for _, instance in parts do
		if not instance:IsA("BasePart") then
			continue
		end
		local part = instance :: BasePart
		--: Anything carrying its own texture is left alone; recolouring a
		--: textured mesh tints the photograph and looks like a filter.
		if part:IsA("MeshPart") and (part :: MeshPart).TextureID ~= "" then
			continue
		end
		local name = string.lower(part.Name)
		local wood = string.find(name, "trunk", 1, true)
			or string.find(name, "bark", 1, true)
			or string.find(name, "branch", 1, true)
			or string.find(name, "stem", 1, true)
		part.Color = if wood then bark else canopy
		part.Material = if wood then Enum.Material.Wood else Enum.Material.Grass
	end
end

--[[
	Where the trees are not.

	A forest with no clearings is a forest with no fights in it -- every
	engagement is at four metres through a trunk. Three open patches give the
	map somewhere a rifle beats an SMG, which is the only reason to carry one.
]]
local CLEARINGS = {
	{ x = 0, z = 0, r = 120 },
	{ x = -250, z = 180, r = 90 },
	{ x = 230, z = -210, r = 85 },
}

local function inClearing(x: number, z: number): boolean
	for _, c in CLEARINGS do
		local dx, dz = x - c.x, z - c.z
		if dx * dx + dz * dz < c.r * c.r then
			return true
		end
	end
	return false
end

local function forest(parent: Instance): (number, number)
	local trees, rocks = 0, 0
	for index = 1, World.TREES do
		local angle = stream:number(0, math.pi * 2)
		--: Square-rooted so the scatter is even by area rather than crowding
		--: the middle, which is what a flat radius does and always looks wrong.
		local radius = math.sqrt(stream:number(0, 1)) * (World.RADIUS - 20)
		local x, z = math.sin(angle) * radius, math.cos(angle) * radius
		if inClearing(x, z) then
			continue
		end
		local model = Place.put(Itch, {
			topic = "tree", seed = index * 13 + 5,
			at = Vector3.new(x, groundAt(x, z) - 1, z),
			yaw = stream:number(0, math.pi * 2), parent = parent,
			jitter = stream:number(0.8, 1.9), tint = false,
		})
		if model then
			deaden(model, BARK[stream:int(1, #BARK)], CANOPY[stream:int(1, #CANOPY)])
			trees += 1
		end
	end

	for index = 1, World.ROCKS do
		local angle = stream:number(0, math.pi * 2)
		local radius = math.sqrt(stream:number(0, 1)) * (World.RADIUS - 30)
		local x, z = math.sin(angle) * radius, math.cos(angle) * radius
		local model = Place.put(Itch, {
			topic = stream:pick({ "rock", "bush", "log" }) or "rock",
			seed = index * 29 + 11,
			at = Vector3.new(x, groundAt(x, z) - 0.5, z),
			yaw = stream:number(0, math.pi * 2), parent = parent,
			jitter = stream:number(0.7, 1.6),
		})
		if model then
			rocks += 1
		end
	end
	return trees, rocks
end

-- ================================= foliage ==================================
--[[
	Grass tufts, as crossed cards.

	Two quads at right angles with an alpha-cut grass image on both faces --
	the oldest trick in real-time vegetation and still the right one, because a
	tuft costs two triangles and reads as a hundred blades.

	The images are the ones the texture pipeline first threw away for having
	holes in them. They were being measured correctly and judged wrongly:
	useless as a floor, and exactly what a card is.

	Anchored and unscripted. The sway comes from Roblox animating
	`Decoration` grass against `GlobalWind`; the cards themselves are still,
	and at tuft scale nobody reads the difference against a moving floor.
]]
local function tuft(at: Vector3, textureId: number, parent: Instance)
	local size = stream:number(3.4, 6.2)
	local model = Instance.new("Model")
	model.Name = "Tuft"

	for index = 0, 1 do
		local card = Instance.new("Part")
		card.Name = "Card"
		card.Size = Vector3.new(size, size * 0.8, 0.08)
		card.Anchored = true
		card.CanCollide = false
		card.CanQuery = false
		card.CanTouch = false
		card.Transparency = 1
		card.CastShadow = false
		card.CFrame = CFrame.new(at + Vector3.new(0, size * 0.4, 0))
			* CFrame.Angles(0, stream:number(0, math.pi) + index * math.pi / 2, 0)
		--: A texture per face, because a single-sided card vanishes when
		--: walked past and that is the most obvious vegetation bug there is.
		for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
			local texture = Instance.new("Texture")
			texture.Face = face
			texture.Texture = "rbxassetid://" .. textureId
			texture.StudsPerTileU = size
			texture.StudsPerTileV = size * 0.8
			texture.Parent = card
		end
		card.Parent = model
	end
	model.Parent = parent
	return model
end

local function undergrowth(parent: Instance): number
	local cards = Textures.byRole("foliage.grass")
	if #cards == 0 then
		return 0
	end
	local folder = Instance.new("Folder")
	folder.Name = "Undergrowth"
	folder.Parent = parent

	local placed = 0
	for index = 1, World.TUFTS do
		local angle = stream:number(0, math.pi * 2)
		local radius = math.sqrt(stream:number(0, 1)) * (World.RADIUS - 30)
		local x, z = math.sin(angle) * radius, math.cos(angle) * radius
		tuft(Vector3.new(x, groundAt(x, z) - 0.6, z),
			cards[stream:int(1, #cards)].id, folder)
		placed += 1
	end
	return placed
end

-- ================================== cover ===================================
local function slab(name: string, size: Vector3, cf: CFrame, colour: Color3,
                    variant: string, base: Enum.Material, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Anchored = true
	part.Color = colour
	part.Material = base
	part.MaterialVariant = variant
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[
	A ruin, which is the only architecture this map needs.

	Three walls and a doorway. Not a building -- a *shape to fight around*: it
	blocks sight from two directions, can be flanked, and gives the player
	inside a reason to watch a doorway. Everything else a structure could do is
	decoration.
]]
local function ruin(at: Vector3, yaw: number, parent: Instance)
	local model = Instance.new("Model")
	model.Name = "Ruin"
	model.Parent = parent
	local base = CFrame.new(at) * CFrame.Angles(0, yaw, 0)

	slab("Floor", Vector3.new(34, 1, 28), base * CFrame.new(0, 0.5, 0),
		Color3.fromRGB(128, 124, 118), "ConcreteFloor", Enum.Material.Concrete, model)

	--: Two long walls and a short one with a gap: cover from three sides and
	--: a way in that a defender can hold.
	slab("WallA", Vector3.new(34, 13, 1.6), base * CFrame.new(0, 6.5, -13.5),
		Color3.fromRGB(122, 116, 108), "RuinWall", Enum.Material.Brick, model)
	slab("WallB", Vector3.new(1.6, 13, 28), base * CFrame.new(-16.5, 6.5, 0),
		Color3.fromRGB(122, 116, 108), "RuinWall", Enum.Material.Brick, model)
	slab("WallC", Vector3.new(12, 13, 1.6), base * CFrame.new(-11, 6.5, 13.5),
		Color3.fromRGB(122, 116, 108), "RuinWall", Enum.Material.Brick, model)
	slab("WallD", Vector3.new(12, 13, 1.6), base * CFrame.new(11, 6.5, 13.5),
		Color3.fromRGB(122, 116, 108), "RuinWall", Enum.Material.Brick, model)

	--: A half-collapsed roof, so the inside is dark and the outside can see
	--: where it is. Light is information in a shooter.
	local roof = slab("Roof", Vector3.new(34, 1.2, 15), base * CFrame.new(0, 13, -6),
		Color3.fromRGB(108, 102, 96), "ConcreteFloor", Enum.Material.Concrete, model)
	roof.CanCollide = true

	--: Waist-high cover in front of the doorway, which is what turns the
	--: approach into a decision rather than a sprint.
	slab("Barricade", Vector3.new(14, 4, 1.4), base * CFrame.new(0, 2.5, 22),
		Color3.fromRGB(96, 82, 64), "RuinWall", Enum.Material.Wood, model)
end

local RUINS = {
	{ x = 0, z = 0, yaw = 0.2 },
	{ x = -250, z = 180, yaw = 2.1 },
	{ x = 230, z = -210, yaw = -1.1 },
	{ x = -180, z = -230, yaw = 0.8 },
}

-- ================================== build ===================================
function World.build(): any
	World.clear()
	local folder = Instance.new("Folder")
	folder.Name = "World"
	folder.Parent = Workspace
	root = folder

	carve()
	local trees, rocks = forest(folder)
	local tufts = undergrowth(folder)
	for _, spot in RUINS do
		ruin(Vector3.new(spot.x, groundAt(spot.x, spot.z), spot.z), spot.yaw, folder)
	end

	--: The rim, so nobody walks out of the valley. Rock rather than an
	--: invisible wall: a player who stops moving should be able to see why.
	local segments = 72
	for index = 0, segments - 1 do
		local angle = (index / segments) * math.pi * 2
		local x = math.sin(angle) * (World.RADIUS + 26)
		local z = math.cos(angle) * (World.RADIUS + 26)
		local wall = slab("Cliff", Vector3.new(60, 90, 40),
			CFrame.lookAt(Vector3.new(x, groundAt(x, z) + 30, z), Vector3.zero)
				* CFrame.Angles(stream:number(-0.06, 0.06), 0,
					stream:number(-0.05, 0.05)),
			Color3.fromRGB(84, 80, 76), "CliffRock", Enum.Material.Rock, folder)
		wall.CanCollide = true
	end

	local pad = Instance.new("SpawnLocation")
	pad.Name = "Spawn"
	pad.Size = Vector3.new(18, 1, 18)
	pad.CFrame = CFrame.new(0, groundAt(0, 26) + 1.5, 26)
	pad.Anchored = true
	--: `Neutral = false` with no Teams accepts nobody at all, which is a spawn
	--: pad that silently refuses every player.
	pad.Neutral = true
	pad.Color = Color3.fromRGB(96, 92, 88)
	pad.Material = Enum.Material.Concrete
	pad.MaterialVariant = "ConcreteFloor"
	pad.Transparency = 0.4
	pad.Parent = folder

	World.planted = { trees = trees, rocks = rocks, ruins = #RUINS,
		tufts = tufts }
	return World.planted
end

function World.clear()
	if root then
		root:Destroy()
	end
	root = nil
end

--: Somewhere in the open, on the ground, at least `away` from a point. The
--: horde needs this and so does anything that drops.
function World.pointNear(origin: Vector3, minimum: number, maximum: number): Vector3
	for _ = 1, 24 do
		local angle = stream:number(0, math.pi * 2)
		local radius = stream:number(minimum, maximum)
		local x = origin.X + math.sin(angle) * radius
		local z = origin.Z + math.cos(angle) * radius
		if math.sqrt(x * x + z * z) < World.RADIUS - 30 then
			return Vector3.new(x, groundAt(x, z) + 3, z)
		end
	end
	return Vector3.new(origin.X, groundAt(origin.X, origin.Z) + 3, origin.Z)
end

function World.describe(): { [string]: any }
	return World.planted or { built = false }
end

return World
