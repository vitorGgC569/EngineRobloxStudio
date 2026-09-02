--!strict
-- Procedural map-building kit. Maps are plain Luau (Rojo-managed, diffable) that
-- assemble anchored parts into a Model with the contract MapService expects:
--   <Map Model>
--     Geometry/        all visible parts
--     SurvivorSpawns/  invisible parts marking survivor spawn points
--     ZombieSpawns/    invisible parts marking zombie respawn points

local Kit = {}

export type MapModel = Model

function Kit.newMap(name: string): (Model, Folder, Folder, Folder, Folder)
	local model = Instance.new("Model")
	model.Name = name
	local geometry = Instance.new("Folder")
	geometry.Name = "Geometry"
	geometry.Parent = model
	local survivorSpawns = Instance.new("Folder")
	survivorSpawns.Name = "SurvivorSpawns"
	survivorSpawns.Parent = model
	local zombieSpawns = Instance.new("Folder")
	zombieSpawns.Name = "ZombieSpawns"
	zombieSpawns.Parent = model
	local patrolPoints = Instance.new("Folder")
	patrolPoints.Name = "PatrolPoints"
	patrolPoints.Parent = model
	return model, geometry, survivorSpawns, zombieSpawns, patrolPoints
end

function Kit.part(
	parent: Instance,
	size: Vector3,
	cframe: CFrame,
	props: { Color: Color3?, Material: Enum.Material?, Transparency: number?, Name: string? }?
): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if props then
		if props.Color then
			part.Color = props.Color
		end
		if props.Material then
			part.Material = props.Material
		end
		if props.Transparency then
			part.Transparency = props.Transparency
		end
		if props.Name then
			part.Name = props.Name
		end
	end
	part.Parent = parent
	return part
end

-- Axis-aligned box position helper: pos is the CENTER of the floor footprint.
function Kit.at(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, z)
end

-- Floor slab centered at (x,z), top surface at y.
function Kit.floor(parent: Instance, x: number, z: number, w: number, d: number, y: number, props: any?): Part
	return Kit.part(parent, Vector3.new(w, 1, d), CFrame.new(x, y - 0.5, z), props)
end

-- Wall along X axis (facing Z): centered at (x, z), width w, height h, base at y.
function Kit.wallX(parent: Instance, x: number, z: number, w: number, h: number, y: number, props: any?): Part
	return Kit.part(parent, Vector3.new(w, h, 1), CFrame.new(x, y + h / 2, z), props)
end

-- Wall along Z axis (facing X).
function Kit.wallZ(parent: Instance, x: number, z: number, d: number, h: number, y: number, props: any?): Part
	return Kit.part(parent, Vector3.new(1, h, d), CFrame.new(x, y + h / 2, z), props)
end

-- Wall along X with a centered doorway gap (two segments + lintel).
function Kit.wallXDoor(
	parent: Instance,
	x: number,
	z: number,
	w: number,
	h: number,
	y: number,
	doorW: number,
	props: any?
)
	local segW = (w - doorW) / 2
	if segW > 0.5 then
		Kit.wallX(parent, x - (doorW + segW) / 2, z, segW, h, y, props)
		Kit.wallX(parent, x + (doorW + segW) / 2, z, segW, h, y, props)
	end
	local lintelH = h - 7
	if lintelH > 0.5 then
		Kit.part(parent, Vector3.new(doorW, lintelH, 1), CFrame.new(x, y + 7 + lintelH / 2, z), props)
	end
end

-- Wall along Z with a centered doorway gap.
function Kit.wallZDoor(
	parent: Instance,
	x: number,
	z: number,
	d: number,
	h: number,
	y: number,
	doorW: number,
	props: any?
)
	local segD = (d - doorW) / 2
	if segD > 0.5 then
		Kit.wallZ(parent, x, z - (doorW + segD) / 2, segD, h, y, props)
		Kit.wallZ(parent, x, z + (doorW + segD) / 2, segD, h, y, props)
	end
	local lintelH = h - 7
	if lintelH > 0.5 then
		Kit.part(parent, Vector3.new(1, lintelH, doorW), CFrame.new(x, y + 7 + lintelH / 2, z), props)
	end
