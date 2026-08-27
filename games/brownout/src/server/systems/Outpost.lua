--!strict
--[[
	Outpost — the generator, the lamp rings, and the beacon that gets you home.

	This is the only system that builds the middle of the map, and two of the
	three things it builds are gameplay wearing scenery's clothes:

	  * The **lamp rings** are the charge gauge. Charge maps to a lit radius,
	    and a lamp switches on when the radius reaches it, so a player watching
	    the outer ring go dark has read the generator's state without looking at
	    a single number. Nothing else in the game explains itself this cheaply.

	  * The **beacon** is a 300-stud column of light over the generator. It
	    exists because the first honest question about a game played in the dark
	    is "how do I get back", and the answer cannot be a compass UI. A player
	    240 studs out in fog needs to turn around and see where home is.

	The generator itself is a baked Creator Store prop rather than a stack of
	boxes, for the reason the whole asset pipeline exists: a machine made of
	four grey blocks reads as a placeholder, and a player who thinks they are
	looking at a placeholder stops believing the rest of the world.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local World = Forge.World
local Prop = Forge.Catalog.Prop
local Mark = Forge.Mark
local Boot = Forge.Core.Boot

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Shift = require(script.Parent.Parent:WaitForChild("core"):WaitForChild("Shift"))
local Props = require(script.Parent.Parent:WaitForChild("core"):WaitForChild("Props"))
local SoundBank = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sound"))
local Audio = Forge.Audio

local Outpost = {}

--: Filled in by `buildLamps`, read every tick by `Power`. Each entry carries
--: its distance from the generator so the tick does not recompute it 40 times
--: a second for objects that never move.
export type Lamp = {
	distance: number,
	bulb: BasePart,
	light: PointLight,
	lit: boolean,
	--: Only the inner ring carries one. Forty looping sounds is a mixer, not a
	--: soundscape, and the hum is there to make the outpost feel powered rather
	--: than to be heard from each post individually.
	hum: Sound?,
}

Outpost.lamps = {} :: { Lamp }
Outpost.pad = nil :: BasePart?
--: The column of light over the generator. Declared here rather than assigned
--: into the table from inside a function, which strict mode reads as writing a
--: field that does not exist.
Outpost.beacon = nil :: BasePart?
--: The generator's looping bed, so `applyRadius` can move its roll-off.
Outpost.generatorSound = nil :: Sound?

local LIT_BULB = Color3.fromRGB(255, 226, 168)
local DARK_BULB = Color3.fromRGB(46, 44, 48)

-- ================================ generator =================================
local function buildGenerator(container: Instance): BasePart
	local ground = World.surface(0, 0) or Vector3.new(0, 0, 0)

	--[[
		The deposit collar.

		A part rather than a ProximityPrompt: hauling is a run, and a run that
		ends in pressing E ends on a pause. The player sprints onto the pad and
		the cell goes in. `Power` does the distance check server-side each tick,
		so this part is a visual and a measurement anchor, never an authority.
	]]
	local pad = Instance.new("Part")
	pad.Name = "GeneratorPad"
	pad.Shape = Enum.PartType.Cylinder
	pad.Size = Vector3.new(1.2, 26, 26)
	--: A cylinder's length runs along X, so a floor disc is rotated onto Z.
	pad.CFrame = CFrame.new(ground + Vector3.new(0, 0.4, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	pad.Anchored = true
	pad.CanCollide = false
	pad.Color = Color3.fromRGB(58, 62, 74)
	pad.Material = Enum.Material.Metal
	pad.Parent = container
	Mark.exclude(pad)

	--: The machine. Scaled to something a person stands next to rather than on.
	local machine = Props.place("generator", Config.seed, ground, {
		height = 11,
		parent = container,
		canCollide = true,
		name = "Generator",
		--: Tight. This is the object the entire game points at, and a squat
		--: wide one hides itself behind its own footprint.
		maxAspect = 2.0,
	})
	if not machine then
		--: A missing bake must not take the map down with it. The pad still
		--: works, the game is still playable, and the log says what is wrong.
		Debug.error("no baked 'generator' prop; the outpost has a pad and no machine")
	end

	--: Two furnaces and a storage tank flanking it, so the pad reads as a plant
	--: rather than as one object on a disc.
	local flank = {
		{ topic = "furnace", offset = Vector3.new(-15, 0, -7), height = 8 },
		{ topic = "furnace", offset = Vector3.new(15, 0, -7), height = 8 },
		{ topic = "storage tank", offset = Vector3.new(0, 0, -18), height = 14 },
		{ topic = "pipe", offset = Vector3.new(-9, 0, 13), height = 3 },
		{ topic = "pipe", offset = Vector3.new(9, 0, 13), height = 3 },
	}
	for index, entry in flank do
		local at = ground + entry.offset
		local surface = World.surface(at.X, at.Z) or at
		--: `maxAspect` 2.2 here and not the scenery default. Everything on this
		--: pad is within twenty studs of the player and of the generator, so a
		--: prop that sprawls is a prop standing between them and the thing they
		--: are running towards. This is where the 48-stud "Terrible Furnace"
		--: got in and put a stone wall across the outpost.
		Props.place(entry.topic, Config.seed + index * 131, surface, {
			height = entry.height,
			parent = container,
			canCollide = true,
			maxAspect = 2.2,
		})
	end

	--: Crates and barrels, close in, as clutter that sells scale.
	local rand = Random.new(Config.seed + 7)
	for index = 1, 14 do
		local angle = rand:NextNumber() * math.pi * 2
		local radius = rand:NextNumber(17, 30)
		local x, z = math.cos(angle) * radius, math.sin(angle) * radius
		local surface = World.surface(x, z)
		if surface then
			Props.place(
				if index % 2 == 0 then "crate" else "barrel",
				Config.seed + index * 977,
				surface,
				{
					height = rand:NextNumber(2.2, 3.4),
					parent = container,
					canCollide = true,
					maxAspect = 2.4,
				}
			)
		end
	end

	--[[
		The plant's own bed, attached to the pad.

		Its roll-off is driven from the lit radius every time the lamps change,
		so the sound of the outpost shrinks as the lights go out. That is the
		audio half of the beacon: a player lost past the last lamp can turn
		until it gets louder.
	]]
	Outpost.generatorSound = Audio.attach("machine.generator", pad)

	Outpost.pad = pad
	Shift.generator = pad
	return pad
end

-- ================================= beacon ===================================
--[[
	The way home.

	A tall, thin, fully-bright part with a light at its base. Not a Beam: a Beam
	needs two attachments and faces the camera, which at 300 studs in fog reads
	as a flat sticker. A part with `Material = Neon` and no shadow is a shaft of
	light from every angle, and it costs one instance.
]]
local function buildBeacon(container: Instance, ground: Vector3)
	--[[
		Its base is eighteen studs up, not on the floor.

		The first build ran the column from the ground, and the generator pad is
		exactly where players stand to deliver — so the brightest object in the
		game passed straight through the character at the moment the player was
		looking at their own delivery. Starting it above head height keeps it
		readable from four hundred studs and out of the way at four.
	]]
	local BASE = 18
	local HEIGHT = 260

	local shaft = Instance.new("Part")
	shaft.Name = "Beacon"
	shaft.Size = Vector3.new(1.2, HEIGHT, 1.2)
	shaft.CFrame = CFrame.new(ground + Vector3.new(0, BASE + HEIGHT * 0.5, 0))
	shaft.Anchored = true
	shaft.CanCollide = false
	shaft.CastShadow = false
	shaft.Material = Enum.Material.Neon
	shaft.Color = Color3.fromRGB(120, 214, 255)
	shaft.Transparency = 0.55
	shaft.Parent = container
	Mark.exclude(shaft)

	--[[
		The light stays low, on an attachment at the base.

		Parented to the shaft it would sit at the shaft's centre, which after
		lifting the column clear of the pad is 148 studs in the air — a beacon
		that lights the sky and leaves the machine underneath it dark. The
		column is the landmark; this is the lamp over the generator.
	]]
	local base = Instance.new("Attachment")
	base.Name = "BeaconBase"
	base.Position = Vector3.new(0, -HEIGHT * 0.5 - BASE + 6, 0)
	base.Parent = shaft

	local glow = Instance.new("PointLight")
	glow.Name = "BeaconGlow"
	glow.Brightness = 2.2
	glow.Range = 40
	glow.Color = Color3.fromRGB(150, 220, 255)
	--: The one light in the game allowed to cast shadows. Future lighting pays
	--: per shadow-casting light per frame, and forty lamp shadows is a
	--: framerate, not a look.
	glow.Shadows = true
	glow.Parent = base

	Outpost.beacon = shaft
	return shaft
end

-- ============================== the lamp rings ==============================
--[[
	One lamp: a baked street lamp, a bulb, and a light in the bulb.

	The bulb is a separate Neon part rather than a recoloured piece of the prop,
	because a baked prop's parts are whatever its author modelled and there is
	no reliable "the bulb one". A part placed at a known offset is a part this
	system can switch on.
]]
local function buildLamp(container: Instance, position: Vector3, seed: number): Lamp?
	local post = Props.place("street lamp", seed, position, {
		height = 13,
		parent = container,
		canCollide = true,
		--: A lamp post is tall and thin by definition; anything wider than it
		--: is tall is not a lamp and would swallow its own bulb.
		maxAspect = 1.4,
	})
	if not post then
		return nil
	end

	local bulb = Instance.new("Part")
	bulb.Name = "Bulb"
	bulb.Shape = Enum.PartType.Ball
	bulb.Size = Vector3.new(1.7, 1.7, 1.7)
	bulb.CFrame = CFrame.new(position + Vector3.new(0, 12.4, 0))
	bulb.Anchored = true
	bulb.CanCollide = false
	bulb.CastShadow = false
	bulb.Material = Enum.Material.Neon
	bulb.Color = DARK_BULB
	bulb.Parent = post
	Mark.exclude(bulb)

	local light = Instance.new("PointLight")
	light.Brightness = 0
	--[[
		Range a little over the ring spacing, so the lit zone is a continuous
		field rather than forty separate puddles with dark between — and not
		much over.

		It was 46 against a 28-stud ring spacing and an inner ring at radius 34,
		which meant all four inner lamps reached the middle at once and the
		generator pad was lit four times over. Matching the range to the spacing
		keeps the field continuous without stacking it.
	]]
	light.Range = 36
	light.Color = Color3.fromRGB(255, 214, 150)
	light.Shadows = false
	light.Enabled = false
	light.Parent = bulb

	return { distance = (position * Vector3.new(1, 0, 1)).Magnitude, bulb = bulb, light = light, lit = false, hum = nil }
end

local function buildLamps(container: Instance)
	local L = Config.light
	local lamps: { Lamp } = {}

	for ringIndex, radius in L.rings do
		local count = L.lampsPerRing[ringIndex] or 6
		--: Each ring offset by half a step, so the lamps do not line up into
		--: spokes when seen from the middle.
		local phase = (ringIndex % 2) * (math.pi / count)
		for i = 1, count do
			local angle = phase + (i - 1) / count * math.pi * 2
			local x, z = math.cos(angle) * radius, math.sin(angle) * radius
			local ground = World.surface(x, z)
			if ground then
				local lamp = buildLamp(container, ground, ringIndex * 1009 + i * 37)
				if lamp then
					table.insert(lamps, lamp)
				end
			end
		end
	end

	--: The innermost ring gets a ballast hum; the rest are silent.
	local innerRadius = L.rings[1] or 0
	local hummed = 0
	for _, lamp in lamps do
		if lamp.distance <= innerRadius + 4 then
			lamp.hum = Audio.attach("machine.lamp", lamp.bulb)
			hummed += 1
		end
	end

	Outpost.lamps = lamps
	Debug.info(string.format("%d lamps across %d rings (%d humming)", #lamps, #L.rings, hummed))
	return lamps
end

--[[
	Switch lamps to match a lit radius.

	Called by `Power` every tick. Cheap on purpose: it touches only the lamps
	whose state actually changed, because writing `Enabled` and `Color` on forty
	instances thirty times a second is forty replication packets a second for a
	value that did not change.
]]
function Outpost.applyRadius(radius: number)
	for _, lamp in Outpost.lamps do
		local shouldBeLit = lamp.distance <= radius
		if shouldBeLit == lamp.lit then
			continue
		end
		lamp.lit = shouldBeLit
		lamp.light.Enabled = shouldBeLit
		lamp.light.Brightness = if shouldBeLit then 1.9 else 0
		lamp.bulb.Color = if shouldBeLit then LIT_BULB else DARK_BULB
		lamp.bulb.Material = if shouldBeLit then Enum.Material.Neon else Enum.Material.Glass
		if lamp.hum then
			--: A dark lamp is a dead lamp. Silencing it is the cheapest way the
			--: soundscape agrees with what the player can see.
			lamp.hum.Playing = shouldBeLit
		end
	end

	--: The plant is audible exactly as far as it is lit.
	local bed = Outpost.generatorSound
	if bed then
		bed.RollOffMaxDistance = math.max(40, radius)
	end
end

--: How bright the beacon is, so a blackout is visible from the far ring.
function Outpost.setBeacon(alpha: number)
	local shaft = Outpost.beacon
	if not shaft then
		return
	end
	shaft.Transparency = 0.9 - 0.35 * math.clamp(alpha, 0, 1)
	local glow = shaft:FindFirstChild("BeaconGlow", true)
	if glow and glow:IsA("PointLight") then
		glow.Brightness = 0.5 + 2.4 * math.clamp(alpha, 0, 1)
	end
end

function Outpost.start()
	task.spawn(function()
		if not Boot.await("ground_ready", 120) then
			Debug.error("outpost gave up waiting for ground; nothing was built")
			return
		end

		local container = Workspace:FindFirstChild("Outpost") or Workspace
		local lampFolder = Workspace:FindFirstChild("Lamps") or container

		local pad = buildGenerator(container)
		buildBeacon(container, pad.Position - Vector3.new(0, 0.4, 0))
		buildLamps(lampFolder)

		--: Lit to whatever the generator currently holds, so the first frame a
		--: player sees is already correct rather than every lamp on and then a
		--: visible snap to the real state.
		Outpost.applyRadius(Shift.radius())
		Outpost.setBeacon(1)

		Boot.signal("outpost_ready")
		Debug.info("outpost ready")
	end)
end

return Outpost
