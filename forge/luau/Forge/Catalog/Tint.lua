--!strict
--[[
	Tint — colour for imported meshes that arrived without any.

	Why this exists
	---------------

	Two thirds of the CC0 models published to this account carry no colour at
	all. Not because the upload failed: the packs modelled them with plain
	untextured materials, and Roblox's importer keeps geometry and drops that.
	What comes back is a MeshPart the colour of unpainted plastic.

	A world built from them is white. Not stylised-white -- the *absence* of a
	decision, which reads as a bug in a way that a wrong colour never does.
	And the grey ones are not a random third: `house`, `tree`, `castle`,
	`rock`, `bush` have no coloured member at all, so exactly the models that
	fill a frame are the ones missing.

	So: colour them here, from what they are.

	How it decides
	--------------

	Three passes, most specific first.

	1. **The part's own name.** A pack that modelled a house as six meshes
	   usually named them (`house5_door1`, `house5_windows`), and a door
	   painted like a door is worth more than a house painted one flat colour.

	2. **The topic.** `tree` is bark and leaves; `barrel` is wood; `castle` is
	   stone. One colour for the whole model, which is the honest answer when
	   the model is a single welded mesh.

	3. **Stone.** Anything unrecognised. Neutral, slightly warm, and never
	   white -- an unknown prop should look like a thing, not like a hole.

	Material matters as much as colour. Brown on `SmoothPlastic` reads as brown
	plastic; the same brown on `Wood` reads as wood. Every entry names both.

	What it will not touch
	----------------------

	A part with a `TextureID` or a `SurfaceAppearance` already carries an
	artist's decision, and overwriting that with a guess is strictly worse.
	Those are left alone, which is why this can be run over a mixed set without
	sorting it first.

		local Tint = Forge.Catalog.Tint
		Tint.apply(model, "house", stream)   -- returns parts coloured
]]

local Rng = require(script.Parent.Parent.Core.Rng)

local Tint = {}

export type Coat = { colour: Color3, material: Enum.Material }

local function coat(r: number, g: number, b: number, material: Enum.Material): Coat
	return { colour = Color3.fromRGB(r, g, b), material = material }
end

--[[
	Matched against the lowercased part name, in order, as plain substrings.

	A list rather than a map because order decides: `door` must be tried before
	`wood`, or every door in a wooden house comes out as wall. And plain
	substrings rather than patterns because Luau patterns have no alternation
	-- `(door|gate)` is not a pattern, it is four literal characters and two
	pipes, and it matches nothing while looking like it should.
]]
local HINTS: { { word: string, coat: Coat } } = {
	{ word = "leaf", coat = coat(74, 124, 58, Enum.Material.Grass) },
	{ word = "leaves", coat = coat(74, 124, 58, Enum.Material.Grass) },
	{ word = "foliage", coat = coat(74, 124, 58, Enum.Material.Grass) },
	{ word = "canopy", coat = coat(74, 124, 58, Enum.Material.Grass) },
	{ word = "needle", coat = coat(56, 100, 62, Enum.Material.Grass) },
	{ word = "branch", coat = coat(94, 71, 48, Enum.Material.Wood) },
	{ word = "trunk", coat = coat(94, 71, 48, Enum.Material.Wood) },
	{ word = "bark", coat = coat(88, 66, 45, Enum.Material.Wood) },
	{ word = "stem", coat = coat(96, 128, 62, Enum.Material.Grass) },

	{ word = "window", coat = coat(150, 186, 200, Enum.Material.Glass) },
	{ word = "glass", coat = coat(150, 186, 200, Enum.Material.Glass) },
	{ word = "door", coat = coat(104, 68, 40, Enum.Material.Wood) },
	{ word = "gate", coat = coat(104, 68, 40, Enum.Material.Wood) },
	{ word = "roof", coat = coat(122, 60, 48, Enum.Material.Slate) },
	{ word = "chimney", coat = coat(112, 92, 84, Enum.Material.Brick) },
	{ word = "brick", coat = coat(146, 92, 74, Enum.Material.Brick) },
	{ word = "stone", coat = coat(134, 132, 126, Enum.Material.Slate) },
	{ word = "rock", coat = coat(126, 124, 118, Enum.Material.Rock) },
	--: Stone, not plaster. This was a warm interior cream, which is right for
	--: a room and wrong for the thing the `wall` topic actually contains --
	--: castle curtain wall -- and the hint beats the topic, so every rampart
	--: around the keep came out white.
	{ word = "wall", coat = coat(138, 134, 126, Enum.Material.Slate) },
	{ word = "floor", coat = coat(128, 100, 70, Enum.Material.WoodPlanks) },
	{ word = "plank", coat = coat(140, 108, 74, Enum.Material.WoodPlanks) },
	{ word = "wood", coat = coat(126, 94, 62, Enum.Material.Wood) },

	{ word = "metal", coat = coat(140, 144, 150, Enum.Material.Metal) },
	{ word = "steel", coat = coat(150, 154, 160, Enum.Material.Metal) },
	{ word = "iron", coat = coat(96, 98, 104, Enum.Material.Metal) },
	{ word = "gold", coat = coat(214, 176, 74, Enum.Material.Metal) },
	{ word = "rope", coat = coat(168, 142, 96, Enum.Material.Fabric) },
	{ word = "cloth", coat = coat(160, 132, 108, Enum.Material.Fabric) },
	{ word = "fabric", coat = coat(160, 132, 108, Enum.Material.Fabric) },
	{ word = "light", coat = coat(246, 224, 156, Enum.Material.Neon) },
	{ word = "lamp", coat = coat(246, 224, 156, Enum.Material.Neon) },
	{ word = "flame", coat = coat(248, 176, 78, Enum.Material.Neon) },
	{ word = "water", coat = coat(72, 132, 158, Enum.Material.Glass) },
	{ word = "dirt", coat = coat(122, 96, 68, Enum.Material.Ground) },
	{ word = "grass", coat = coat(104, 148, 68, Enum.Material.Grass) },
	{ word = "sand", coat = coat(206, 186, 142, Enum.Material.Sand) },
	{ word = "snow", coat = coat(228, 232, 238, Enum.Material.Snow) },
}