end

-- Ramp from (x,z) floor y0 up to y1, running along +Z.
function Kit.ramp(
	parent: Instance,
	x: number,
	z: number,
	w: number,
	y0: number,
	y1: number,
	length: number,
	props: any?
): Part
	local rise = y1 - y0
	local slope = math.sqrt(rise * rise + length * length)
	local angle = math.atan2(rise, length)
	local part = Kit.part(
		parent,
		Vector3.new(w, 1, slope),
		CFrame.new(x, (y0 + y1) / 2, z) * CFrame.Angles(-angle, 0, 0),
		props
	)
	return part
end

-- Simple box prop (crate, counter, planter...)
function Kit.box(
	parent: Instance,
	x: number,
	y: number,
	z: number,
	sx: number,
	sy: number,
	sz: number,
	props: any?
): Part
	return Kit.part(parent, Vector3.new(sx, sy, sz), CFrame.new(x, y + sy / 2, z), props)
end

-- Real stepped stairs. Humanoids climb these natively and PathfindingService handles them;
-- a single sloped slab (Kit.ramp) reads as a placeholder, and the game had no stairs at all.
-- `facing` is "+Z" | "-Z" | "+X" | "-X" — the direction you walk while going UP.
function Kit.stairs(
	parent: Instance,
	x: number,
	z: number,
	width: number,
	y0: number,
	y1: number,
	run: number,
	facing: string,
	props: any?
)
	local rise = y1 - y0
	if rise <= 0 or run <= 0 then
		return
	end
	local steps = math.max(1, math.floor(rise / 1.2))
	local stepRise = rise / steps
	local stepRun = run / steps
	local alongX = facing == "+X" or facing == "-X"
	local sign = (facing == "-Z" or facing == "-X") and -1 or 1

	for i = 1, steps do
		local top = y0 + stepRise * i
		-- Each tread is a solid block from the ground up, so there is no gap to fall through.
		local height = top - y0 + 1
		local offset = (i - 0.5) * stepRun * sign
		local size = if alongX
			then Vector3.new(stepRun, height, width)
			else Vector3.new(width, height, stepRun)
		local centre = if alongX
			then CFrame.new(x + offset, top - height / 2, z)
			else CFrame.new(x, top - height / 2, z + offset)
		Kit.part(parent, size, centre, props)
	end
end

-- Waist-high railing along a run, so balconies read as balconies.
function Kit.railing(
	parent: Instance,
	x: number,
	z: number,
	length: number,
	y: number,
	alongX: boolean,
	props: any?
)
	local size = if alongX then Vector3.new(length, 0.3, 0.3) else Vector3.new(0.3, 0.3, length)
	Kit.part(parent, size, CFrame.new(x, y + 3.2, z), props)
	local posts = math.max(2, math.floor(length / 8))
	for i = 0, posts do
		local t = (i / posts - 0.5) * length
		local px = if alongX then x + t else x
		local pz = if alongX then z else z + t
		Kit.part(parent, Vector3.new(0.3, 3.2, 0.3), CFrame.new(px, y + 1.6, pz), props)
	end
end

-- Elevated walkway with railings on both sides.
function Kit.catwalk(
	parent: Instance,
	x: number,
	z: number,
	w: number,
	d: number,
	y: number,
	props: any?,
	railProps: any?
)
	Kit.floor(parent, x, z, w, d, y, props)
	local alongX = w >= d
	if alongX then
		Kit.railing(parent, x, z - d / 2, w, y, true, railProps or props)
		Kit.railing(parent, x, z + d / 2, w, y, true, railProps or props)
	else
		Kit.railing(parent, x - w / 2, z, d, y, false, railProps or props)
		Kit.railing(parent, x + w / 2, z, d, y, false, railProps or props)
	end
end

-- Climbable ladder. TrussPart is first-party and Humanoids climb it with no extra code.
function Kit.ladder(parent: Instance, x: number, z: number, y0: number, y1: number, props: any?)
	local height = y1 - y0
	if height <= 0 then
		return
	end
	local truss = Instance.new("TrussPart")
	truss.Anchored = true
	truss.Size = Vector3.new(2, height, 2)
	truss.CFrame = CFrame.new(x, y0 + height / 2, z)
	if props and props.Color then
		truss.Color = props.Color
	end
	truss.Parent = parent
	return truss
