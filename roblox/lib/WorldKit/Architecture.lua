--!strict
-- L4: architecture.
--
-- The gap this closes was measured rather than guessed. A capture of a generated
-- world scored 22/100 on environment density, with 90% of the frame a single
-- unbroken plane -- and the cause was not lighting. It was that the only things
-- in the world were slabs: ground, a path, three boxes stacked into a
-- "landmark", and scattered trees. Every one of those is a Part with a colour.
--
-- What a scene needs to stop reading as a test map, in the order it matters:
--
-- **Something must occlude the horizon.** A flat plane meeting empty sky is the
-- greybox signature, and no amount of props on the ground removes it. Perimeter
-- walls, cliffs and tall structures are what turn an expanse into a place.
--
-- **Vertical variation.** Ground at one elevation reads as a floor plan seen in
-- perspective. Terraces, steps and raised platforms give the eye something to
-- travel.
--
-- **Silhouettes made of more than one box.** A building is a base, a body, a
-- roof, an eave, openings and trim. Six parts instead of one is the difference
-- between architecture and a crate.
--
-- Everything here is built from the token grammar -- `buildingMinHeight`,
-- `doorWidth`, `ceilingHeight`, `landmarkMinHeight` -- and the palette roles. A
-- module that chose its own proportions would produce buildings that look
-- consistent with each other and wrong beside everything else the game ships,
-- and doors a character cannot walk through.

local Tokens = require(script.Parent.Tokens)

local Architecture = {}

export type Style = {
	--- Palette roles for the parts of a structure. Named by function rather than
	--- by colour, so a nocturnal kit and a desert one differ in tokens and not in
	--- this file.
	wall: string,
	trim: string,
	roof: string,
	accent: string,
	--- Material for the main mass. Openings and trim derive from it.
	material: Enum.Material?,
}

export type BuildingSpec = {
	position: Vector3,
	footprint: Vector2,
	floors: number?,
	rotation: number?,
	style: Style,
	--- Which side the entrance faces, in degrees. A door on the far side of a
	--- building from the path is a door nobody finds.
	facing: number?,
	seed: number?,
}

local function fail(message: string): never
	error("[WorldKit.Architecture] " .. message, 0)
end

local function part(parent: Instance, name: string, size: Vector3, cframe: CFrame,
	colour: Color3, material: Enum.Material): Part
	local instance = Instance.new("Part")
	instance.Name = name
	instance.Anchored = true
	instance.Size = size
	instance.CFrame = cframe
	instance.Color = colour
	instance.Material = material
	instance.TopSurface = Enum.SurfaceType.Smooth
	instance.BottomSurface = Enum.SurfaceType.Smooth
	instance.Parent = parent
	return instance
end

local function wedge(parent: Instance, name: string, size: Vector3, cframe: CFrame,
	colour: Color3, material: Enum.Material): WedgePart
	local instance = Instance.new("WedgePart")
	instance.Name = name
	instance.Anchored = true
	instance.Size = size
	instance.CFrame = cframe
	instance.Color = colour
	instance.Material = material
	instance.Parent = parent
	return instance
end

