--!strict
--[[
	World — the six zones, laid out as a climb.

	`Sim` decides what a crate is worth and what a zone costs. This builds the
	ground you stand on, the crates you break, the eggs you buy and the gate
	between here and the next place.

	Why a climb and not a hub
	-------------------------

	The zones are a line, each one further out and higher than the last, joined
	by a bridge with a toll gate on it. That shape does three things a hub
	cannot: the next zone is *visible* from the one you are in, so the goal is
	on screen rather than in a menu; the gate is a physical object with a price
	written on it; and looking back down the line is the only progress bar the
	game needs.

	Everything themeable comes from `Theme`
	---------------------------------------

	Ground colour, material, prop topic and name. Nothing here reads a number
	that decides balance, and nothing in `Theme` reads a number that decides
	balance either -- which is the whole contract that makes the reskin cheap.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Theme = require(ReplicatedStorage.Shared.Theme)
local Sim = require(script.Parent.Sim)

local Place = Forge.Catalog.Place
local Itch = Forge.Catalog.ItchAssets
local Rng = Forge.Core.Rng

local World = {}

--: One pad per zone, in a line, each higher than the last. Wide enough to
--: run around in and small enough that the next gate is always in sight.
World.PAD = 150
World.GAP = 90
World.RISE = 14
World.CRATES_PER_ZONE = 22

--[[
	Which baked material each zone's ground uses.

	Names, not ids. The variants are built into the place at build time because
	`MaterialVariant.BaseMaterial` is plugin-only and a live server cannot write
	it -- see `Forge.Material`. A game that tries to define them at runtime gets
	nil and a flat grey floor, which is exactly what every game in this project
	had before textures existed.
]]
local ZONE_SURFACE = {
	{ variant = "MeadowGrass", base = Enum.Material.Grass },
	{ variant = "WoodFloor", base = Enum.Material.Ground },
	{ variant = "FrostGround", base = Enum.Material.Snow },
	{ variant = "EmberGround", base = Enum.Material.Ground },
	{ variant = "SkyStone", base = Enum.Material.Slate },
	{ variant = "VoidStone", base = Enum.Material.Rock },
}

local stream = Rng.stream("hatchling.world")
local zones: { any } = {}
local root: Folder? = nil

-- =================================== parts ==================================
local function slab(name: string, size: Vector3, at: Vector3, colour: Color3,
                    parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(at)
	part.Anchored = true
	part.Color = colour
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--: A surface, rather than a colour. `MaterialVariant` is a plain string
--: property on a part -- unlike the variant itself, a server can write this --
--: so the whole texture pipeline lands in one line here.
local function surface(part: BasePart, variant: string, base: Enum.Material)
	part.Material = base
	part.MaterialVariant = variant
end

local function sign(part: BasePart, text: string, colour: Color3, face: Enum.NormalId)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.CanvasSize = Vector2.new(760, 260)
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = colour
	--: SourceSansPro, because it is the one this project has verified. An
	--: unverified font id is a label that renders in the default face on some
	--: builds and nobody notices until a screenshot looks subtly wrong.
	label.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json",
		Enum.FontWeight.Heavy)
	label.Parent = gui
	return label
end

function World.centre(zone: number): Vector3
	return Vector3.new(0, (zone - 1) * World.RISE, (zone - 1) * (World.PAD + World.GAP))
end

-- =================================== crates =================================
--[[
	A crate is a thing you run into, not a thing you click.

	No prompt, no button: touching it breaks it. That is the genre's whole
	moment-to-moment feel and it is why a pet simulator is played with the
	movement keys rather than with the mouse. The prompt version was tried in
	the previous game in this repository and it turns a run into a queue.
]]
function World.crate(zone: number, index: number, parent: Instance): BasePart
	local theme = Theme.zones[zone]
	local angle = (index / World.CRATES_PER_ZONE) * math.pi * 2
	local radius = stream:number(18, World.PAD / 2 - 12)
	local at = World.centre(zone) + Vector3.new(
		math.sin(angle) * radius, 2.4, math.cos(angle) * radius)

	local box = slab("Crate", Vector3.new(4, 4, 4), at, theme.crate, parent)
	surface(box, "BareWood", Enum.Material.Wood)
	box.CanCollide = false
	box:SetAttribute("zone", zone)
	box.CFrame = CFrame.new(at) * CFrame.Angles(0, stream:number(0, 6.28), 0)
	return box
end

-- =================================== zones ==================================
local function buildZone(zone: number, parent: Instance): any
	local theme = Theme.zones[zone]
	local skin = ZONE_SURFACE[math.min(zone, #ZONE_SURFACE)]
	local centre = World.centre(zone)

	local folder = Instance.new("Folder")
	folder.Name = "Zone" .. zone
	folder.Parent = parent

	local ground = slab("Ground", Vector3.new(World.PAD, 4, World.PAD),
		centre - Vector3.new(0, 2, 0), theme.ground, folder)
	surface(ground, skin.variant, skin.base)

	--: A rim, so the pad reads as land with an edge rather than as a rectangle
	--: that stops. The player who walks off it should have seen it coming.
	local rim = slab("Rim", Vector3.new(World.PAD + 8, 3, World.PAD + 8),
		centre - Vector3.new(0, 4.5, 0),
		Color3.fromRGB(120, 108, 96), folder)
	surface(rim, "VoidStone", Enum.Material.Rock)

	local post = slab("Sign", Vector3.new(24, 8, 1), centre
		+ Vector3.new(0, 6, -World.PAD / 2 + 3), Color3.fromRGB(96, 72, 52), folder)
	surface(post, "BareWood", Enum.Material.Wood)
	sign(post, theme.name, Color3.fromRGB(252, 244, 226), Enum.NormalId.Back)

	--: Scenery from the catalogue, kept off the crate ring so nothing a player
	--: runs at is hidden behind a bush.
	local props = 0
	for index = 1, 16 do
		local angle = stream:number(0, math.pi * 2)
		local radius = stream:number(World.PAD / 2 - 26, World.PAD / 2 - 6)
		local model = Place.put(Itch, {
			topic = theme.prop, seed = zone * 97 + index,
			at = centre + Vector3.new(math.sin(angle) * radius, 0,
				math.cos(angle) * radius),
			yaw = stream:number(0, math.pi * 2), parent = folder,
			jitter = stream:number(0.7, 1.15),
		})
		if model then
			props += 1
		end
	end

	local crates = {}
	for index = 1, World.CRATES_PER_ZONE do
		table.insert(crates, World.crate(zone, index, folder))
	end

	return { zone = zone, folder = folder, centre = centre, crates = crates,
		props = props }
end

--[[
	The bridge and the gate between two zones.

	The gate is solid and the price is written on it, at the size of a door.
	A toll that lives only in a menu is a toll nobody knows they are saving for.
]]
local function buildGate(zone: number, parent: Instance): any
	local from, to = World.centre(zone - 1), World.centre(zone)
	local middle = (from + to) / 2

	local folder = Instance.new("Folder")
	folder.Name = "Gate" .. zone
	folder.Parent = parent

	local span = (to - from).Magnitude
	local bridge = slab("Bridge", Vector3.new(16, 2, span), middle
		- Vector3.new(0, 1.4, 0), Color3.fromRGB(176, 140, 96), folder)
	surface(bridge, "PlankFloor", Enum.Material.WoodPlanks)
	bridge.CFrame = CFrame.lookAt(bridge.Position, to)
		* CFrame.Angles(0, 0, 0)
	bridge.Size = Vector3.new(16, 2, span)

	local wall = slab("Barrier", Vector3.new(18, 16, 2),
		middle + Vector3.new(0, 7, 0), Color3.fromRGB(88, 78, 96), folder)
	surface(wall, "BrickWall", Enum.Material.Brick)
	wall.Transparency = 0.25
	local label = sign(wall, string.format("%s\n%s", Theme.zones[zone].name,
		World.money(Sim.zoneToll(zone))),
		Color3.fromRGB(255, 226, 150), Enum.NormalId.Back)
	label.RichText = false

	return { zone = zone, folder = folder, wall = wall, label = label,
		at = middle }
end

--: Short money, because a toll reading 58,644,420 is a toll nobody can compare
--: to the number in their HUD at a glance.
function World.money(value: number): string
	if value >= 1e12 then return string.format("%.1fT", value / 1e12) end
	if value >= 1e9 then return string.format("%.1fB", value / 1e9) end
	if value >= 1e6 then return string.format("%.1fM", value / 1e6) end
	if value >= 1e3 then return string.format("%.1fK", value / 1e3) end
	return tostring(math.floor(value))
end

-- ================================= hatchery =================================
--[[
	The egg stands, one per tier, all together at the start.

	Together on purpose. Seeing the egg you cannot afford yet, beside the one
	you can, is the cheapest and oldest motivator this genre has, and splitting
	them across zones hides the ladder from the player who most needs to see it.
]]
local function buildHatchery(parent: Instance): any
	local folder = Instance.new("Folder")
	folder.Name = "Hatchery"
	folder.Parent = parent

	local base = World.centre(1) + Vector3.new(0, 0, World.PAD / 2 - 26)
	local deck = slab("Deck", Vector3.new(Sim.EGG_TIERS * 16 + 12, 1.6, 20),
		base, Color3.fromRGB(186, 148, 104), folder)
	surface(deck, "PlankFloor", Enum.Material.WoodPlanks)

	local stands = {}
	for tier = 1, Sim.EGG_TIERS do
		local at = base + Vector3.new(
			(tier - (Sim.EGG_TIERS + 1) / 2) * 16, 3.4, 0)
		local plinth = slab("Egg" .. tier, Vector3.new(7, 5, 7), at,
			Color3.fromRGB(148, 122, 92), folder)
		surface(plinth, "PlasterWall", Enum.Material.Plaster)
		plinth:SetAttribute("egg", tier)

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "Hatch"
		prompt.ActionText = "Hatch"
		prompt.ObjectText = Theme.eggs[tier].name
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 11
		prompt.RequiresLineOfSight = false
		prompt.Parent = plinth

		--: The egg itself, sitting on the plinth, from the catalogue.
		local model = Place.put(Itch, {
			topic = Theme.eggs[tier].topic, seed = tier * 31,
			at = at + Vector3.new(0, 3.4, 0), parent = folder, jitter = 1.1,
		})

		local card = slab("Card" .. tier, Vector3.new(7, 3.2, 0.4),
			at + Vector3.new(0, -0.4, -3.8), Color3.fromRGB(64, 54, 74), folder)
		card.CanCollide = false
		local text = sign(card, string.format("%s\n%s",
			Theme.eggs[tier].name, World.money(Sim.eggCost(tier))),
			Color3.fromRGB(250, 240, 220), Enum.NormalId.Back)

		stands[tier] = { plinth = plinth, prompt = prompt, model = model,
			label = text }
	end
	return { folder = folder, stands = stands, at = base }
end

-- ================================== build ===================================
function World.build(): any
	World.clear()
	local folder = Instance.new("Folder")
	folder.Name = "World"
	folder.Parent = Workspace
	root = folder

	for zone = 1, Sim.ZONES do
		zones[zone] = buildZone(zone, folder)
		if zone > 1 then
			zones[zone].gate = buildGate(zone, folder)
		end
	end
	local hatchery = buildHatchery(folder)

	--: The one spawn, on the first pad, facing the hatchery. A player who
	--: arrives looking at the thing they are meant to press does not need a
	--: tutorial to find it.
	local pad = Instance.new("SpawnLocation")
	pad.Name = "Spawn"
	pad.Size = Vector3.new(14, 1, 14)
	pad.CFrame = CFrame.lookAt(
		World.centre(1) + Vector3.new(0, 0.5, -22), hatchery.at)
	pad.Anchored = true
	pad.Neutral = true
	--: `Neutral = false` with no Teams accepts nobody at all, which is a spawn
	--: pad that silently refuses every player. Learned the expensive way.
	pad.Material = Enum.Material.WoodPlanks
	pad.MaterialVariant = "PlankFloor"
	pad.Color = Color3.fromRGB(196, 156, 108)
	pad.Parent = folder

	return { zones = zones, hatchery = hatchery, spawn = pad }
end

function World.clear()
	if root then
		root:Destroy()
	end
	root = nil
	table.clear(zones)
end

function World.zone(index: number): any
	return zones[index]
end

--: Where to put a player who has just paid a toll. Walking them through the
--: gate they just opened is better than a fade, and it is one line.
function World.arrival(zone: number): CFrame
	return CFrame.lookAt(World.centre(zone) + Vector3.new(0, 4, -World.PAD / 2 + 14),
		World.centre(zone))
end

function World.describe(): { [string]: any }
	local crates, props = 0, 0
	for _, z in zones do
		crates += #z.crates
		props += z.props
	end
	return { zones = #zones, crates = crates, props = props,
		built = root ~= nil }
end

return World