end

-- Non-collidable glass pane, so buildings read as having windows instead of gaps.
function Kit.window(
	parent: Instance,
	x: number,
	z: number,
	w: number,
	h: number,
	y: number,
	alongX: boolean,
	props: any?
)
	local size = if alongX then Vector3.new(w, h, 0.3) else Vector3.new(0.3, h, w)
	local pane = Kit.part(parent, size, CFrame.new(x, y + h / 2, z), props)
	pane.Transparency = 0.65
	pane.Material = Enum.Material.Glass
	pane.CanCollide = true
	pane.Reflectance = 0.15
	return pane
end

-- Landmark signage. A SurfaceGui with text needs no image asset and gives every space a
-- name, which is what actually makes a map navigable and memorable.
function Kit.sign(
	parent: Instance,
	x: number,
	y: number,
	z: number,
	text: string,
	face: Enum.NormalId,
	color: Color3?,
	width: number?
)
	local w = width or 16
	local board = Kit.part(parent, Vector3.new(w, 4, 0.4), CFrame.new(x, y, z), {
		Color = Color3.fromRGB(28, 28, 32),
		Material = Enum.Material.SmoothPlastic,
		Name = "Sign",
	})
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.CanvasSize = Vector2.new(400, 100)
	gui.LightInfluence = 0
	gui.Parent = board
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = color or Color3.fromRGB(255, 210, 120)
	label.Parent = gui
	return board
end

-- Emissive strip light: a neon bar plus the light it implies.
function Kit.neonStrip(
	parent: Instance,
	x: number,
	y: number,
	z: number,
	w: number,
	d: number,
	color: Color3,
	brightness: number?
)
	local strip = Kit.part(parent, Vector3.new(w, 0.4, d), CFrame.new(x, y, z), {
		Color = color,
		Material = Enum.Material.Neon,
		Name = "Strip",
	})
	strip.CanCollide = false
	Kit.pointLight(strip, brightness or 2, math.max(w, d) * 1.6, color)
	return strip
end

-- Cylindrical column / pipe / barrel.
function Kit.cylinder(
	parent: Instance,
	x: number,
	y: number,
	z: number,
	diameter: number,
	height: number,
	props: any?
)
	local part = Kit.part(
		parent,
		Vector3.new(height, diameter, diameter),
		CFrame.new(x, y + height / 2, z) * CFrame.Angles(0, 0, math.rad(90)),
		props
	)
	part.Shape = Enum.PartType.Cylinder
	return part
end

-- Wedge, for pitched roofs and angled cover — the whole game was axis-aligned boxes.
function Kit.wedge(parent: Instance, size: Vector3, cframe: CFrame, props: any?): WedgePart
	local wedge = Instance.new("WedgePart")
	wedge.Anchored = true
	wedge.Size = size
	wedge.CFrame = cframe
	if props then
		if props.Color then
			wedge.Color = props.Color
		end
		if props.Material then
			wedge.Material = props.Material
		end
	end
	wedge.Parent = parent
	return wedge
end

-- Pitched roof built from two opposing wedges.
function Kit.pitchedRoof(
	parent: Instance,
	x: number,
	z: number,
	w: number,
	d: number,
	y: number,
	height: number,
	props: any?
)
	local half = d / 2
	Kit.wedge(parent, Vector3.new(w, height, half), CFrame.new(x, y + height / 2, z - half / 2), props)
	Kit.wedge(
		parent,
		Vector3.new(w, height, half),
		CFrame.new(x, y + height / 2, z + half / 2) * CFrame.Angles(0, math.pi, 0),
		props
	)
end

-- Patrol waypoint for bots. Mirrors spawnMarker but lives in its own folder so bots explore
-- the map instead of ping-ponging between spawn points.
function Kit.patrolMarker(parent: Instance, x: number, y: number, z: number)
	local marker = Instance.new("Part")
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.Transparency = 1
	marker.Size = Vector3.new(2, 1, 2)
	marker.CFrame = CFrame.new(x, y + 3, z)
	marker.Name = "Patrol"
	marker.Parent = parent