--- One building: base, body, floor bands, openings, roof, eaves.
---
--- The parts count is the point. A single box painted brick is a box; the eave
--- overhang and the floor band are what read as construction at fifty studs,
--- which is where a player actually sees it.
function Architecture.building(parent: Instance, tokens: Tokens.TokenSet, spec: BuildingSpec): Model
	local footprint = spec.footprint
	local minimum = tokens:grammar("buildingMinFootprint")
	if footprint.X < minimum or footprint.Y < minimum then
		fail(string.format(
			"a building footprint of %.0fx%.0f is below the grammar's %.0f; a structure "
			.. "smaller than that reads as a prop and cannot hold a door",
			footprint.X, footprint.Y, minimum))
	end

	local storey = tokens:grammar("ceilingHeight")
	local floors = math.max(spec.floors or math.max(math.floor(tokens:grammar("buildingMinHeight") / storey), 1), 1)
	local height = storey * floors
	local rotation = CFrame.Angles(0, math.rad(spec.rotation or 0), 0)
	local origin = CFrame.new(spec.position) * rotation

	local style = spec.style
	local material = style.material or Enum.Material.Brick
	local wall = tokens:color(style.wall)
	local trim = tokens:color(style.trim)

	-- A row of buildings does not have one roof colour.
	--
	-- Every building in every generated game took `style.roof` verbatim, so a
	-- town read as one material from any distance and an aerial capture of a
	-- whole map came back with three distinct hues in it. Roofs are the largest
	-- surface visible from above and the cheapest place to put variety.
	--
	-- Chosen from the seed, not at random: the same building rebuilt from the
	-- same spec has to come out the same colour, or every rebuild is a diff.
	local roofTones = style.roofTones
	local roof
	if type(roofTones) == "table" and #roofTones > 0 then
		local pick = (spec.seed or 1) % #roofTones + 1
		roof = tokens:color(roofTones[pick])
	else
		roof = tokens:color(style.roof)
	end

	local model = Instance.new("Model")
	model.Name = "Building"
	model.Parent = parent

	-- Plinth. A wall meeting ground exactly is what makes a building look
	-- dropped onto the world rather than built on it.
	part(model, "Plinth", Vector3.new(footprint.X + 2, 2, footprint.Y + 2),
		origin * CFrame.new(0, 1, 0), trim, Enum.Material.Slate)

	part(model, "Body", Vector3.new(footprint.X, height, footprint.Y),
		origin * CFrame.new(0, 2 + height / 2, 0), wall, material)

	-- Floor bands: one horizontal line per storey. Cheap, and the single most
	-- effective cue that a mass has scale.
	for floor = 1, floors - 1 do
		part(model, "Band", Vector3.new(footprint.X + 0.8, 1.2, footprint.Y + 0.8),
			origin * CFrame.new(0, 2 + storey * floor, 0), trim, Enum.Material.Concrete)
	end

	-- Openings, inset rather than painted on, so they hold a shadow.
	local doorWidth = tokens:grammar("doorWidth")
	local doorHeight = tokens:grammar("doorHeight")
	local facing = math.rad(spec.facing or 0)
	local depth = footprint.Y / 2
	part(model, "Door", Vector3.new(doorWidth, doorHeight, 1.6),
		origin * CFrame.Angles(0, facing, 0) * CFrame.new(0, 2 + doorHeight / 2, -depth),
		tokens:color(style.accent), Enum.Material.Wood)

	local random = Random.new(spec.seed or 1)
	local windowsPerFloor = math.max(math.floor(footprint.X / (doorWidth * 1.6)), 1)
	for floor = 1, floors do
		for index = 1, windowsPerFloor do
			local offset = (index - (windowsPerFloor + 1) / 2) * (footprint.X / (windowsPerFloor + 1)) * 1.6
			local y = 2 + storey * (floor - 1) + storey * 0.55
			for _, side in ipairs({ 0, math.pi }) do
				part(model, "Window", Vector3.new(doorWidth * 0.55, storey * 0.4, 1.2),
					origin * CFrame.Angles(0, side + facing, 0)
						* CFrame.new(offset, y, -depth),
					tokens:color(style.accent), Enum.Material.Glass)
			end
		end
	end

	-- Roof with an overhang. The overhang is what casts the line of shadow that
	-- separates a roof from a lid.
	local eave = 3
	part(model, "Eave", Vector3.new(footprint.X + eave, 1.4, footprint.Y + eave),
		origin * CFrame.new(0, 2 + height + 0.7, 0), trim, Enum.Material.WoodPlanks)

	local pitch = math.max(storey * 0.6, 6)
	local half = (footprint.Y + eave) / 2
	for _, sign in ipairs({ 1, -1 }) do
		wedge(model, "Roof", Vector3.new(footprint.X + eave, pitch, half),
			origin * CFrame.new(0, 2 + height + 1.4 + pitch / 2, sign * half / 2)
				* CFrame.Angles(0, sign > 0 and 0 or math.pi, 0),
			roof, Enum.Material.Slate)
	end

	-- Fine grain on the facade: sills under the windows and quoins at the
	-- corners. Each is small against the mass it sits on, and that contrast of
	-- sizes is what stops a wall reading as a painted rectangle -- the scene
	-- critic measures it as scale coherence and a facade of one grain fails it
	-- however many windows are on it.
	for _, corner in ipairs({ 1, -1 }) do
		for step = 0, floors - 1 do
			part(model, "Quoin", Vector3.new(1.6, storey * 0.9, 1.6),
				origin * CFrame.new(corner * footprint.X / 2, 2 + storey * (step + 0.5),
					footprint.Y / 2),
				trim, Enum.Material.Slate)
		end
	end
	for floor = 1, floors do
		part(model, "Sill", Vector3.new(footprint.X * 0.9, 0.7, 1.6),
			origin * CFrame.Angles(0, facing, 0)
				* CFrame.new(0, 2 + storey * (floor - 1) + storey * 0.34, -depth),
			trim, Enum.Material.Concrete)
	end

	-- A chimney breaks the roofline, which is what stops a row of buildings
	-- reading as one extruded shape.
	if random:NextNumber() > 0.35 then
		local x = random:NextNumber(-footprint.X * 0.3, footprint.X * 0.3)
		part(model, "Chimney", Vector3.new(4, pitch + 6, 4),
			origin * CFrame.new(x, 2 + height + pitch / 2 + 3, 0), trim, Enum.Material.Brick)
	end

	model.PrimaryPart = model:FindFirstChild("Body") :: BasePart
	return model
