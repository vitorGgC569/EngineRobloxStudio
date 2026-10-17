--!strict
--[[
	LandmarkKit — the far side of the horizon, built from parts.

	BuildKit dresses the places players stand on. This dresses the places they
	sail *toward*: a lighthouse that marks the harbor, a shack, a wreck, an
	arch, a cave mouth, a ruined watchtower, a campfire, and a small shrine for
	each water. Every builder returns one Model with a PrimaryPart and no
	Scripts inside it, so a validator can count it and a server can place it
	without trusting a network fetch.

	Nothing here is welded. A landmark's placement is computed before its parts
	exist, so a PivotTo is never needed, and per ENGINE-FACTS a weld between
	two anchored parts is inert anyway — it would be instance budget spent on
	nothing. Every part is both anchored and where it belongs.

	`LandmarkKit.build(spec, parent)` dispatches by `spec.kind` and is the only
	door the service uses, which is what keeps the plan and the builders
	describing the same set of things.
]]

local BuildKit = require(script.Parent.BuildKit)

local LandmarkKit = {}

--: Colour beyond BuildKit's wood-and-rope set. Named so a call site reads
--: `palette.beaconRed` instead of a literal, and so the night dressing can
--: quote the same warm lantern colour the builders use.
LandmarkKit.palette = {
	whitewash = Color3.fromRGB(214, 208, 196),
	beaconRed = Color3.fromRGB(176, 72, 58),
	lantern = Color3.fromRGB(255, 206, 138),
	beacon = Color3.fromRGB(255, 240, 205),
	glass = Color3.fromRGB(198, 224, 226),
	rock = Color3.fromRGB(112, 108, 104),
	rockDark = Color3.fromRGB(82, 80, 80),
	caveDark = Color3.fromRGB(24, 22, 26),
	algae = Color3.fromRGB(74, 122, 88),
	hull = Color3.fromRGB(96, 78, 58),
	hullDark = Color3.fromRGB(66, 54, 42),
	kelp = Color3.fromRGB(96, 148, 72),
	kelpDeep = Color3.fromRGB(62, 108, 60),
	glow = Color3.fromRGB(120, 232, 216),
	ash = Color3.fromRGB(88, 84, 78),
	flame = Color3.fromRGB(255, 156, 66),
}

--: Per-zone flavour for the shrines: the accent colour a zone already uses on
--: its buoys, plus the material word the vignette is built from. The zone
--: names and blurbs live in Config; this only has to quote them.
LandmarkKit.zoneFlavour = {
	shallows = { color = Color3.fromRGB(120, 220, 255), motif = "driftwood" },
	kelp = { color = Color3.fromRGB(110, 230, 150), motif = "kelp" },
	coral = { color = Color3.fromRGB(255, 170, 200), motif = "coral" },
	storm = { color = Color3.fromRGB(255, 210, 120), motif = "splinter" },
	abyss = { color = Color3.fromRGB(190, 140, 255), motif = "cairn" },
}

--: One Model from a table of part specs, stamped as in BuildKit.assemble but
--: without welds — see the header for why.
function LandmarkKit.assemble(name: string, parent: Instance?, specs: { any }): Model
	local model = Instance.new("Model")
	model.Name = name
	local root: BasePart? = nil
	for _, spec in specs do
		local part = BuildKit.part(spec)
		part.Parent = model
		if spec.root or not root then
			root = part
		end
	end
	model.PrimaryPart = root
	model.Parent = parent
	return model
end

local function pointLight(part: BasePart, range: number, brightness: number?, name: string?): PointLight
	local light = Instance.new("PointLight")
	light.Name = name or "Glow"
	light.Color = LandmarkKit.palette.lantern
	light.Brightness = brightness or 2.0
	light.Range = range
	light.Shadows = false
	light.Parent = part
	return light
end

local function frame(at: Vector3, yaw: number?): CFrame
	return CFrame.new(at) * CFrame.Angles(0, yaw or 0, 0)
end