end

function Kit.spawnMarker(parent: Instance, x: number, y: number, z: number)
	local marker = Instance.new("Part")
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.Transparency = 1
	marker.Size = Vector3.new(2, 1, 2)
	marker.CFrame = CFrame.new(x, y + 3, z)
	marker.Name = "Spawn"
	marker.Parent = parent
end

function Kit.pointLight(parent: Part, brightness: number, range: number, color: Color3?)
	local light = Instance.new("PointLight")
	light.Brightness = brightness
	light.Range = range
	if color then
		light.Color = color
	end
	light.Parent = parent
end

-- Shared baseline palette. Kept for compatibility; prefer Kit.Palettes so each map has its
-- own identity — every map drawing from one 10-colour list is a large part of why they all
-- looked the same.
Kit.Colors = {
	Concrete = Color3.fromRGB(160, 158, 152),
	DarkFloor = Color3.fromRGB(90, 88, 86),
	Brick = Color3.fromRGB(138, 90, 66),
	Roof = Color3.fromRGB(70, 66, 64),
	Glass = Color3.fromRGB(150, 200, 220),
	Metal = Color3.fromRGB(120, 124, 130),
	Grass = Color3.fromRGB(96, 140, 72),
	Road = Color3.fromRGB(52, 52, 56),
	Accent = Color3.fromRGB(200, 60, 60),
	LabWhite = Color3.fromRGB(222, 224, 226),
}

-- Per-map palettes. Suburbia is warm domestic brick and painted siding under a cold night;
-- the Mall is warm amber retail with teal accents; the Facility is cold clinical white.
Kit.Palettes = {
	Suburbia = {
		Concrete = Color3.fromRGB(168, 164, 156),
		DarkFloor = Color3.fromRGB(96, 92, 88),
		Brick = Color3.fromRGB(146, 88, 68),
		SidingA = Color3.fromRGB(206, 198, 180),
		SidingB = Color3.fromRGB(150, 168, 172),
		SidingC = Color3.fromRGB(188, 172, 140),
		Roof = Color3.fromRGB(74, 62, 58),
		RoofAlt = Color3.fromRGB(92, 74, 62),
		Glass = Color3.fromRGB(160, 200, 218),
		Metal = Color3.fromRGB(126, 130, 136),
		Grass = Color3.fromRGB(84, 128, 66),
		Road = Color3.fromRGB(48, 48, 52),
		Wood = Color3.fromRGB(134, 100, 68),
		Accent = Color3.fromRGB(214, 78, 62),
		Light = Color3.fromRGB(255, 214, 150),
	},
	Mall = {
		Concrete = Color3.fromRGB(198, 190, 178),
		DarkFloor = Color3.fromRGB(110, 104, 100),
		Tile = Color3.fromRGB(226, 220, 208),
		TileAlt = Color3.fromRGB(196, 186, 172),
		Brick = Color3.fromRGB(150, 106, 82),
		Roof = Color3.fromRGB(84, 80, 78),
		Glass = Color3.fromRGB(178, 214, 226),
		Metal = Color3.fromRGB(148, 150, 156),
		Storefront = Color3.fromRGB(212, 156, 96),
		Teal = Color3.fromRGB(72, 156, 156),
		Accent = Color3.fromRGB(226, 92, 84),
		Light = Color3.fromRGB(255, 226, 178),
	},
	Facility = {
		Concrete = Color3.fromRGB(176, 178, 182),
		DarkFloor = Color3.fromRGB(84, 88, 94),
		LabWhite = Color3.fromRGB(228, 232, 236),
		Panel = Color3.fromRGB(198, 204, 210),
		Glass = Color3.fromRGB(186, 220, 232),
		Metal = Color3.fromRGB(138, 144, 152),
		Hazard = Color3.fromRGB(216, 176, 60),
		Accent = Color3.fromRGB(74, 190, 210),
		Danger = Color3.fromRGB(212, 64, 58),
		Light = Color3.fromRGB(214, 242, 255),
	},
}

return Kit