--: The fallback when the mesh is one welded shape with a meaningless name,
--: which is the common case. Keyed by the catalogue's topic vocabulary.
local TOPICS: { [string]: Coat } = {
	tree = coat(78, 118, 60, Enum.Material.Grass),
	bush = coat(84, 124, 62, Enum.Material.Grass),
	["grass patch"] = coat(106, 150, 68, Enum.Material.Grass),
	flower = coat(196, 122, 148, Enum.Material.Grass),
	log = coat(102, 76, 50, Enum.Material.Wood),
	rock = coat(128, 126, 120, Enum.Material.Rock),

	--: Warm plaster rather than the near-white it was. A row of houses in a
	--: colour that light reads as unpainted geometry, which is the exact
	--: impression this whole module exists to avoid.
	house = coat(198, 174, 142, Enum.Material.Concrete),
	castle = coat(146, 142, 134, Enum.Material.Slate),
	wall = coat(150, 146, 138, Enum.Material.Slate),
	watchtower = coat(148, 142, 132, Enum.Material.Slate),
	fence = coat(122, 92, 60, Enum.Material.Wood),
	door = coat(104, 68, 40, Enum.Material.Wood),
	window = coat(150, 186, 200, Enum.Material.Glass),
	bridge = coat(118, 88, 58, Enum.Material.WoodPlanks),
	road = coat(122, 106, 84, Enum.Material.Ground),
	platform = coat(128, 104, 74, Enum.Material.WoodPlanks),
	["street lamp"] = coat(78, 80, 86, Enum.Material.Metal),
	["wooden sign"] = coat(124, 94, 62, Enum.Material.Wood),
	barricade = coat(120, 92, 62, Enum.Material.Wood),
	sandbag = coat(168, 148, 108, Enum.Material.Fabric),

	barrel = coat(116, 82, 52, Enum.Material.Wood),
	crate = coat(146, 112, 72, Enum.Material.WoodPlanks),
	["military crate"] = coat(96, 104, 78, Enum.Material.WoodPlanks),
	["ammo box"] = coat(88, 96, 74, Enum.Material.Metal),
	bench = coat(126, 96, 64, Enum.Material.Wood),
	chair = coat(124, 94, 62, Enum.Material.Wood),
	table = coat(130, 100, 66, Enum.Material.Wood),
	bed = coat(178, 158, 142, Enum.Material.Fabric),
	sofa = coat(122, 108, 128, Enum.Material.Fabric),
	rug = coat(150, 88, 78, Enum.Material.Fabric),
	bookshelf = coat(112, 84, 56, Enum.Material.Wood),
	["desk lamp"] = coat(214, 198, 148, Enum.Material.Metal),
	["kitchen counter"] = coat(186, 176, 162, Enum.Material.Marble),
	refrigerator = coat(198, 202, 206, Enum.Material.Metal),

	conveyor = coat(84, 86, 92, Enum.Material.Metal),
	dropper = coat(112, 118, 126, Enum.Material.Metal),
	furnace = coat(96, 84, 78, Enum.Material.Metal),
	generator = coat(108, 114, 118, Enum.Material.Metal),
	["storage tank"] = coat(142, 148, 152, Enum.Material.Metal),
	["factory machine"] = coat(112, 118, 124, Enum.Material.Metal),
	pipe = coat(126, 130, 134, Enum.Material.Metal),
	["mine cart"] = coat(96, 80, 66, Enum.Material.Metal),
	ore = coat(118, 112, 104, Enum.Material.Rock),
	pickaxe = coat(126, 100, 70, Enum.Material.Wood),

	altar = coat(158, 152, 142, Enum.Material.Marble),
	anvil = coat(74, 76, 82, Enum.Material.Metal),
	sword = coat(178, 182, 190, Enum.Material.Metal),
	shield = coat(122, 96, 66, Enum.Material.Wood),
	armor = coat(156, 160, 168, Enum.Material.Metal),
	rifle = coat(78, 72, 66, Enum.Material.Metal),
	pistol = coat(72, 72, 76, Enum.Material.Metal),
	["shooting target"] = coat(198, 190, 178, Enum.Material.Fabric),
	coffin = coat(96, 72, 50, Enum.Material.Wood),
	tombstone = coat(140, 138, 132, Enum.Material.Slate),
	treasure = coat(196, 160, 76, Enum.Material.Wood),
	candle = coat(232, 220, 190, Enum.Material.Sand),
	coin = coat(214, 176, 74, Enum.Material.Metal),
	gem = coat(96, 174, 190, Enum.Material.Glass),
	potion = coat(126, 168, 132, Enum.Material.Glass),
	["magic staff"] = coat(112, 86, 60, Enum.Material.Wood),
	egg = coat(224, 212, 188, Enum.Material.Sand),
}

