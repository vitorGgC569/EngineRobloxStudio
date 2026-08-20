--!strict
-- L4: props.
--
-- `Nature.tree` and `Nature.rock` exist and produce a trunk with a ball on it
-- and a single sphere. At the distance a player sees them that is a lollipop and
-- a pebble, and forty of them is the "repetitive, test-block" reading that a
-- capture of the generated world got.
--
-- The difference between a prop and a placeholder is not polygon count. It is:
--
-- **More than one mass.** A crate is a box; a crate with corner posts and a lid
-- band is a crate. Three parts, and it stops reading as a primitive.
--
-- **Variation that is not scale.** Scattering one prop at random sizes still
-- reads as one prop, because the silhouette is identical. Varying the *number*
-- of masses, their rotation and which palette role they take is what makes a
-- row of forty stop looking like a row of one.
--
-- **A shadow-catching detail.** An overhang, a rim, a recess. Flat surfaces at
-- the same angle all take the same light, and a scene of them looks unlit even
-- when the lighting is correct.
--
-- Deterministic from a seed, like everything else placed in a world: two builds
-- of the same game must put the same barrel in the same place or a visual
-- comparison between them reports noise.

local Palette = require(script.Parent.Palette)
local Tokens = require(script.Parent.Tokens)

local Props = {}

export type PropSpec = {
	position: Vector3,
	rotation: number?,
	scale: number?,
	seed: number?,
	--- Palette roles. Defaults suit timber and stone; a kit passes its own.
	primary: string?,
	secondary: string?,
	accent: string?,
}

local function fail(message: string): never
	error("[WorldKit.Props] " .. message, 0)
end

