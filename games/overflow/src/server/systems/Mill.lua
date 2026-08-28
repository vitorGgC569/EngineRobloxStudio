--!strict
--[[
	Mill — the floor, the belt, the four chutes, and the light over them.

	Everything here is either a procedural part or a baked Creator Store prop
	rebuilt from data. Nothing is fetched at runtime, which in this build is not
	a preference: the publishing account is moderated, so every `rbxassetid://`
	in the engine's published catalogues answers HTTP 403 — including reads.
	`Forge.Catalog.Prop` is geometry stored *in the place*, so it is the one
	asset source that still works.

	The one thing this file must get right
	--------------------------------------

	**The belt has to read as a direction.** A player who cannot tell at a
	glance which way crates are travelling cannot anticipate anything, and
	anticipation is the entire game. So: the belt is a visibly different
	material from the floor, its chevrons point downstream, the head end has a
	machine on it and the tail end is an open drop, and the chutes are the only
	saturated colour in the room.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local Visual = Forge.Visual
local Prop = Forge.Catalog.Prop
local Mark = Forge.Mark
local Boot = Forge.Core.Boot

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Mill = {}

--: Filled in by `buildChutes`, read every tick by `Line`.
export type Chute = {
	spec: any,
	color: Color3,
	mouth: BasePart,
	lever: BasePart,
	glow: BasePart,
	light: PointLight,
	--: When the gate shuts. Zero means closed.
	openUntil: number,
	--: When it may next be pulled.
	readyAt: number,
}

Mill.chutes = {} :: { Chute }
Mill.belt = nil :: BasePart?
Mill.floorY = 0

local FLOOR_Y = 0
local BELT_TOP = Config.belt.y

--[[
	The operator's walkway, four studs above the belt.

	Not decoration and not realism-for-its-own-sake. With the levers on the same
	floor as the belt, the camera sits at belt height and the line is a thin
	horizontal band with a blown-out ceiling above it — measured from the first
	three screenshots, all of which framed more lighting than game.

	Standing the operator above the line puts the camera where it can see the
	whole belt at once, which is the view the game is actually played from: you
	are reading four crates and choosing where to be.
]]
local WALK_Y = 8

local function colourOf(rgb: { number }): Color3
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

local function part(name: string, size: Vector3, cf: CFrame, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.CanCollide = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- ================================== look ====================================
local function defineLook()
	Visual.defineLook("mill_floor", {
		--: Indoors, so the sun is scenery rather than the light source. Set low
		--: and warm so the windows read as evening and the chute lights are
		--: what the eye actually uses.
		clockTime = 17.4,
		brightness = 1.9,
		--: Lifted well above the first pass. Four walls block the sun entirely,
		--: so ambient is not a mood control here — it is whether the room has
		--: any light in it at all beyond the strips.
		ambient = Color3.fromRGB(76, 74, 86),
		outdoorAmbient = Color3.fromRGB(96, 94, 106),
		fogColor = Color3.fromRGB(38, 36, 44),
		fogStart = 90,
		fogEnd = 420,
		environmentDiffuse = 0.5,
		environmentSpecular = 0.4,
		geographicLatitude = 30,
		atmosphere = {
			--: Thick enough that the far end of the hall has air in it, which
			--: is what stops a long straight room reading as a corridor in a
			--: student project.
			density = 0.34,
			haze = 1.1,
			glare = 0.2,
			color = Color3.fromRGB(180, 170, 176),
			decay = Color3.fromRGB(70, 64, 74),
		},
		--: Threshold well above 1: the chute glows and the crates are the only
		--: things meant to bloom, and a low threshold blooms the floor.
		bloom = { intensity = 0.9, size = 24, threshold = 1.7 },
		colorCorrection = {
			contrast = 0.12,
			saturation = 0.06,
			tint = Color3.fromRGB(255, 250, 242),
		},
	})
end

-- ================================== room ====================================
local function buildRoom(container: Instance)
	local B = Config.belt
	local length = (B.tailX - B.headX) + 70
	local width = 90
	local centreX = (B.headX + B.tailX) * 0.5

	local floor = part("Floor", Vector3.new(length, 2, width),
		CFrame.new(centreX, FLOOR_Y - 1, B.z), container)
	--: Darker than the catwalk and much darker than the belt's chevrons, so the
	--: three surfaces separate by value and not only by hue.
	floor.Color = Color3.fromRGB(46, 45, 52)
	floor.Material = Enum.Material.Concrete
	Mark.exclude(floor)

	--[[
		Four walls, not three.

		The first build left the far side open so the camera would have
		somewhere to be, and got the opposite of what it wanted: the player
		faces that way, so every forward view was void with a floor under it.
		The camera lives *behind* the player, which is the near side — so the
		far side is a backdrop and wants to be solid.
	]]
	local wallHeight = 26
	local walls = {
		{ Vector3.new(length, wallHeight, 2), CFrame.new(centreX, wallHeight * 0.5, B.z - width * 0.5) },
		{ Vector3.new(length, wallHeight, 2), CFrame.new(centreX, wallHeight * 0.5, B.z + 34) },
		{ Vector3.new(2, wallHeight, width), CFrame.new(centreX - length * 0.5, wallHeight * 0.5, B.z) },
		{ Vector3.new(2, wallHeight, width), CFrame.new(centreX + length * 0.5, wallHeight * 0.5, B.z) },
	}
	for index, spec in walls do
		local w = part("Wall" .. index, spec[1], spec[2], container)
		w.Color = Color3.fromRGB(58, 56, 64)
		w.Material = Enum.Material.Brick
		Mark.exclude(w)
	end

	--[[
		Strip lights over the belt, close enough together to be a lit room.

		Seven at 26-stud spacing over a 226-stud hall left the middle distance
		black, which read as an unfinished world rather than a dim one. Thirteen
		at 14 studs, directly over the line rather than off to one side, is the
		difference between a room and a corridor with a lamp in it.
	]]
	for i = -6, 6 do
		local strip = part("Strip" .. i, Vector3.new(11, 0.6, 2.4),
			CFrame.new(centreX + i * 14, 23, B.z + 3), container)
		--: Not Neon. A neon strip at full brightness with bloom over it turned
		--: the top third of every screenshot into white, and the light the room
		--: needs comes from the PointLight underneath it rather than from the
		--: emissive surface. A lit room, not a lit ceiling.
		strip.Color = Color3.fromRGB(226, 220, 206)
		strip.Material = Enum.Material.SmoothPlastic
		strip.CanCollide = false
		strip.CastShadow = false
		--: 1.15, not 2.1. Thirteen lights at 2.1 over a grey room washed the
		--: floor and both walls to near-white — the opposite failure from the
		--: first pass and just as unreadable, because a scene with no dark in it
		--: has no shape in it either.
		local light = Instance.new("PointLight")
		light.Brightness = 1.15
		light.Range = 44
		light.Color = Color3.fromRGB(255, 246, 226)
		light.Shadows = false
		light.Parent = strip
		Mark.exclude(strip)
	end

	--[[
		The catwalk. It runs the length of the hall on the player's side, with
		its outer edge against the near wall so there is nowhere to fall off
		into — a reaction game that also asks you not to walk off a ledge is two
		games, and the second one is not fun.
	]]
	local walkNear = B.z - width * 0.5 + 1
	local walkFar = B.z - B.width * 0.5 - 4
	local walkDepth = walkFar - walkNear
	local walk = part("Catwalk", Vector3.new(length - 4, 1.5, walkDepth),
		CFrame.new(centreX, WALK_Y - 0.75, (walkNear + walkFar) * 0.5), container)
	walk.Color = Color3.fromRGB(88, 86, 94)
	walk.Material = Enum.Material.Metal
	Mark.exclude(walk)

	--: A kick rail along the belt-facing edge, so the drop reads as an edge
	--: rather than as somewhere to step.
	local kick = part("KickRail", Vector3.new(length - 4, 1.6, 0.6),
		CFrame.new(centreX, WALK_Y + 0.8, walkFar), container)
	kick.Color = Color3.fromRGB(196, 158, 72)
	kick.Material = Enum.Material.Metal
	kick.CanCollide = false
	Mark.exclude(kick)

	return floor
end

-- ================================== belt ====================================
--[[
	The trunk, and the chevrons that make it a direction.

	The chevrons are separate thin parts rather than a texture, because a
	texture is an asset and assets are what this account cannot fetch. Ten
	parts, one job: tell the player which way the room flows.
]]
local function buildBelt(container: Instance): BasePart
	local B = Config.belt
	local length = B.tailX - B.headX
	local centreX = (B.headX + B.tailX) * 0.5

	local bed = part("Belt", Vector3.new(length, 1.2, B.width),
		CFrame.new(centreX, BELT_TOP - 0.6, B.z), container)
	bed.Color = Color3.fromRGB(42, 41, 48)
	bed.Material = Enum.Material.DiamondPlate
	Mark.exclude(bed)

	--: Rails, so a crate reads as being *on* something rather than hovering.
	for _, side in { -1, 1 } do
		local rail = part("Rail", Vector3.new(length, 0.9, 0.7),
			CFrame.new(centreX, BELT_TOP - 0.1, B.z + side * (B.width * 0.5 + 0.35)), container)
		rail.Color = Color3.fromRGB(96, 92, 84)
		rail.Material = Enum.Material.Metal
		rail.CanCollide = false
		Mark.exclude(rail)
	end

	local chevrons = math.floor(length / 12)
	for i = 0, chevrons - 1 do
		local x = B.headX + 6 + i * 12
		local mark = part("Chevron", Vector3.new(3.2, 0.1, 0.9),
			CFrame.new(x, BELT_TOP + 0.02, B.z) * CFrame.Angles(0, math.rad(35), 0), container)
		mark.Color = Color3.fromRGB(210, 176, 96)
		mark.Material = Enum.Material.Neon
		mark.CanCollide = false
		mark.CastShadow = false
		mark.Transparency = 0.35
		Mark.exclude(mark)
	end

	--: The head machine and the tail drop, so both ends of the belt say what
	--: they are without a label.
	local headGround = Vector3.new(B.headX - 8, FLOOR_Y, B.z)
	Prop.place("dropper", Config.seed, headGround,
		{ targetHeight = 12, parent = container, canCollide = true })

	local pit = part("Overflow", Vector3.new(14, 1, B.width + 6),
		CFrame.new(B.tailX + 7, BELT_TOP - 3.2, B.z), container)
	pit.Color = Color3.fromRGB(24, 22, 26)
	pit.Material = Enum.Material.Slate
	pit.CanCollide = false
	Mark.exclude(pit)

	Mill.belt = bed
	return bed
end

-- ================================= chutes ===================================
--[[
	One chute: a mouth beside the belt, a lever to stand at, and a light.

	The lever is the thing the player runs to and the mouth is where the crate
	goes, and they are deliberately the same colour and a few studs apart, so
	the connection between "I am standing here" and "that hole opens" needs no
	explaining.
]]
local function buildChute(spec: any, container: Instance): Chute
	local B = Config.belt
	local colour = colourOf(spec.color)
	local zEdge = B.z + B.width * 0.5

	local model = Instance.new("Model")
	model.Name = "Chute_" .. spec.id
	model.Parent = container

	--: The mouth: an open box beside the belt, dark inside so it reads as a
	--: hole rather than a block.
	local mouth = part("Mouth", Vector3.new(Config.chutes.span, 5, 7),
		CFrame.new(spec.x, BELT_TOP - 1.2, zEdge + 4.2), model)
	mouth.Color = Color3.fromRGB(30, 29, 34)
	mouth.Material = Enum.Material.Metal
	mouth.CanCollide = false
	Mark.exclude(mouth)

	local lip = part("Lip", Vector3.new(Config.chutes.span + 1.4, 1, 1.2),
		CFrame.new(spec.x, BELT_TOP + 1.6, zEdge + 0.9), model)
	lip.Color = colour
	lip.Material = Enum.Material.SmoothPlastic
	lip.CanCollide = false
	Mark.exclude(lip)

	--: The glow strip. This is the gate's whole visual state: lit means open.
	local glow = part("Glow", Vector3.new(Config.chutes.span, 0.4, 0.9),
		CFrame.new(spec.x, BELT_TOP + 0.1, zEdge + 0.4), model)
	glow.Color = colour
	glow.Material = Enum.Material.SmoothPlastic
	glow.CanCollide = false
	glow.CastShadow = false
	Mark.exclude(glow)

	local light = Instance.new("PointLight")
	light.Brightness = 0
	light.Range = 26
	light.Color = colour
	light.Shadows = false
	light.Enabled = false
	light.Parent = glow

	--: The lever, on the player's side of the belt, standing on the floor.
	local lever = part("Lever", Vector3.new(2.4, 5.5, 2.4),
		CFrame.new(spec.x, WALK_Y + 2.75, B.z - B.width * 0.5 - 7), model)
	lever.Color = colour
	lever.Material = Enum.Material.Metal
	Mark.exclude(lever)

	local knob = part("Knob", Vector3.new(2.6, 1, 2.6),
		CFrame.new(spec.x, WALK_Y + 5.9, B.z - B.width * 0.5 - 7), model)
	knob.Shape = Enum.PartType.Ball
	knob.Color = colour
	knob.Material = Enum.Material.Neon
	knob.CanCollide = false
	knob.CastShadow = false
	Mark.exclude(knob)

	--[[
		The label, on a SurfaceGui facing the player.

		Billboards were the obvious choice and the wrong one: a BillboardGui
		turns to face the camera, so four of them along a wall all overlap when
		the player stands at one end of the room. A SurfaceGui stays on its own
		lever and is legible from where the lever matters.
	]]
	local sign = part("Sign", Vector3.new(9, 3, 0.4),
		CFrame.new(spec.x, WALK_Y + 9.5, B.z - B.width * 0.5 - 7), model)
	sign.Color = Color3.fromRGB(26, 25, 30)
	sign.Material = Enum.Material.SmoothPlastic
	sign.CanCollide = false
	Mark.exclude(sign)

	local surface = Instance.new("SurfaceGui")
	surface.Face = Enum.NormalId.Back
	surface.CanvasSize = Vector2.new(300, 100)
	surface.LightInfluence = 0
	surface.Parent = sign

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = spec.label
	text.TextColor3 = colour
	text.TextScaled = true
	text.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.Bold)
	text.Parent = surface

	--: A barrel and a crate beside each chute, so the room has objects in it
	--: that are not made of primitives.
	Prop.place(if spec.id == "ore" then "ore" else "crate",
		Config.seed + spec.x, Vector3.new(spec.x + 6, FLOOR_Y, B.z + 16),
		{ targetHeight = 3, parent = container, canCollide = false })

	return {
		spec = spec,
		color = colour,
		mouth = mouth,
		lever = lever,
		glow = glow,
		light = light,
		openUntil = 0,
		readyAt = 0,
	}
end

local function buildChutes(container: Instance)
	local made: { Chute } = {}
	for _, spec in Config.chutes do
		--: `Config.chutes` carries `span` alongside the four rows, so anything
		--: without an id is configuration rather than a chute.
		if type(spec) == "table" and spec.id then
			table.insert(made, buildChute(spec, container))
		end
	end
	Mill.chutes = made
	Debug.info(string.format("%d chutes built", #made))
	return made
end

--[[
	Paint a chute's gate to match its state.

	Called by `Play` whenever a gate changes, not on a timer: writing `Enabled`
	and `Color` on eight instances thirty times a second is thirty replication
	packets a second for values that did not change.
]]
function Mill.paintGate(chute: Chute, open: boolean)
	chute.glow.Material = if open then Enum.Material.Neon else Enum.Material.SmoothPlastic
	chute.glow.Transparency = if open then 0 else 0.4
	chute.light.Enabled = open
	chute.light.Brightness = if open then 3 else 0
	chute.mouth.Color = if open
		then chute.color:Lerp(Color3.fromRGB(0, 0, 0), 0.55)
		else Color3.fromRGB(30, 29, 34)
end

-- ================================== spawn ===================================
local function placeSpawn(container: Instance)
	local B = Config.belt
	--: Mid-line, on the player's side. A shift starts with the operator in the
	--: middle of their own run, which is the only fair place to start it.
	local pad = Instance.new("SpawnLocation")
	pad.Name = "MillSpawn"
	--: Small and dark. The first build made it twelve studs of near-white
	--: concrete directly under the camera, and it was the brightest and largest
	--: thing in every screenshot — a spawn pad out-competing the belt for the
	--: player's eye.
	pad.Size = Vector3.new(8, 0.6, 8)
	--[[
		Turned to face the belt, and this is not a detail.

		A character spawns facing its pad's own LookVector, and an unrotated
		part looks down **-Z**. The belt is at +Z from here, so the first build
		put every player's first frame against a blank wall thirty studs behind
		the line — measured, not guessed: a raycast from the spawned character's
		eye found `Mill.Wall1` ahead and nothing at all toward the belt.

		The whole game is reading what is coming. Spawning with your back to it
		is the worst single frame this game could open on.
	]]
	pad.CFrame = CFrame.new(0, WALK_Y + 0.3, B.z - B.width * 0.5 - 12)
		* CFrame.Angles(0, math.pi, 0)
	pad.Anchored = true
	pad.CanCollide = true
	pad.Neutral = true
	pad.Duration = 0
	pad.Color = Color3.fromRGB(64, 62, 70)
	pad.Material = Enum.Material.Concrete
	pad.TopSurface = Enum.SurfaceType.Smooth
	pad.Parent = container
	Mark.exclude(pad)
	return pad
end

function Mill.start()
	--[[
		Spawned, not inline.

		The bootstrap starts systems in a loop and `Line` and `Play` both wait
		on `mill_ready`. If this one blocked the loop while they had not started
		yet, the wait would be for a signal nobody was left running to send.
	]]
	task.spawn(function()
		defineLook()
		Visual.apply("mill_floor")

		local container = Workspace:FindFirstChild("Mill") or Workspace
		buildRoom(container)
		buildBelt(container)
		buildChutes(Workspace:FindFirstChild("Chutes") or container)
		placeSpawn(container)

		for _, chute in Mill.chutes do
			Mill.paintGate(chute, false)
		end

		Boot.signal("mill_ready")
		Debug.info("mill ready")
	end)
end

return Mill