local STONE = coat(140, 136, 128, Enum.Material.Slate)

local function hintFor(name: string): Coat?
	local lowered = string.lower(name)
	for _, hint in HINTS do
		--: Plain find: the fourth argument turns pattern matching off, so a
		--: part named `door.001` is not read as a pattern with a wildcard.
		if string.find(lowered, hint.word, 1, true) then
			return hint.coat
		end
	end
	return nil
end

--: Already carrying an artist's decision. Overwriting one with a guess makes
--: the model worse, and a mixed set is the normal case here.
local function alreadyColoured(part: BasePart): boolean
	if part:IsA("MeshPart") and (part :: MeshPart).TextureID ~= "" then
		return true
	end
	return part:FindFirstChildOfClass("SurfaceAppearance") ~= nil
end

local function vary(colour: Color3, amount: number, stream: any): Color3
	local h, s, v = colour:ToHSV()
	return Color3.fromHSV(
		(h + stream:number(-amount * 0.5, amount * 0.5)) % 1,
		math.clamp(s + stream:number(-amount, amount), 0, 1),
		math.clamp(v + stream:number(-amount, amount), 0.04, 1))
end

--[[
	Colour every uncoloured part of a model. Returns how many it painted.

	`stream` is optional; without one every copy of a model comes out
	identical, which is visible the moment a topic has one model and the world
	places it thirteen times.
]]
function Tint.apply(model: Instance, topic: string, stream: any?): number
	local roll = stream or Rng.stream("tint")
	local fallback = TOPICS[topic] or STONE
	--: One roll per model, not per part: varying each part separately turns a
	--: house into a patchwork, while varying the model keeps it one house that
	--: differs from the house next door.
	local shift = roll:number(-0.05, 0.05)

	local painted = 0
	local parts: { Instance } = if model:IsA("BasePart")
		then { model }
		else model:GetDescendants()

	for _, part in parts do
		if not part:IsA("BasePart") then
			continue
		end
		local basePart = part :: BasePart
		if alreadyColoured(basePart) then
			continue
		end

		local chosen = hintFor(basePart.Name) or fallback
		local h, s, v = chosen.colour:ToHSV()
		basePart.Color = Color3.fromHSV(h, s, math.clamp(v + shift, 0.04, 1))
		basePart.Material = chosen.material
		if chosen.material == Enum.Material.Glass then
			basePart.Transparency = math.max(basePart.Transparency, 0.35)
			basePart.Reflectance = 0.12
		end
		painted += 1
	end
	return painted
end

--[[
	Colour a model where each copy differs a little.

	For scatter: thirteen instances of the one tree a thin topic has, all the
	same green, read as thirteen copies. Varied, they read as trees.
]]
function Tint.applyVaried(model: Instance, topic: string, stream: any,
                          amount: number?): number
	local spread = amount or 0.07
	local fallback = TOPICS[topic] or STONE
	local painted = 0
	local parts: { Instance } = if model:IsA("BasePart")
		then { model }
		else model:GetDescendants()

	for _, part in parts do
		if not part:IsA("BasePart") then
			continue
		end
		local basePart = part :: BasePart
		if alreadyColoured(basePart) then
			continue
		end
		local chosen = hintFor(basePart.Name) or fallback
		basePart.Color = vary(chosen.colour, spread, stream)
		basePart.Material = chosen.material
		if chosen.material == Enum.Material.Glass then
			basePart.Transparency = math.max(basePart.Transparency, 0.35)
			basePart.Reflectance = 0.12
		end
		painted += 1
	end
	return painted
end

function Tint.topics(): { string }
	local out = {}
	for topic in TOPICS do
		table.insert(out, topic)
	end
	table.sort(out)
	return out
end

function Tint.describe(): { [string]: any }
	return { topics = #Tint.topics(), hints = #HINTS }
end

return Tint