-- ================================ lighthouse ================================
--[[
	The harbor's landmark: plinth, a six-band taper in the classic white and
	red, gallery, lantern room and a beam that only exists at night. The beam
	is an Attachment pair the service spins — this module builds the lantern,
	the service drives the light, and neither needs a Script to do it.
]]
function LandmarkKit.lighthouse(spec: any, parent: Instance?): Model
	local at = spec.at :: Vector3
	local base = frame(at, spec.yaw)
	local palette = LandmarkKit.palette

	local specs: { any } = {
		{ name = "Plinth", size = Vector3.new(13, 2, 13), cframe = base * CFrame.new(0, 1, 0), mat = "stone", color = palette.rock, root = true },
		{ name = "PlinthCap", size = Vector3.new(15, 0.9, 15), cframe = base * CFrame.new(0, 2.45, 0), mat = "stone", color = palette.rockDark },
		{ name = "Door", size = Vector3.new(2.6, 5, 0.4), cframe = base * CFrame.new(0, 4.9, 6.7), mat = "wood", color = BuildKit.palette.woodDark, collide = false },
	}

	local height = 10.2
	local y = 2.9
	for band = 1, 6 do
		local diameter = 9.6 - (band - 1) * 0.72
		table.insert(specs, {
			name = "Band" .. band,
			size = Vector3.new(height, diameter, diameter),
			cframe = base * CFrame.new(0, y + height / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
			mat = "stone",
			color = if band % 2 == 1 then palette.whitewash else palette.beaconRed,
		})
		y += height
	end

	local galleryY = y
	table.insert(specs, {
		name = "Gallery",
		size = Vector3.new(1.8, 9.6, 9.6),
		cframe = base * CFrame.new(0, galleryY + 0.9, 0) * CFrame.Angles(0, 0, math.pi / 2),
		mat = "stone",
		color = palette.rockDark,
	})
	for step = 0, 7 do
		local angle = step * math.pi / 4
		table.insert(specs, {
			name = "Rail" .. step,
			size = Vector3.new(0.4, 3.2, 0.4),
			cframe = base * CFrame.new(math.cos(angle) * 4.2, galleryY + 3.2, math.sin(angle) * 4.2),
			mat = "metal",
			color = BuildKit.palette.metal,
			collide = false,
		})
	end

	local lanternY = galleryY + 1.8
	table.insert(specs, {
		name = "LanternBase",
		size = Vector3.new(0.9, 6.4, 6.4),
		cframe = base * CFrame.new(0, lanternY + 0.45, 0) * CFrame.Angles(0, 0, math.pi / 2),
		mat = "metal",
		color = BuildKit.palette.metal,
	})
	table.insert(specs, {
		name = "LanternGlass",
		size = Vector3.new(5.2, 5.4, 5.4),
		cframe = base * CFrame.new(0, lanternY + 3.3, 0) * CFrame.Angles(0, 0, math.pi / 2),
		mat = "glass",
		color = palette.glass,
		transparency = 0.55,
		collide = false,
	})
	table.insert(specs, {
		name = "LanternCore",
		size = Vector3.new(4.6, 2.6, 2.6),
		cframe = base * CFrame.new(0, lanternY + 3.3, 0) * CFrame.Angles(0, 0, math.pi / 2),
		mat = "neon",
		color = palette.beacon,
		collide = false,
		shadow = false,
	})
	table.insert(specs, {
		name = "Roof",
		size = Vector3.new(1.6, 6.6, 6.6),
		cframe = base * CFrame.new(0, lanternY + 6.8, 0) * CFrame.Angles(0, 0, math.pi / 2),
		mat = "metal",
		color = palette.beaconRed,
	})
	table.insert(specs, {
		name = "Finial",
		size = Vector3.new(1.6, 1.6, 1.6),
		cframe = base * CFrame.new(0, lanternY + 8.4, 0),
		mat = "metal",
		color = BuildKit.palette.brass,
		collide = false,
	})

	local model = LandmarkKit.assemble("Lighthouse", parent, specs)
	local core = model:FindFirstChild("LanternCore") :: BasePart
	pointLight(core, 48, 2.2, "BeaconLight")

	--[[
		The beam rides two Attachments parented to the lantern core, so
		rotating it is one Position write per tick and needs no moving parts.
		Disabled by default: the lantern burns day and night, the beam is the
		night dressing the service turns on when the clock passes dusk.
	]]
	local beamStart = Instance.new("Attachment")
	beamStart.Name = "BeamStart"
	beamStart.Position = Vector3.new(0, 0, 0)
	beamStart.Parent = core

	local beamEnd = Instance.new("Attachment")
	beamEnd.Name = "BeamEnd"
	beamEnd.Position = Vector3.new(0, 0, 72)
	beamEnd.Parent = core

	local beam = Instance.new("Beam")
	beam.Name = "Beam"
	beam.Attachment0 = beamStart
	beam.Attachment1 = beamEnd
	--: Beam.Color is a ColorSequence, not a Color3 (measured: assigning a
	--: Color3 here aborts the server boot mid-landmark-loop).
	beam.Color = ColorSequence.new(palette.beacon)
	beam.Width0 = 2.2
	beam.Width1 = 9.5
	beam.LightEmission = 1
	beam.FaceCamera = false
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.Enabled = false
	beam.Parent = core

	return model
end

-- =============================== fishing shack ==============================
--: A small shack with a sign and a clothesline. Anchors face +Z; the service
--: aims `yaw` at whatever the shack should face.
function LandmarkKit.fishingShack(spec: any, parent: Instance?): Model
	local at = spec.at :: Vector3
	local base = frame(at, spec.yaw)
	local palette = LandmarkKit.palette
	local wood = BuildKit.palette

	local specs: { any } = {
		{ name = "Floor", size = Vector3.new(14, 0.8, 10), cframe = base * CFrame.new(0, 0.4, 0), mat = "wood", color = wood.wood, root = true },
		{ name = "PostFL", size = Vector3.new(0.8, 8.6, 0.8), cframe = base * CFrame.new(-6.5, 4.3, 4.5), mat = "wood", color = wood.woodDark },
		{ name = "PostFR", size = Vector3.new(0.8, 8.6, 0.8), cframe = base * CFrame.new(6.5, 4.3, 4.5), mat = "wood", color = wood.woodDark },
		{ name = "PostBL", size = Vector3.new(0.8, 8.6, 0.8), cframe = base * CFrame.new(-6.5, 4.3, -4.5), mat = "wood", color = wood.woodDark },
		{ name = "PostBR", size = Vector3.new(0.8, 8.6, 0.8), cframe = base * CFrame.new(6.5, 4.3, -4.5), mat = "wood", color = wood.woodDark },
		{ name = "WallBack", size = Vector3.new(14, 7.5, 0.5), cframe = base * CFrame.new(0, 4.55, -4.55), mat = "wood", color = wood.woodLight },
		{ name = "WallLeft", size = Vector3.new(0.5, 7.5, 9.6), cframe = base * CFrame.new(-6.55, 4.55, 0), mat = "wood", color = wood.woodLight },
		{ name = "WallRight", size = Vector3.new(0.5, 7.5, 9.6), cframe = base * CFrame.new(6.55, 4.55, 0), mat = "wood", color = wood.woodLight },
		{ name = "WallFrontL", size = Vector3.new(5.5, 7.5, 0.5), cframe = base * CFrame.new(-4, 4.55, 4.55), mat = "wood", color = wood.woodLight },
		{ name = "WallFrontR", size = Vector3.new(5.5, 7.5, 0.5), cframe = base * CFrame.new(4, 4.55, 4.55), mat = "wood", color = wood.woodLight },
		{ name = "Lintel", size = Vector3.new(4, 1.6, 0.5), cframe = base * CFrame.new(0, 7.6, 4.55), mat = "wood", color = wood.woodDark },
		{ name = "RoofL", size = Vector3.new(8.8, 0.6, 11.6), cframe = base * CFrame.new(-3.9, 10.2, 0) * CFrame.Angles(0, 0, math.rad(30)), mat = "wood", color = wood.woodDark },
		{ name = "RoofR", size = Vector3.new(8.8, 0.6, 11.6), cframe = base * CFrame.new(3.9, 10.2, 0) * CFrame.Angles(0, 0, math.rad(-30)), mat = "wood", color = wood.woodDark },
		{ name = "Ridge", size = Vector3.new(1, 1, 11.8), cframe = base * CFrame.new(0, 12.2, 0), mat = "wood", color = wood.woodDark },
		{ name = "SignBoard", size = Vector3.new(5, 2, 0.35), cframe = base * CFrame.new(0, 8.9, 5), mat = "wood", color = wood.woodDark, collide = false },
		{ name = "PostClothesA", size = Vector3.new(0.5, 7, 0.5), cframe = base * CFrame.new(-9.8, 3.5, 3.4), mat = "wood", color = wood.woodDark },
		{ name = "PostClothesB", size = Vector3.new(0.5, 7, 0.5), cframe = base * CFrame.new(-9.8, 3.5, -3.6), mat = "wood", color = wood.woodDark },
		{ name = "ClothesLine", size = Vector3.new(0.16, 0.16, 7), cframe = base * CFrame.new(-9.8, 6.7, -0.1), mat = "rope", color = wood.rope, collide = false, query = false },
		{ name = "ClothA", size = Vector3.new(0.14, 2.9, 1.9), cframe = base * CFrame.new(-9.8, 5.25, 1.9), mat = "canvas", color = wood.canvas, collide = false, query = false },
		{ name = "ClothB", size = Vector3.new(0.14, 2.4, 1.5), cframe = base * CFrame.new(-9.8, 5.5, -0.6), mat = "canvas", color = BuildKit.palette.waterTrim, collide = false, query = false },
		{ name = "ClothC", size = Vector3.new(0.14, 3.1, 1.7), cframe = base * CFrame.new(-9.8, 5.15, -2.6), mat = "canvas", color = wood.canvas, collide = false, query = false },
		{ name = "LanternArm", size = Vector3.new(1.6, 0.3, 0.3), cframe = base * CFrame.new(-3.4, 6.6, 5.1), mat = "metal", color = BuildKit.palette.metal },
		{ name = "LanternHang", size = Vector3.new(0.9, 1.4, 0.9), cframe = base * CFrame.new(-4.1, 5.7, 5.1), mat = "neon", color = palette.lantern, collide = false, query = false },
	}

	local model = LandmarkKit.assemble("FishingShack", parent, specs)
	pointLight(model:FindFirstChild("LanternHang") :: BasePart, 26, 1.8, "ShackLight")

	--[[
		The sign is geometry — an anchor emblem bolted to the board — and not
		a SurfaceGui. A landmark assembled from parts can be assembled by the
		headless harness and measured there; lettering painted onto a face
		can only be believed in Studio, and a believed claim is not evidence.
		The emblem also survives at the distance a mast approaches a dock,
		which two lines of text on a five-stud board do not.
	]]
	local brass = BuildKit.palette.brass
	local emblemParts: { any } = {
		{ name = "EmblemShank", size = Vector3.new(0.35, 1.15, 0.22), cframe = base * CFrame.new(0, 8.85, 5.32) },
		{ name = "EmblemStock", size = Vector3.new(1.5, 0.28, 0.22), cframe = base * CFrame.new(0, 9.12, 5.32) },
		{ name = "EmblemRing", size = Vector3.new(0.38, 0.38, 0.22), cframe = base * CFrame.new(0, 9.58, 5.32) },
		{ name = "EmblemArmA", size = Vector3.new(0.62, 0.3, 0.22), cframe = base * CFrame.new(-0.42, 8.35, 5.32) * CFrame.Angles(0, 0, math.rad(38)) },
		{ name = "EmblemArmB", size = Vector3.new(0.62, 0.3, 0.22), cframe = base * CFrame.new(0.42, 8.35, 5.32) * CFrame.Angles(0, 0, math.rad(-38)) },
	}
	for _, spec in emblemParts do
		spec.mat = "metal"
		spec.color = brass
		spec.collide = false
		spec.query = false
		spec.shadow = false
		spec.parent = model
		BuildKit.part(spec)
	end

	return model
end

-- ================================ shipwreck =================================
--: A broken hull aground on the sand, tilted so the keel bites. Anchors face
--: +Z (the bow); the service aims it at the open water.
function LandmarkKit.shipwreck(spec: any, parent: Instance?): Model
	local at = spec.at :: Vector3
	local base = frame(at, spec.yaw)
	local palette = LandmarkKit.palette
	local wood = BuildKit.palette
	local tilt = math.rad(13)

	local specs: { any } = {
		{ name = "Keel", size = Vector3.new(3.2, 2.6, 26), cframe = base * CFrame.new(0, 2.2, 0) * CFrame.Angles(tilt, 0, 0), mat = "wood", color = palette.hullDark, root = true },
		{ name = "HullLowerA", size = Vector3.new(1.6, 3.4, 24), cframe = base * CFrame.new(-3.4, 3.2, 0) * CFrame.Angles(tilt, 0, 0), mat = "wood", color = palette.hull },
		{ name = "HullLowerB", size = Vector3.new(1.6, 3.4, 24), cframe = base * CFrame.new(3.4, 3.2, 0) * CFrame.Angles(tilt, 0, 0), mat = "wood", color = palette.hull },
		{ name = "HullUpperA", size = Vector3.new(1.4, 3, 19), cframe = base * CFrame.new(-4.7, 5.4, -1.5) * CFrame.Angles(tilt, 0, 0), mat = "wood", color = palette.hullDark },
		{ name = "HullUpperB", size = Vector3.new(1.4, 2.6, 12), cframe = base * CFrame.new(4.7, 5.2, 2.5) * CFrame.Angles(tilt, 0, 0), mat = "wood", color = palette.hullDark },
		{ name = "Stern", size = Vector3.new(7.6, 7.6, 1.8), cframe = base * CFrame.new(0, 4.6, -12.2) * CFrame.Angles(tilt, 0, 0), mat = "wood", color = palette.hull },
		{ name = "Bow", size = Vector3.new(5.4, 5.4, 1.6), cframe = base * CFrame.new(0, 3.9, 12.4) * CFrame.Angles(tilt, 0, math.rad(18)), mat = "wood", color = palette.hullDark },
		{ name = "RibA", size = Vector3.new(0.5, 5.4, 0.9), cframe = base * CFrame.new(-1.2, 6, -5.5) * CFrame.Angles(tilt, 0, math.rad(10)), mat = "wood", color = palette.hullDark, collide = false },
		{ name = "RibB", size = Vector3.new(0.5, 6.4, 0.9), cframe = base * CFrame.new(0.4, 6.6, 0.5) * CFrame.Angles(tilt, 0, math.rad(-8)), mat = "wood", color = palette.hullDark, collide = false },
		{ name = "RibC", size = Vector3.new(0.5, 4.6, 0.9), cframe = base * CFrame.new(1.4, 5.6, 6.5) * CFrame.Angles(tilt, 0, math.rad(14)), mat = "wood", color = palette.hullDark, collide = false },
		{ name = "MastStub", size = Vector3.new(9.5, 1.1, 1.1), cframe = base * CFrame.new(1.6, 7.4, 2.6) * CFrame.Angles(tilt, 0, math.rad(38)), mat = "wood", color = palette.hullDark, collide = false },
		{ name = "MastTip", size = Vector3.new(5, 0.9, 0.9), cframe = base * CFrame.new(6.6, 4.4, 5.4) * CFrame.Angles(tilt, 0, math.rad(74)), mat = "wood", color = palette.hullDark, collide = false },
		{ name = "Spar", size = Vector3.new(1, 1, 8.5), cframe = base * CFrame.new(-4.6, 4.6, -4) * CFrame.Angles(tilt, 0, math.rad(-64)), mat = "wood", color = wood.woodLight, collide = false },
		{ name = "DebrisPlankA", size = Vector3.new(5.4, 0.4, 1.2), cframe = base * CFrame.new(-8.6, 0.4, 8.5) * CFrame.Angles(0, math.rad(24), 0), mat = "wood", color = wood.woodLight },
		{ name = "DebrisPlankB", size = Vector3.new(3.8, 0.4, 1), cframe = base * CFrame.new(7.6, 0.4, 9.6) * CFrame.Angles(0, math.rad(-40), 0), mat = "wood", color = palette.hull, collide = false },
		{ name = "DebrisCrate", size = Vector3.new(3, 3, 3), cframe = base * CFrame.new(9.2, 1.6, -5.4) * CFrame.Angles(0, math.rad(12), 0), mat = "wood", color = wood.wood },
		{ name = "LanternHook", size = Vector3.new(0.3, 0.3, 2.6), cframe = base * CFrame.new(-3.6, 8.4, -12) * CFrame.Angles(tilt, 0, 0), mat = "metal", color = BuildKit.palette.metal, collide = false },
		{ name = "Lantern", size = Vector3.new(1.1, 1.7, 1.1), cframe = base * CFrame.new(-3.6, 7.2, -13.1) * CFrame.Angles(tilt, 0, 0), mat = "neon", color = palette.lantern, collide = false, query = false },
	}

	local model = LandmarkKit.assemble("Shipwreck", parent, specs)
	pointLight(model:FindFirstChild("Lantern") :: BasePart, 24, 1.6, "WreckLight")
	return model
end

-- ================================== sea arch ================================
--: A rock arch standing on the seabed in water a few studs deep. Anchors are
--: the base centre; the service passes the seabed height in `at.Y`.
function LandmarkKit.seaArch(spec: any, parent: Instance?): Model
	local at = spec.at :: Vector3
	local base = frame(at, spec.yaw)
	local palette = LandmarkKit.palette

	local specs: { any } = {
		{ name = "FootA", size = Vector3.new(10, 5, 9), cframe = base * CFrame.new(-8.6, 2.4, 0) * CFrame.Angles(0, math.rad(6), math.rad(3)), mat = "stone", color = palette.rockDark, root = true },
		{ name = "LegA1", size = Vector3.new(8.2, 10, 7.6), cframe = base * CFrame.new(-8.4, 8.6, 0.3) * CFrame.Angles(0, math.rad(-8), math.rad(4)), mat = "stone", color = palette.rock },
		{ name = "LegA2", size = Vector3.new(6.8, 8.4, 6.4), cframe = base * CFrame.new(-7.8, 16.6, 0.8) * CFrame.Angles(0, math.rad(10), math.rad(-6)), mat = "stone", color = palette.rock },
		{ name = "LegA3", size = Vector3.new(5.6, 6.6, 5.4), cframe = base * CFrame.new(-7.2, 23.4, 1.2) * CFrame.Angles(0, math.rad(-5), math.rad(-9)), mat = "stone", color = palette.rockDark },
		{ name = "FootB", size = Vector3.new(9, 4.4, 8.2), cframe = base * CFrame.new(8.4, 2.1, 0.6) * CFrame.Angles(0, math.rad(-7), math.rad(-3)), mat = "stone", color = palette.rockDark },
		{ name = "LegB1", size = Vector3.new(7.6, 9, 7), cframe = base * CFrame.new(8.2, 8.2, 0.9) * CFrame.Angles(0, math.rad(8), math.rad(-5)), mat = "stone", color = palette.rock },
		{ name = "LegB2", size = Vector3.new(6.2, 7.6, 5.8), cframe = base * CFrame.new(7.6, 15.8, 1.4) * CFrame.Angles(0, math.rad(-9), math.rad(6)), mat = "stone", color = palette.rockDark },
		{ name = "LintelA", size = Vector3.new(10, 6, 6.6), cframe = base * CFrame.new(-3.4, 26.2, 0.6) * CFrame.Angles(0, math.rad(4), math.rad(-12)), mat = "stone", color = palette.rock },
		{ name = "LintelB", size = Vector3.new(9, 5.2, 6), cframe = base * CFrame.new(4.4, 27.2, 0.2) * CFrame.Angles(0, math.rad(-6), math.rad(9)), mat = "stone", color = palette.rockDark },
		{ name = "BoulderA", size = Vector3.new(5.4, 3.6, 4.6), cframe = base * CFrame.new(-14.6, 1.4, 1.8) * CFrame.Angles(0, math.rad(31), math.rad(4)), mat = "stone", color = palette.rock },
		{ name = "BoulderB", size = Vector3.new(4.4, 3, 3.8), cframe = base * CFrame.new(13.8, 1.2, -1.4) * CFrame.Angles(0, math.rad(-22), math.rad(-4)), mat = "stone", color = palette.rockDark },
		{ name = "AlgaeCrown", size = Vector3.new(6.4, 0.7, 5.4), cframe = base * CFrame.new(-3.4, 29.4, 0.6) * CFrame.Angles(0, math.rad(4), math.rad(-12)), mat = "grass", color = palette.algae, collide = false, query = false },
		{ name = "AlgaeFoot", size = Vector3.new(5.6, 0.6, 4.8), cframe = base * CFrame.new(14, 2.9, -1.4) * CFrame.Angles(0, math.rad(-22), 0), mat = "grass", color = palette.algae, collide = false, query = false },
	}

	return LandmarkKit.assemble("SeaArch", parent, specs)
end

-- ================================= cave mouth ===============================
--: Two flanking outcrops under a lintel, with a dark recess behind them. The
--: recess is a solid near-black part: it reads as depth from outside without
--: hollowing the hill or lighting a room nothing can reach.
function LandmarkKit.caveMouth(spec: any, parent: Instance?): Model
	local at = spec.at :: Vector3
	local base = frame(at, spec.yaw)
	local palette = LandmarkKit.palette

	local specs: { any } = {
		{ name = "OutcropL", size = Vector3.new(10, 14, 11), cframe = base * CFrame.new(-8, 6, 0) * CFrame.Angles(0, math.rad(7), math.rad(4)), mat = "rock", color = palette.rockDark, root = true },
		{ name = "OutcropR", size = Vector3.new(9, 12, 10), cframe = base * CFrame.new(7.6, 5.4, 1) * CFrame.Angles(0, math.rad(-9), math.rad(-5)), mat = "rock", color = palette.rockDark },
		{ name = "Lintel", size = Vector3.new(14.6, 5.2, 9), cframe = base * CFrame.new(0, 13.8, -0.4) * CFrame.Angles(math.rad(-4), 0, math.rad(3)), mat = "rock", color = palette.rock },
		{ name = "Recess", size = Vector3.new(11, 8, 6), cframe = base * CFrame.new(0, 3.4, -2.2), mat = "slate", color = palette.caveDark },
		{ name = "RubbleA", size = Vector3.new(3.4, 2.2, 2.8), cframe = base * CFrame.new(-12.6, 1, 3.4) * CFrame.Angles(0, math.rad(28), math.rad(6)), mat = "rock", color = palette.rock },
		{ name = "RubbleB", size = Vector3.new(2.6, 1.8, 2.2), cframe = base * CFrame.new(11.8, 0.8, 4.2) * CFrame.Angles(0, math.rad(-34), 0), mat = "rock", color = palette.rockDark },
		{ name = "GlowA1", size = Vector3.new(0.3, 3.4, 0.3), cframe = base * CFrame.new(-4.6, 2.6, 4.4) * CFrame.Angles(math.rad(4), 0, math.rad(8)), mat = "grass", color = palette.algae, collide = false, query = false },
		{ name = "GlowA2", size = Vector3.new(0.9, 0.9, 0.9), cframe = base * CFrame.new(-4.6, 4.5, 4.4), mat = "neon", color = palette.glow, collide = false, query = false },
		{ name = "GlowB1", size = Vector3.new(0.3, 2.8, 0.3), cframe = base * CFrame.new(4.9, 2.3, 4.6) * CFrame.Angles(math.rad(-3), 0, math.rad(-7)), mat = "grass", color = palette.algae, collide = false, query = false },
		{ name = "GlowB2", size = Vector3.new(0.9, 0.9, 0.9), cframe = base * CFrame.new(4.9, 3.9, 4.6), mat = "neon", color = palette.glow, collide = false, query = false },
		{ name = "MouthGlow", size = Vector3.new(6, 3.6, 0.8), cframe = base * CFrame.new(0, 2.8, -0.9), mat = "slate", color = Color3.fromRGB(58, 54, 62), transparency = 0.25, collide = false, query = false },
	}

	local model = LandmarkKit.assemble("CaveMouth", parent, specs)
	local glow = model:FindFirstChild("GlowA2") :: BasePart
	local light = pointLight(glow, 22, 1.4, "CaveGlow")
	light.Color = Color3.fromRGB(255, 196, 128)
	return model
end

-- ================================ watchtower ================================
--: A ruined tower: two columns still full height, two broken at different
--: heights, a standable platform and parapet, and a brazier. The platform
--: is the one part a player is meant to stand on, so it collides.
function LandmarkKit.watchtower(spec: any, parent: Instance?): Model
	local at = spec.at :: Vector3
	local base = frame(at, spec.yaw)
	local palette = LandmarkKit.palette
	local stone = BuildKit.palette.stone

	local specs: { any } = {
		{ name = "Plinth", size = Vector3.new(13, 2, 13), cframe = base * CFrame.new(0, 1, 0), mat = "stone", color = palette.rockDark },
		{ name = "ColumnA", size = Vector3.new(2.4, 24, 2.4), cframe = base * CFrame.new(-4.7, 14, -4.7), mat = "stone", color = stone },
		{ name = "ColumnB", size = Vector3.new(2.4, 24, 2.4), cframe = base * CFrame.new(4.7, 14, -4.3) * CFrame.Angles(0, math.rad(2), math.rad(-1.5)), mat = "stone", color = stone },
		{ name = "ColumnC", size = Vector3.new(2.4, 16, 2.4), cframe = base * CFrame.new(-4.4, 10, 4.8) * CFrame.Angles(math.rad(2.5), 0, math.rad(2)), mat = "stone", color = palette.rock },
		{ name = "ColumnD", size = Vector3.new(2.4, 11, 2.4), cframe = base * CFrame.new(4.8, 7.5, 4.5) * CFrame.Angles(math.rad(-4), 0, math.rad(-3)), mat = "stone", color = palette.rock },
		{ name = "RingLow", size = Vector3.new(12.6, 1.1, 12.6), cframe = base * CFrame.new(0, 9.5, 0), mat = "stone", color = palette.rockDark },
		{ name = "RingHigh", size = Vector3.new(11.4, 1.1, 11.4), cframe = base * CFrame.new(0, 18, 0), mat = "stone", color = stone },
		{ name = "Platform", size = Vector3.new(11.6, 1.2, 11.6), cframe = base * CFrame.new(0, 25.6, 0), mat = "stone", color = palette.rockDark, root = true },
		{ name = "ParapetN", size = Vector3.new(11.6, 2.2, 0.8), cframe = base * CFrame.new(0, 27.3, -5.4), mat = "stone", color = stone },
		{ name = "ParapetW", size = Vector3.new(0.8, 2.2, 9.6), cframe = base * CFrame.new(-5.4, 27.3, 0), mat = "stone", color = palette.rock },
		{ name = "ParapetE", size = Vector3.new(0.8, 2.2, 9.6), cframe = base * CFrame.new(5.4, 27.3, 0), mat = "stone", color = palette.rock },
		{ name = "ParapetSLeft", size = Vector3.new(4.4, 2.2, 0.8), cframe = base * CFrame.new(-3.4, 27.3, 5.4), mat = "stone", color = palette.rockDark },
		{ name = "ParapetSRight", size = Vector3.new(2.4, 1.6, 0.8), cframe = base * CFrame.new(3.9, 27, 5.4) * CFrame.Angles(0, 0, math.rad(-6)), mat = "stone", color = palette.rockDark },
		{ name = "FallenBeam", size = Vector3.new(13, 1.1, 1.1), cframe = base * CFrame.new(6.4, 5.4, 4.4) * CFrame.Angles(0, math.rad(28), math.rad(44)), mat = "wood", color = BuildKit.palette.woodDark, collide = false },
		{ name = "RubbleA", size = Vector3.new(3.6, 2.4, 3), cframe = base * CFrame.new(-8.4, 1.1, 2.6) * CFrame.Angles(0, math.rad(18), math.rad(5)), mat = "stone", color = stone },
		{ name = "RubbleB", size = Vector3.new(2.8, 2, 2.4), cframe = base * CFrame.new(8.8, 0.9, -3.4) * CFrame.Angles(0, math.rad(-42), 0), mat = "stone", color = palette.rockDark },
		{ name = "RubbleC", size = Vector3.new(2.2, 1.6, 2), cframe = base * CFrame.new(2.2, 0.7, -8.4) * CFrame.Angles(0, math.rad(64), math.rad(-4)), mat = "stone", color = palette.rock },
		{ name = "BrazierPost", size = Vector3.new(1.2, 3, 1.2), cframe = base * CFrame.new(2.8, 27.8, -2.6), mat = "metal", color = BuildKit.palette.metal },
		{ name = "BrazierBowl", size = Vector3.new(2.8, 1, 2.8), cframe = base * CFrame.new(2.8, 29.4, -2.6), mat = "metal", color = BuildKit.palette.woodDark },
		{ name = "BrazierFire", size = Vector3.new(1.8, 1.4, 1.8), cframe = base * CFrame.new(2.8, 30.3, -2.6), mat = "neon", color = palette.flame, collide = false, query = false },
	}

	local model = LandmarkKit.assemble("Watchtower", parent, specs)
	pointLight(model:FindFirstChild("BrazierFire") :: BasePart, 34, 1.8, "BrazierLight")
	return model
end

-- ================================== campfire ================================
--: A fire pit that is genuinely warm: a stone ring, crossed logs, a neon core
--: and one particle emitter standing in for the flames.
function LandmarkKit.campfire(spec: any, parent: Instance?): Model
	local at = spec.at :: Vector3
	local base = frame(at, spec.yaw)
	local palette = LandmarkKit.palette

	local specs: { any } = {}
	for step = 0, 5 do
		local angle = step * math.pi / 3 + 0.35
		table.insert(specs, {
			name = "PitStone" .. step,
			size = Vector3.new(2.4, 1.3, 1.9),
			cframe = base * CFrame.new(math.cos(angle) * 3.5, 0.55, math.sin(angle) * 3.5) * CFrame.Angles(0, angle, 0),
			mat = "stone",
			color = if step % 2 == 0 then palette.rockDark else palette.rock,
			root = step == 0,
		})
	end
	table.insert(specs, { name = "Ash", size = Vector3.new(5, 0.4, 5), cframe = base * CFrame.new(0, 0.3, 0), mat = "slate", color = palette.ash, collide = false })
	table.insert(specs, { name = "LogA", size = Vector3.new(0.7, 0.7, 5.4), cframe = base * CFrame.new(0, 1, 0) * CFrame.Angles(0, 0, 0), mat = "wood", color = palette.hullDark })
	table.insert(specs, { name = "LogB", size = Vector3.new(0.7, 0.7, 5.4), cframe = base * CFrame.new(0, 1.2, 0) * CFrame.Angles(0, math.rad(62), 0), mat = "wood", color = palette.hullDark })
	table.insert(specs, { name = "LogC", size = Vector3.new(0.7, 0.7, 5), cframe = base * CFrame.new(0, 1.4, 0) * CFrame.Angles(0, math.rad(-58), 0), mat = "wood", color = palette.hull })
	table.insert(specs, { name = "Embers", size = Vector3.new(2.6, 0.5, 2.6), cframe = base * CFrame.new(0, 1.6, 0), mat = "neon", color = palette.flame, collide = false, query = false, shadow = false })
	table.insert(specs, { name = "Flame", size = Vector3.new(1.5, 2.6, 1.5), cframe = base * CFrame.new(0, 2.8, 0) * CFrame.Angles(math.rad(6), 0, math.rad(7)), mat = "neon", color = palette.flame, transparency = 0.3, collide = false, query = false, shadow = false })

	local model = LandmarkKit.assemble("Campfire", parent, specs)
	local embers = model:FindFirstChild("Embers") :: BasePart
	local light = pointLight(embers, 30, 2.4, "FireLight")
	light.Color = Color3.fromRGB(255, 170, 92)

	local flames = Instance.new("ParticleEmitter")
	flames.Name = "Flames"
	flames.Color = ColorSequence.new(Color3.fromRGB(255, 216, 108), Color3.fromRGB(226, 98, 42))
	flames.LightEmission = 1
	flames.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.9),
		NumberSequenceKeypoint.new(1, 0.4),
	})
	flames.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	flames.Lifetime = NumberRange.new(0.5, 1.0)
	flames.Rate = 16
	flames.Speed = NumberRange.new(3.5, 6)
	flames.SpreadAngle = Vector2.new(12, 12)
	flames.Acceleration = Vector3.new(0, 7, 0)
	flames.Rotation = NumberRange.new(0, 360)
	flames.RotSpeed = NumberRange.new(-120, 120)
	flames.Parent = model:FindFirstChild("Flame") :: BasePart

	return model