local function piece(parent: Instance, name: string, size: Vector3, cframe: CFrame,
	colour: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = colour
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function base(spec: PropSpec): (CFrame, number, Random)
	local scale = spec.scale or 1
	if scale <= 0 then
		fail("a prop scale must be positive")
	end
	local origin = CFrame.new(spec.position) * CFrame.Angles(0, math.rad(spec.rotation or 0), 0)
	return origin, scale, Random.new(spec.seed or 1)
end

--- A crate: body, corner posts, lid band.
function Props.crate(parent: Instance, tokens: Tokens.TokenSet, spec: PropSpec): Model
	local origin, scale, random = base(spec)
	local model = Instance.new("Model")
	model.Name = "Crate"
	model.Parent = parent

	local wood = tokens:color(spec.primary or "woodPrimary")
	local dark = tokens:color(spec.secondary or "woodSecondary")
	local size = 5 * scale

	piece(model, "Body", Vector3.new(size, size, size),
		origin * CFrame.new(0, size / 2, 0), wood, Enum.Material.WoodPlanks)
	for _, corner in ipairs({
		Vector3.new(1, 0, 1), Vector3.new(-1, 0, 1),
		Vector3.new(1, 0, -1), Vector3.new(-1, 0, -1),
	}) do
		piece(model, "Post", Vector3.new(size * 0.16, size, size * 0.16),
			origin * CFrame.new(corner.X * size / 2, size / 2, corner.Z * size / 2),
			dark, Enum.Material.Wood)
	end
	piece(model, "Band", Vector3.new(size * 1.04, size * 0.14, size * 1.04),
		origin * CFrame.new(0, size * 0.82, 0), dark, Enum.Material.Metal)
	return model
end

--- A barrel: staves, two hoops, a rim.
function Props.barrel(parent: Instance, tokens: Tokens.TokenSet, spec: PropSpec): Model
	local origin, scale, _ = base(spec)
	local model = Instance.new("Model")
	model.Name = "Barrel"
	model.Parent = parent

	local wood = tokens:color(spec.primary or "woodPrimary")
	local hoop = tokens:color(spec.secondary or "metalDark")
	local height = 6 * scale
	local radius = 2.2 * scale
	local upright = CFrame.Angles(0, 0, math.rad(90))

	local body = piece(model, "Body", Vector3.new(height, radius * 2, radius * 2),
		origin * CFrame.new(0, height / 2, 0) * upright, wood, Enum.Material.Wood)
	body.Shape = Enum.PartType.Cylinder

	for _, at in ipairs({ 0.25, 0.75 }) do
		local band = piece(model, "Hoop", Vector3.new(height * 0.1, radius * 2.15, radius * 2.15),
			origin * CFrame.new(0, height * at, 0) * upright, hoop, Enum.Material.Metal)
		band.Shape = Enum.PartType.Cylinder
	end
	return model
end

--- A rock cluster: several masses at different angles, never one sphere.
---
--- The count varies with the seed rather than only the size, because a scatter
--- of identically-shaped rocks at different scales still reads as one rock.
function Props.rock(parent: Instance, tokens: Tokens.TokenSet, spec: PropSpec): Model
	local origin, scale, random = base(spec)
	local model = Instance.new("Model")
	model.Name = "Rock"
	model.Parent = parent

	local stone = tokens:color(spec.primary or "stonePrimary")
	local shade = tokens:color(spec.secondary or "stoneSecondary")
	local masses = random:NextInteger(2, 4)

	for index = 1, masses do
		local size = (3.2 - index * 0.55) * scale * random:NextNumber(0.8, 1.3)
		local offset = Vector3.new(
			random:NextNumber(-1.4, 1.4) * scale, size * 0.35,
			random:NextNumber(-1.4, 1.4) * scale)
		local rock = piece(model, "Mass", Vector3.new(size * 1.6, size, size * 1.4),
			origin * CFrame.new(offset)
				* CFrame.Angles(random:NextNumber(0, 0.5), random:NextNumber(0, 6.2),
					random:NextNumber(0, 0.5)),
			index % 2 == 0 and shade or stone, Enum.Material.Rock)
		rock.TopSurface = Enum.SurfaceType.Smooth
	end

	-- Chips: the small grain that keeps a boulder from reading as one blob.
	for index = 1, random:NextInteger(2, 5) do
		piece(model, "Chip",
			Vector3.new(0.7 * scale, 0.5 * scale, 0.6 * scale),
			origin * CFrame.new(
				random:NextNumber(-2.6, 2.6) * scale, 0.25 * scale,
				random:NextNumber(-2.6, 2.6) * scale)
				* CFrame.Angles(0, random:NextNumber(0, 6.2), 0),
			shade, Enum.Material.Rock)
	end
	return model
end

--- A tree with a tapered trunk, boughs and layered canopy.
---
--- `Nature.tree` puts one ball on one cylinder. This is the same idea with the
--- three details that make a canopy read: taper, more than one crown mass, and
--- boughs that connect them.
function Props.tree(parent: Instance, tokens: Tokens.TokenSet, spec: PropSpec): Model
	local origin, scale, random = base(spec)
	local model = Instance.new("Model")
	model.Name = "Tree"
	model.Parent = parent

	local bark = tokens:color(spec.primary or "vegetationBark")
	local leaf = tokens:color(spec.secondary or "vegetationLeaf")
	local leafDark = tokens:color(spec.accent or "vegetationLeafDark")

	-- Height varies 3x rather than 1.5x. A stand of trees within a narrow band
	-- cuts the sky at one line and reads as a hedge; the scene critic measured
	-- the skyline as nearly unbroken with the old range, and a broken canopy is
	-- the cheapest thing that fixes it.
	local height = random:NextNumber(11, 34) * scale
	local upright = CFrame.Angles(0, 0, math.rad(90))

	-- Taper: two stacked sections rather than one cylinder. A trunk of constant
	-- width is the single clearest tell of a generated tree.
	local lower = piece(model, "Trunk", Vector3.new(height * 0.6, 2.6 * scale, 2.6 * scale),
		origin * CFrame.new(0, height * 0.3, 0) * upright, bark, Enum.Material.Wood)
	lower.Shape = Enum.PartType.Cylinder
	local upper = piece(model, "Trunk", Vector3.new(height * 0.45, 1.7 * scale, 1.7 * scale),
		origin * CFrame.new(0, height * 0.62, 0) * upright, bark, Enum.Material.Wood)
	upper.Shape = Enum.PartType.Cylinder

	local crowns = random:NextInteger(3, 5)
	for index = 1, crowns do
		local angle = random:NextNumber(0, math.pi * 2)
		local spread = random:NextNumber(0, 4) * scale
		local size = random:NextNumber(7, 11) * scale * (1 - (index - 1) * 0.09)
		local crown = piece(model, "Canopy", Vector3.new(size, size * 0.8, size),
			origin * CFrame.new(
				math.cos(angle) * spread,
				height * random:NextNumber(0.72, 1.0),
				math.sin(angle) * spread),
			index % 3 == 0 and leafDark or leaf, Enum.Material.Grass)
		crown.Shape = Enum.PartType.Ball
	end

	-- Fine grain: small branches, an order of magnitude below the canopy masses.
	-- A frame whose detail is all one size reads as a diagram however dense it
	-- is, which is what `scale_coherence` measures.
	for index = 1, random:NextInteger(2, 4) do
		local twig = piece(model, "Twig",
			Vector3.new(height * 0.16, 0.45 * scale, 0.45 * scale),
			origin * CFrame.new(0, height * random:NextNumber(0.45, 0.7), 0)
				* CFrame.Angles(0, random:NextNumber(0, 6.2), math.rad(random:NextNumber(35, 70))),
			bark, Enum.Material.Wood)
		twig.Shape = Enum.PartType.Cylinder
	end

	-- One bough, angled, tying the canopy to the trunk.
	local bough = piece(model, "Bough", Vector3.new(height * 0.3, 1.1 * scale, 1.1 * scale),
		origin * CFrame.new(0, height * 0.66, 0)
			* CFrame.Angles(0, random:NextNumber(0, 6.2), math.rad(55)),
		bark, Enum.Material.Wood)
	bough.Shape = Enum.PartType.Cylinder

	return model
end

--- Ground cover: a clump of grass blades or a scatter of pebbles.
---
--- The cheapest fix for an empty foreground, and the one that matters most: a
--- scene critique measured 62% of a player-level frame as one unbroken plane,
--- and the plane was the ground the player stands on. Trees and buildings do
--- not fix it -- they are all beyond the near field.
---
--- Small enough to cost nothing at distance and to read as texture up close,
--- which is also what stops a frame holding detail at a single size.
function Props.tuft(parent: Instance, tokens: Tokens.TokenSet, spec: PropSpec): Model
	local origin, scale, random = base(spec)
	local model = Instance.new("Model")
	model.Name = "Tuft"
	model.Parent = parent

	local leaf = tokens:color(spec.primary or "vegetationLeafDark")
	local blades = random:NextInteger(3, 6)
	for index = 1, blades do
		local height = random:NextNumber(1.1, 2.4) * scale
		piece(model, "Blade",
			Vector3.new(0.28 * scale, height, 0.28 * scale),
			origin * CFrame.new(
				random:NextNumber(-1.1, 1.1) * scale, height / 2,
				random:NextNumber(-1.1, 1.1) * scale)
				* CFrame.Angles(math.rad(random:NextNumber(-14, 14)),
					random:NextNumber(0, 6.2), math.rad(random:NextNumber(-14, 14))),
			leaf, Enum.Material.Grass)
	end
	return model
end

--- A standing lamp, which is also a light source.
function Props.lamp(parent: Instance, tokens: Tokens.TokenSet, spec: PropSpec): Model
	local origin, scale, _ = base(spec)
	local model = Instance.new("Model")
	model.Name = "Lamp"
	model.Parent = parent

	local boostHint = tonumber(
		game:GetService("Lighting"):GetAttribute("WorldKitLightBoost")) or 1
	local metal = tokens:color(spec.primary or "metalDark")
	local glow = tokens:color(spec.accent or "accentGold")
	local height = 12 * scale

	piece(model, "Foot", Vector3.new(2.4 * scale, 1.2, 2.4 * scale),
		origin * CFrame.new(0, 0.6, 0), metal, Enum.Material.Metal)
	local post = piece(model, "Post", Vector3.new(height, 0.9 * scale, 0.9 * scale),
		origin * CFrame.new(0, height / 2, 0) * CFrame.Angles(0, 0, math.rad(90)),
		metal, Enum.Material.Metal)
	post.Shape = Enum.PartType.Cylinder

	-- Small. At eye level a 2.6-stud Neon block reads as a floating yellow box
	-- rather than as a lamp, and a lane of them dominates the frame -- which is
	-- what a close capture showed once the camera finally got down to where a
	-- player stands.
	-- Smaller in a dark mood, not larger.
	--
	-- A Neon head is the brightest thing in a night scene and bloom grows it by
	-- its own size again; at 1.1 studs under a 1.8x boost it read as a white
	-- square rather than as a flame. What a dark scene wants is a small, intense
	-- source throwing a wide pool -- the pool comes from Range, below.
	local headSize = 1.1 * scale / math.max(boostHint, 1) ^ 0.5
	local head = piece(model, "Head", Vector3.new(headSize, 1.4 * scale, headSize),
		origin * CFrame.new(0, height + 0.6, 0), glow, Enum.Material.Neon)
	-- Deliberately modest. A lane of lamps at 2.4 brightness and 26 studs each
	-- overlaps into a single flat wash, which reads as an overexposed frame
	-- rather than as lighting.
	-- Scaled by the mood. See the note in `rqe/art/direction.py`: 0.9/16 is a
	-- noon value, and at night it is the difference between a lit abbey and a
	-- uniformly black one.
	local boost = tonumber(game:GetService("Lighting"):GetAttribute("WorldKitLightBoost")) or 1
	local light = Instance.new("PointLight")
	-- Range scales with the boost; brightness only by its square root.
	--
	-- The first attempt scaled both and overshot in the other direction: at 3.4x
	-- the player standing beside a lamp was clipped to pure white and the abbey
	-- read as a warmly lit street. What a dark scene needs from a lamp is
	-- *reach* -- a wide, soft pool with black between pools -- not intensity at
	-- the bulb. Brightness is what blows out whatever is nearest.
	light.Brightness = 0.9 * math.sqrt(boost)
	light.Range = 16 * scale * boost
	light.Color = glow
	light.Parent = head

	piece(model, "Cap", Vector3.new(2.2 * scale, 0.6, 2.2 * scale),
		origin * CFrame.new(0, height + 1.6, 0), metal, Enum.Material.Metal)
	return model
end

--- A banner on a pole: identity, and a vertical accent where the eye needs one.
function Props.banner(parent: Instance, tokens: Tokens.TokenSet, spec: PropSpec): Model
	local origin, scale, _ = base(spec)
	local model = Instance.new("Model")
	model.Name = "Banner"
	model.Parent = parent

	local pole = tokens:color(spec.primary or "woodSecondary")
	local cloth = tokens:color(spec.accent or "accentDanger")
	local height = 16 * scale

	local mast = piece(model, "Pole", Vector3.new(height, 0.7 * scale, 0.7 * scale),
		origin * CFrame.new(0, height / 2, 0) * CFrame.Angles(0, 0, math.rad(90)),
		pole, Enum.Material.Wood)
	mast.Shape = Enum.PartType.Cylinder
	piece(model, "Cloth", Vector3.new(0.3, height * 0.45, 5 * scale),
		origin * CFrame.new(0, height * 0.72, 2.6 * scale), cloth, Enum.Material.Fabric)
	piece(model, "Finial", Vector3.new(1.4 * scale, 1.4 * scale, 1.4 * scale),
		origin * CFrame.new(0, height + 0.7, 0), tokens:color("accentGold"), Enum.Material.Metal)
	return model
end

--- Every prop this module can build, so a dresser can choose without guessing.
function Props.kinds(): { string }
	return { "crate", "barrel", "rock", "tree", "lamp", "banner", "tuft" }
end

--- The authored kit, when a game has one.
---
--- Set once by the world script. Every `Props.build` after it prefers the
--- authored mesh over the Part assembly, so a world gets real geometry without
--- one call site changing -- which matters because the alternative is a branch
--- at every scatter loop in every template, and the one that gets forgotten is
--- the forest.
local kit: { [string]: any }? = nil

function Props.useKit(source: { [string]: any }?): ()
	kit = source
end

--- Roles the kit is allowed to answer for.
---
--- Not every prop should become a mesh even when one exists. A lamp is mostly a
--- post and a light; a banner is a cloth plane that has to stay flat against
--- its pole. These are shapes a Part expresses honestly, and spending a mesh on
--- them costs place size for nothing.
local MESHED = {
	tree = true, rock = true, crate = true, barrel = true, objective = true,
}

--- Build one by name.
---
--- Falls back rather than fails. A client that cannot build meshes -- or a game
--- whose kit was never generated -- gets the Part version, because a blocky
--- tree is a far better outcome than a hole where the forest was.
function Props.build(kind: string, parent: Instance, tokens: Tokens.TokenSet, spec: PropSpec): Instance
	if kit ~= nil and MESHED[kind] then
		local data = kit[kind]
		if data ~= nil then
			local Mesh = require(script.Parent.Mesh)
			-- Each kind keeps the palette role its Part version uses.
			--
			-- The first pass passed `spec.primary` straight through, and almost
			-- no caller sets it -- so every authored tree, rock and crate fell
			-- back to `structurePrimary` and the forest came out stone-coloured.
			local ROLE = {
				tree = "vegetationLeaf", rock = "stoneSecondary",
				crate = "woodPrimary", barrel = "woodSecondary",
				objective = "accentGold",
			}
			local built = Mesh.build(data, tokens, {
				name = kind,
				position = spec.position,
				rotation = spec.rotation,
				scale = spec.scale,
				role = spec.primary or ROLE[kind],
				material = if kind == "tree" then Enum.Material.Grass else nil,
				parent = parent,
			})
			if built ~= nil then
				return built
			end
		end
	end

	local builder = (Props :: any)[kind]
	if type(builder) ~= "function" or kind == "build" or kind == "kinds"
		or kind == "useKit" then
		fail(string.format("unknown prop %q; available: %s",
			kind, table.concat(Props.kinds(), ", ")))
	end
	return builder(parent, tokens, spec)
end

return Props