end

export type WallSpec = {
	from: Vector3,
	to: Vector3,
	height: number?,
	thickness: number?,
	style: Style,
	--- Towers every N studs. A long wall with nothing on it is a slab stood up.
	towerSpacing: number?,
}

--- A defensive wall with merlons and towers.
---
--- The most valuable single structure for a scene that reads as empty: it
--- occludes the horizon, and the horizon is where the flat-plane measurement
--- comes from.
function Architecture.wall(parent: Instance, tokens: Tokens.TokenSet, spec: WallSpec): Model
	local from, to = spec.from, spec.to
	local span = (to - from)
	local length = span.Magnitude
	if length < 1 then
		fail("a wall needs two distinct endpoints")
	end

	local height = spec.height or tokens:grammar("buildingMinHeight")
	local thickness = spec.thickness or 6
	local centre = from:Lerp(to, 0.5)
	local look = CFrame.lookAt(centre, centre + span.Unit)

	local model = Instance.new("Model")
	model.Name = "Wall"
	model.Parent = parent

	local wall = tokens:color(spec.style.wall)
	local trim = tokens:color(spec.style.trim)

	part(model, "Curtain", Vector3.new(thickness, height, length),
		look * CFrame.new(0, height / 2, 0), wall, Enum.Material.Cobblestone)

	-- Walkway and merlons. The crenellation is a silhouette detail: it is what a
	-- player sees against the sky, and it costs one part per two studs.
	part(model, "Walk", Vector3.new(thickness + 3, 1.5, length),
		look * CFrame.new(0, height + 0.75, 0), trim, Enum.Material.Slate)

	local merlon = 4
	local count = math.max(math.floor(length / (merlon * 2)), 1)
	for index = 0, count do
		local along = -length / 2 + index * (length / count)
		part(model, "Merlon", Vector3.new(thickness + 3, 4, merlon),
			look * CFrame.new(0, height + 3.5, along), wall, Enum.Material.Cobblestone)
	end

	local spacing = spec.towerSpacing or 90
	local towers = math.max(math.floor(length / spacing), 0)
	for index = 0, towers do
		local along = -length / 2 + index * (length / math.max(towers, 1))
		Architecture.tower(model, tokens, {
			position = (look * CFrame.new(0, 0, along)).Position,
			radius = thickness * 1.6,
			height = height * 1.5,
			style = spec.style,
		})
	end

	return model
end

export type TowerSpec = {
	position: Vector3,
	radius: number?,
	height: number?,
	style: Style,
	--- A light at the top. A landmark that does not read at night is a landmark
	--- half the session cannot see.
	beacon: boolean?,
}

--- A round tower: base flare, shaft, corbel, battlement, roof.
function Architecture.tower(parent: Instance, tokens: Tokens.TokenSet, spec: TowerSpec): Model
	local radius = spec.radius or 10
	local height = spec.height or tokens:grammar("landmarkMinHeight")
	local origin = CFrame.new(spec.position)

	local model = Instance.new("Model")
	model.Name = "Tower"
	model.Parent = parent

	local wall = tokens:color(spec.style.wall)
	local trim = tokens:color(spec.style.trim)
	local roof = tokens:color(spec.style.roof)

	local function cylinder(name: string, size: Vector3, cframe: CFrame, colour: Color3,
		material: Enum.Material): Part
		local instance = part(model, name, size, cframe, colour, material)
		instance.Shape = Enum.PartType.Cylinder
		return instance
	end

	-- Cylinders are rotated: the Roblox cylinder's length runs along X.
	local upright = CFrame.Angles(0, 0, math.rad(90))

	cylinder("Base", Vector3.new(4, radius * 2.4, radius * 2.4),
		origin * CFrame.new(0, 2, 0) * upright, trim, Enum.Material.Slate)
	cylinder("Shaft", Vector3.new(height, radius * 2, radius * 2),
		origin * CFrame.new(0, 4 + height / 2, 0) * upright, wall, Enum.Material.Cobblestone)
	cylinder("Corbel", Vector3.new(3, radius * 2.5, radius * 2.5),
		origin * CFrame.new(0, 4 + height + 1.5, 0) * upright, trim, Enum.Material.Slate)

	local merlons = 10
	for index = 1, merlons do
		local angle = (index / merlons) * math.pi * 2
		part(model, "Merlon", Vector3.new(4, 5, 4),
			origin * CFrame.new(math.cos(angle) * radius, 4 + height + 5.5,
				math.sin(angle) * radius) * CFrame.Angles(0, -angle, 0),
			wall, Enum.Material.Cobblestone)
	end

	-- Sized to read, not to dominate. At radius * 1.6 this was a 24-stud ball of
	-- Neon: from the plaza it blew the whole frame to white and the keep behind
	-- it disappeared. A landmark the eye cannot look past is not a landmark.
	local cone = Instance.new("Part")
	cone.Name = "Spire"
	cone.Anchored = true
	cone.Shape = Enum.PartType.Ball
	cone.Size = Vector3.new(radius * 0.7, radius * 0.7, radius * 0.7)
	cone.CFrame = origin * CFrame.new(0, 4 + height + 10, 0)
	cone.Color = roof
	cone.Material = Enum.Material.Metal
	cone.Parent = model

	if spec.beacon then
		-- A beacon marks a place; it does not light the town. Brightness 4 over a
		-- 120-stud range washed every surface within sight of it, and the mood
		-- the token set describes stopped being visible at all.
		local light = Instance.new("PointLight")
		light.Brightness = 1.4
		light.Range = radius * 3.5
		light.Color = tokens:color(spec.style.accent)
		light.Parent = cone
		cone.Material = Enum.Material.Neon
		cone.Color = tokens:color(spec.style.accent)
	end

	model.PrimaryPart = model:FindFirstChild("Shaft") :: BasePart
	return model