end

-- =================================== shrine =================================
--: The per-zone vignette: one small formation quoting that water's motif and
--: buoys' colour. `spec.flavor` is a zone id.
function LandmarkKit.shrine(spec: any, parent: Instance?): Model
	local at = spec.at :: Vector3
	local base = frame(at, spec.yaw)
	local palette = LandmarkKit.palette
	local wood = BuildKit.palette
	local flavor = LandmarkKit.zoneFlavour[spec.flavor] or LandmarkKit.zoneFlavour.shallows
	local accent = flavor.color

	local specs: { any } = {
		{ name = "Base", size = Vector3.new(5.6, 1, 5.6), cframe = base * CFrame.new(0, 0.5, 0), mat = "stone", color = BuildKit.palette.stoneDark, root = true },
	}

	if flavor.motif == "kelp" then
		specs[#specs + 1] = { name = "Post", size = Vector3.new(0.7, 6, 0.7), cframe = base * CFrame.new(0, 3.5, 0), mat = "wood", color = wood.woodDark }
		specs[#specs + 1] = { name = "StrandA", size = Vector3.new(0.35, 4.6, 0.9), cframe = base * CFrame.new(-0.8, 3.4, 0.2) * CFrame.Angles(0, 0, math.rad(9)), mat = "grass", color = palette.kelp, collide = false, query = false }
		specs[#specs + 1] = { name = "StrandB", size = Vector3.new(0.35, 3.8, 0.8), cframe = base * CFrame.new(0.9, 3.7, -0.2) * CFrame.Angles(0, 0, math.rad(-8)), mat = "grass", color = palette.kelpDeep, collide = false, query = false }
		specs[#specs + 1] = { name = "Sigil", size = Vector3.new(1.1, 1.1, 1.1), cframe = base * CFrame.new(0, 7, 0), mat = "neon", color = accent, collide = false, query = false }
	elseif flavor.motif == "coral" then
		specs[#specs + 1] = { name = "StackA", size = Vector3.new(3.4, 2.2, 3.4), cframe = base * CFrame.new(-0.6, 2.1, 0.4) * CFrame.Angles(0, math.rad(14), 0), mat = "slate", color = Color3.fromRGB(214, 138, 158) }
		specs[#specs + 1] = { name = "StackB", size = Vector3.new(2.6, 2, 2.6), cframe = base * CFrame.new(0.4, 4.1, -0.3) * CFrame.Angles(0, math.rad(-18), 0), mat = "slate", color = Color3.fromRGB(230, 160, 176) }
		specs[#specs + 1] = { name = "StackC", size = Vector3.new(1.8, 1.6, 1.8), cframe = base * CFrame.new(-0.1, 5.8, 0.2) * CFrame.Angles(0, math.rad(30), 0), mat = "slate", color = Color3.fromRGB(198, 116, 140) }
		specs[#specs + 1] = { name = "Sigil", size = Vector3.new(1, 1, 1), cframe = base * CFrame.new(-0.1, 7.1, 0.2), mat = "neon", color = accent, collide = false, query = false }
	elseif flavor.motif == "splinter" then
		specs[#specs + 1] = { name = "Splinter", size = Vector3.new(0.9, 7.5, 0.9), cframe = base * CFrame.new(0.4, 4.2, 0) * CFrame.Angles(math.rad(9), 0, math.rad(-14)), mat = "wood", color = wood.woodDark }
		specs[#specs + 1] = { name = "Brace", size = Vector3.new(0.6, 4.4, 0.6), cframe = base * CFrame.new(-1.4, 3, 0.6) * CFrame.Angles(0, 0, math.rad(38)), mat = "wood", color = palette.hullDark, collide = false }
		specs[#specs + 1] = { name = "DebrisA", size = Vector3.new(1.8, 0.5, 0.8), cframe = base * CFrame.new(1.9, 0.9, -1.2) * CFrame.Angles(0, math.rad(40), 0), mat = "wood", color = palette.hull, collide = false }
		specs[#specs + 1] = { name = "Sigil", size = Vector3.new(1, 1.5, 1), cframe = base * CFrame.new(0.5, 8.2, 0), mat = "neon", color = accent, collide = false, query = false }
	elseif flavor.motif == "cairn" then
		specs[#specs + 1] = { name = "CairnA", size = Vector3.new(3.8, 2.4, 3.4), cframe = base * CFrame.new(0, 2.2, 0) * CFrame.Angles(0, math.rad(22), 0), mat = "slate", color = palette.rockDark }
		specs[#specs + 1] = { name = "CairnB", size = Vector3.new(2.8, 2.2, 2.6), cframe = base * CFrame.new(0.2, 4.3, 0.1) * CFrame.Angles(0, math.rad(-34), math.rad(3)), mat = "slate", color = palette.rock }
		specs[#specs + 1] = { name = "CairnC", size = Vector3.new(1.9, 1.8, 1.8), cframe = base * CFrame.new(-0.2, 6.1, -0.1) * CFrame.Angles(0, math.rad(48), 0), mat = "slate", color = palette.rockDark }
		specs[#specs + 1] = { name = "Sigil", size = Vector3.new(0.9, 1.4, 0.9), cframe = base * CFrame.new(-0.2, 7.6, -0.1) * CFrame.Angles(math.rad(6), 0, math.rad(-5)), mat = "neon", color = accent, collide = false, query = false }
	else
		specs[#specs + 1] = { name = "Totem", size = Vector3.new(1, 6.4, 1), cframe = base * CFrame.new(0, 3.7, 0) * CFrame.Angles(math.rad(3), 0, math.rad(-4)), mat = "wood", color = wood.woodLight }
		specs[#specs + 1] = { name = "Crossbar", size = Vector3.new(3.6, 0.6, 0.7), cframe = base * CFrame.new(0, 5.4, 0.1) * CFrame.Angles(0, math.rad(14), math.rad(-3)), mat = "wood", color = wood.woodDark, collide = false }
		specs[#specs + 1] = { name = "Shell", size = Vector3.new(1.6, 0.7, 1.6), cframe = base * CFrame.new(0, 7.2, 0) * CFrame.Angles(0, math.rad(20), 0), mat = "neon", color = accent, collide = false, query = false }
	end

	local model = LandmarkKit.assemble("Shrine", parent, specs)
	local sigil = model:FindFirstChild("Sigil") or model:FindFirstChild("Shell")
	pointLight(sigil :: BasePart, 20, 1.4, "ShrineLight")
	return model
end

-- ============================ underwater dressing ===========================
--: Reef kelp: the stalk stands, the frond leans into whatever current the
--: seed chose. No physics — CanCollide and CanQuery off, so a boat and a
--: raycast both ignore it.
function LandmarkKit.kelpStrand(spec: any, parent: Instance?): Model
	local at = spec.at :: Vector3
	local scale = spec.scale or 1
	local base = frame(at, spec.yaw)
	local palette = LandmarkKit.palette
	local height = 15 * scale

	local specs: { any } = {
		{ name = "Stalk", size = Vector3.new(height, 0.8 * scale, 0.8 * scale),
			cframe = base * CFrame.new(0, height / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
			mat = "grass", color = palette.kelp, collide = false, query = false, shadow = false, root = true },
		{ name = "Frond", size = Vector3.new(0.3 * scale, 4 * scale, 1.3 * scale),
			cframe = base * CFrame.new(0.7 * scale, height - 1.6 * scale, 0) * CFrame.Angles(0, 0, math.rad(-24)),
			mat = "grass", color = palette.kelpDeep, collide = false, query = false, shadow = false },
	}
	return LandmarkKit.assemble("Kelp", parent, specs)
end

--: A rock cluster on the reef floor: one big rounded block, one smaller one
--: riding it. No physics.
function LandmarkKit.reefRock(spec: any, parent: Instance?): Model
	local at = spec.at :: Vector3
	local scale = spec.scale or 1
	local base = frame(at, spec.yaw)
	local palette = LandmarkKit.palette

	local specs: { any } = {
		{ name = "RockA", size = Vector3.new(5 * scale, 3.4 * scale, 4.4 * scale),
			cframe = base * CFrame.new(0, 1.2 * scale, 0) * CFrame.Angles(0, spec.yaw, math.rad(6)),
			mat = "stone", color = palette.rock, collide = false, query = false, shadow = false, root = true },
		{ name = "RockB", size = Vector3.new(2.8 * scale, 2 * scale, 2.4 * scale),
			cframe = base * CFrame.new(1.6 * scale, 3 * scale, -0.8 * scale) * CFrame.Angles(0, spec.yaw * 2, math.rad(-8)),
			mat = "stone", color = palette.rockDark, collide = false, query = false, shadow = false },
	}
	return LandmarkKit.assemble("ReefRock", parent, specs)
end

--: A glow plant: a thin stem with a neon bulb, the only light on the reef
--: floor. Deliberately lightless — neon reads underwater and a PointLight per
--: plant is how a reef becomes a lamp shop.
function LandmarkKit.glowPlant(spec: any, parent: Instance?): Model
	local at = spec.at :: Vector3
	local scale = spec.scale or 1
	local base = frame(at, spec.yaw)
	local palette = LandmarkKit.palette
	local height = 5 * scale

	local specs: { any } = {
		{ name = "Stem", size = Vector3.new(height, 0.3 * scale, 0.3 * scale),
			cframe = base * CFrame.new(0, height / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
			mat = "grass", color = palette.kelpDeep, collide = false, query = false, shadow = false, root = true },
		{ name = "Bulb", size = Vector3.new(1.5 * scale, 1.9 * scale, 1.5 * scale),
			cframe = base * CFrame.new(0, height + 0.5 * scale, 0),
			mat = "neon", color = spec.glow or palette.glow, collide = false, query = false, shadow = false },
	}
	local model = LandmarkKit.assemble("GlowPlant", parent, specs)
	local bulb = model:FindFirstChild("Bulb") :: BasePart
	bulb.Shape = Enum.PartType.Ball
	return model
end

-- ================================== dispatch ================================
local BUILDERS: { [string]: (any, Instance?) -> Model } = {
	lighthouse = LandmarkKit.lighthouse,
	fishingShack = LandmarkKit.fishingShack,
	shipwreck = LandmarkKit.shipwreck,
	seaArch = LandmarkKit.seaArch,
	caveMouth = LandmarkKit.caveMouth,
	watchtower = LandmarkKit.watchtower,
	campfire = LandmarkKit.campfire,
	shrine = LandmarkKit.shrine,
	kelpStrand = LandmarkKit.kelpStrand,
	reefRock = LandmarkKit.reefRock,
	glowPlant = LandmarkKit.glowPlant,
}

--: The one door the service uses. An unknown kind names what exists, because
--: "attempt to call a nil value" does not.
function LandmarkKit.build(spec: any, parent: Instance?): Model
	local builder = BUILDERS[spec.kind]
	if not builder then
		local names = {}
		for name in BUILDERS do
			table.insert(names, name)
		end
		table.sort(names)
		error(string.format("[LandmarkKit] no builder named '%s'; have: %s",
			tostring(spec.kind), table.concat(names, ", ")), 2)
	end
	return builder(spec, parent)
end

return LandmarkKit