end

export type TerraceSpec = {
	centre: Vector3,
	size: Vector2,
	steps: number?,
	rise: number?,
	style: Style,
	--- Edge length of one paving slab, in studs.
	slabSize: number?,
	seed: number?,
}

--- Stepped ground. The cheapest fix for "no vertical variation".
---
--- Ground at one elevation reads as a floor plan in perspective no matter what
--- is placed on it, and a terrace is a handful of parts.
function Architecture.terrace(parent: Instance, tokens: Tokens.TokenSet, spec: TerraceSpec): Model
	local steps = math.max(spec.steps or 3, 1)
	local rise = spec.rise or tokens:grammar("stairRise") * 3

	local model = Instance.new("Model")
	model.Name = "Terrace"
	model.Parent = parent

	for index = 1, steps do
		local shrink = (index - 1) / steps
		local size = Vector3.new(
			spec.size.X * (1 - shrink * 0.45), rise, spec.size.Y * (1 - shrink * 0.45))
		part(model, "Step", size,
			CFrame.new(spec.centre + Vector3.new(0, rise * (index - 0.5), 0)),
			tokens:color(index % 2 == 0 and spec.style.trim or spec.style.wall),
			Enum.Material.Slate)
	end

	-- Paving on the top step.
	--
	-- An unbroken surface is the single largest thing left in a scene critique:
	-- an eye-level frame read 60% as one plane, and that plane was the plaza the
	-- player stands on. Slabs at two tones with a gap between them break it into
	-- something the eye can measure distance against, which is most of what
	-- makes a floor read as built rather than as backdrop.
	local top = spec.centre + Vector3.new(0, rise * steps, 0)
	local span = Vector2.new(spec.size.X * (1 - 0.45 * (steps - 1) / steps),
		spec.size.Y * (1 - 0.45 * (steps - 1) / steps))
	local slab = spec.slabSize or 9
	local across = math.max(math.floor(span.X / slab), 1)
	local along = math.max(math.floor(span.Y / slab), 1)
	local random = Random.new(spec.seed or 1)

	for row = 0, along - 1 do
		for column = 0, across - 1 do
			local x = -span.X / 2 + (column + 0.5) * (span.X / across)
			local z = -span.Y / 2 + (row + 0.5) * (span.Y / along)
			-- A checker plus a random third tone: a strict checker is its own
			-- kind of repetition, and reads as a chessboard rather than as stone.
			local role = spec.style.wall
			if (row + column) % 2 == 0 then
				role = spec.style.trim
			elseif random:NextNumber() > 0.78 then
				role = spec.style.roof
			end
			part(model, "Slab",
				Vector3.new(span.X / across - 0.5, 0.35, span.Y / along - 0.5),
				CFrame.new(top + Vector3.new(x, 0.18, z)),
				tokens:color(role), Enum.Material.Slate)
		end
	end
	return model
end

--- Every structure this module can build, for a caller choosing between them.
function Architecture.kinds(): { string }
	return { "building", "wall", "tower", "terrace" }
end

return Architecture
