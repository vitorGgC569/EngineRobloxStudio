--!strict
-- Structural primitives.
--
-- Every builder takes world-space sizes and positions, so a call reads the way
-- the result looks. Composite builders (building, road, fence) exist because a
-- map assembled from bare parts is where "everything is tiny and flat" comes
-- from: scale and detail have to be decisions the primitive makes, not
-- something each call site remembers.

local Palette = require(script.Parent.Palette)
local Semantics = require(script.Parent.Semantics)

local Build = {}

export type Options = {
	transparency: number?,
	canCollide: boolean?,
	castShadow: boolean?,
	reflectance: number?,
	shape: Enum.PartType?,
	orientation: Vector3?,
}

local function apply(part: BasePart, swatch: Palette.Swatch, options: Options?)
	local opts = options or {}
	part.Color = swatch.color
	part.Material = swatch.material
	part.Anchored = true
	part.CanCollide = if opts.canCollide == nil then true else opts.canCollide
	part.CastShadow = if opts.castShadow == nil then true else opts.castShadow
	part.Transparency = opts.transparency or 0
	part.Reflectance = opts.reflectance or 0
end

--- A plain box.
function Build.part(parent: Instance, name: string, size: Vector3, position: Vector3, swatch: Palette.Swatch, options: Options?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	apply(part, swatch, options)
	local opts = options or {}
	if opts.shape then
		part.Shape = opts.shape
	end
	if opts.orientation then
		part.Orientation = opts.orientation
	end
	part.Parent = parent
	return part
end

--- A flat disc or upright column.
---
--- `size` is (diameter, height, diameter) in world terms. A Roblox Cylinder
--- puts its circular faces on the local X axis, so the axes are swapped here --
--- passing plate-style sizes straight through is what once turned a decorative
--- 25x0.35x25 medallion into a 25-stud wall across a plaza.
function Build.cylinder(parent: Instance, name: string, size: Vector3, position: Vector3, swatch: Palette.Swatch, options: Options?): Part
	local part = Build.part(parent, name, size, position, swatch, options)
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(size.Y, size.X, size.Z)
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	return part
end

function Build.sphere(parent: Instance, name: string, diameter: number, position: Vector3, swatch: Palette.Swatch, options: Options?): Part
	local part = Build.part(parent, name, Vector3.new(diameter, diameter, diameter), position, swatch, options)
	part.Shape = Enum.PartType.Ball
	return part
end

--- A wedge, for roofs and ramps.
function Build.wedge(parent: Instance, name: string, size: Vector3, cframe: CFrame, swatch: Palette.Swatch, options: Options?): WedgePart
	local part = Instance.new("WedgePart")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	apply(part, swatch, options)
	part.Parent = parent
	return part
end

--- Replace a block's visible shell with a true rounded cuboid assembled from
--- boxes, cylinders and spheres. The original remains as the collision hull.
--- Radius is therefore a real world-space input, not decorative metadata.
function Build.round(part: BasePart, radius: number): Model
	if not part:IsA("Part") or part.Shape ~= Enum.PartType.Block then
		error("Build.round only supports block Parts", 2)
	end
	if radius <= 0 or radius >= math.min(part.Size.X, part.Size.Y, part.Size.Z) / 2 then
		error("radius must be positive and smaller than half the shortest side", 2)
	end
	if part:GetAttribute("WorldKitRounded") == true then
		error("part already has a rounded visual shell", 2)
	end

	local originalTransparency = part.Transparency
	local shell = Instance.new("Model")
	shell.Name = part.Name .. "RoundedVisual"
	shell:SetAttribute("WorldKitRole", "rounded-shell")
	shell:SetAttribute("CornerRadius", radius)
	shell.Parent = part.Parent

	local function visual(name: string, size: Vector3, localCFrame: CFrame, shape: Enum.PartType?): Part
		local component = Instance.new("Part")
		component.Name = name
		component.Size = size
		component.CFrame = part.CFrame * localCFrame
		component.Shape = shape or Enum.PartType.Block
		component.Color = part.Color
		component.Material = part.Material
		component.MaterialVariant = part.MaterialVariant
		component.Transparency = originalTransparency
		component.Reflectance = part.Reflectance
		component.CastShadow = part.CastShadow
		component.Anchored = true
		component.CanCollide = false
		component.CanTouch = false
		component.CanQuery = false
		component.Parent = shell
		return component
	end

	local size = part.Size
	local inner = size - Vector3.new(radius * 2, radius * 2, radius * 2)
	visual("CoreX", Vector3.new(inner.X, size.Y, inner.Z), CFrame.identity)
	visual("CoreY", Vector3.new(size.X, inner.Y, inner.Z), CFrame.identity)
	visual("CoreZ", Vector3.new(inner.X, inner.Y, size.Z), CFrame.identity)

	local half = size / 2 - Vector3.new(radius, radius, radius)
	local diameter = radius * 2
	for _, ySign in ipairs({ -1, 1 }) do
		for _, zSign in ipairs({ -1, 1 }) do
			visual(
				"EdgeX",
				Vector3.new(inner.X, diameter, diameter),
				CFrame.new(0, ySign * half.Y, zSign * half.Z),
				Enum.PartType.Cylinder
			)
		end
	end
	for _, xSign in ipairs({ -1, 1 }) do
		for _, zSign in ipairs({ -1, 1 }) do
			visual(
				"EdgeY",
				Vector3.new(inner.Y, diameter, diameter),
				CFrame.new(xSign * half.X, 0, zSign * half.Z) * CFrame.Angles(0, 0, math.rad(90)),
				Enum.PartType.Cylinder
			)
		end
	end
	for _, xSign in ipairs({ -1, 1 }) do
		for _, ySign in ipairs({ -1, 1 }) do
			visual(
				"EdgeZ",
				Vector3.new(inner.Z, diameter, diameter),
				CFrame.new(xSign * half.X, ySign * half.Y, 0) * CFrame.Angles(0, math.rad(90), 0),
				Enum.PartType.Cylinder
			)
		end
	end
	for _, xSign in ipairs({ -1, 1 }) do
		for _, ySign in ipairs({ -1, 1 }) do
			for _, zSign in ipairs({ -1, 1 }) do
				visual(
					"Corner",
					Vector3.new(diameter, diameter, diameter),
					CFrame.new(xSign * half.X, ySign * half.Y, zSign * half.Z),
					Enum.PartType.Ball
				)
			end
		end
	end

	part.Transparency = 1
	part.CastShadow = false
	part:SetAttribute("WorldKitRounded", true)
	part:SetAttribute("CornerRadius", radius)
	return shell
end

function Build.light(part: BasePart, color: Color3, brightness: number, range: number)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Shadows = true
	light.Parent = part
	return light
end

--- Text that floats above a part.
---
--- `maxDistance` is the important argument and it defaults low on purpose.
--- World labels do not compete for space the way UI does -- they overlap in
--- screen space, and a map with a few hundred of them becomes an unreadable
--- wall of text from any distance. Measured: 8 plots x 40 slot labels rendering
--- at 400 studs buried the entire map. A label should appear when a player is
--- close enough to act on the thing it names, and not before.
function Build.billboard(part: BasePart, text: string, color: Color3, width: number, height: number, offsetY: number, textSize: number, maxDistance: number?): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromOffset(width, height)
	gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = maxDistance or 55
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = false
	label.TextSize = textSize
	label.TextStrokeTransparency = 0.4
	label.Parent = gui
	return gui
end

--- Four walls, a floor and a roof, with window bands and a doorway gap.
---
--- Composite on purpose: a building is the unit a designer thinks in, and
--- assembling one from eight `part` calls at every site is how maps end up as
--- featureless boxes.
export type BuildingSpec = {
	size: Vector3,
	wallSwatch: Palette.Swatch,
	trimSwatch: Palette.Swatch,
	glassSwatch: Palette.Swatch?,
	roofSwatch: Palette.Swatch?,
	doorWidth: number?,
	doorFacing: string?,
	windows: boolean?,
	floorThickness: number?,
}

function Build.building(parent: Instance, name: string, spec: BuildingSpec, position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	Semantics.root(model, "building", "worldkit-building", "worldkit.building")

	local size = spec.size
	local wallThickness = 1.2
	local floorThickness = spec.floorThickness or 1
	local doorWidth = spec.doorWidth or 10
	local facing = spec.doorFacing or "-Z"
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		error("building size must be positive on every axis", 2)
	end
	if facing ~= "-Z" and facing ~= "+Z" and facing ~= "-X" and facing ~= "+X" then
		error("doorFacing must be one of -Z, +Z, -X or +X", 2)
	end
	local doorSpan = if facing == "-Z" or facing == "+Z" then size.X else size.Z
	if doorWidth <= 0 or doorWidth >= doorSpan - wallThickness * 2 then
		error("doorWidth must leave positive wall segments on both sides", 2)
	end
	local halfX, halfZ = size.X / 2, size.Z / 2

	Build.part(model, "Floor", Vector3.new(size.X, floorThickness, size.Z), position + Vector3.new(0, floorThickness / 2, 0), spec.trimSwatch)

	local wallY = position.Y + floorThickness + size.Y / 2
	local function wall(wallName: string, wallSize: Vector3, offset: Vector3)
		Build.part(model, wallName, wallSize, Vector3.new(position.X, wallY, position.Z) + offset, spec.wallSwatch)
	end

	-- Split the wall the door sits in, leaving a gap a character can walk through.
	local function splitWall(wallName: string, along: string, offset: Vector3)
		local span = if along == "X" then size.X else size.Z
		local side = (span - doorWidth) / 2
		for index, sign in ipairs({ -1, 1 }) do
			local centre = sign * (doorWidth / 2 + side / 2)
			local wallSize = if along == "X"
				then Vector3.new(side, size.Y, wallThickness)
				else Vector3.new(wallThickness, size.Y, side)
			local shift = if along == "X" then Vector3.new(centre, 0, 0) else Vector3.new(0, 0, centre)
			wall(wallName .. index, wallSize, offset + shift)
		end
	end

	if facing == "-Z" then
		splitWall("WallFront", "X", Vector3.new(0, 0, -halfZ))
		wall("WallBack", Vector3.new(size.X, size.Y, wallThickness), Vector3.new(0, 0, halfZ))
		wall("WallLeft", Vector3.new(wallThickness, size.Y, size.Z), Vector3.new(-halfX, 0, 0))
		wall("WallRight", Vector3.new(wallThickness, size.Y, size.Z), Vector3.new(halfX, 0, 0))
	elseif facing == "+Z" then
		wall("WallFront", Vector3.new(size.X, size.Y, wallThickness), Vector3.new(0, 0, -halfZ))
		splitWall("WallBack", "X", Vector3.new(0, 0, halfZ))
		wall("WallLeft", Vector3.new(wallThickness, size.Y, size.Z), Vector3.new(-halfX, 0, 0))
		wall("WallRight", Vector3.new(wallThickness, size.Y, size.Z), Vector3.new(halfX, 0, 0))
	elseif facing == "-X" then
		splitWall("WallFront", "Z", Vector3.new(-halfX, 0, 0))
		wall("WallBack", Vector3.new(wallThickness, size.Y, size.Z), Vector3.new(halfX, 0, 0))
		wall("WallLeft", Vector3.new(size.X, size.Y, wallThickness), Vector3.new(0, 0, -halfZ))
		wall("WallRight", Vector3.new(size.X, size.Y, wallThickness), Vector3.new(0, 0, halfZ))
	else
		wall("WallFront", Vector3.new(wallThickness, size.Y, size.Z), Vector3.new(-halfX, 0, 0))
		splitWall("WallBack", "Z", Vector3.new(halfX, 0, 0))
		wall("WallLeft", Vector3.new(size.X, size.Y, wallThickness), Vector3.new(0, 0, -halfZ))
		wall("WallRight", Vector3.new(size.X, size.Y, wallThickness), Vector3.new(0, 0, halfZ))
	end

	if spec.windows ~= false and spec.glassSwatch then
		local bandY = wallY + size.Y * 0.18
		local bandHeight = math.max(2.5, size.Y * 0.26)
		local bands = {}
		if facing ~= "-Z" then
			table.insert(bands, { Vector3.new(size.X * 0.96, bandHeight, 0.6), Vector3.new(0, 0, -halfZ) })
		end
		if facing ~= "+Z" then
			table.insert(bands, { Vector3.new(size.X * 0.96, bandHeight, 0.6), Vector3.new(0, 0, halfZ) })
		end
		if facing ~= "-X" then
			table.insert(bands, { Vector3.new(0.6, bandHeight, size.Z * 0.96), Vector3.new(-halfX, 0, 0) })
		end
		if facing ~= "+X" then
			table.insert(bands, { Vector3.new(0.6, bandHeight, size.Z * 0.96), Vector3.new(halfX, 0, 0) })
		end
		for _, entry in ipairs(bands) do
			Build.part(model, "Window", entry[1], Vector3.new(position.X, bandY, position.Z) + entry[2], spec.glassSwatch, {
				transparency = 0.55,
				canCollide = false,
				reflectance = 0.15,
			})
		end
	end

	local roofY = position.Y + floorThickness + size.Y
	local roofSwatch = spec.roofSwatch or spec.trimSwatch
	Build.part(model, "Roof", Vector3.new(size.X + 2.5, 1.4, size.Z + 2.5), Vector3.new(position.X, roofY + 0.7, position.Z), roofSwatch)
	Build.part(model, "RoofTrim", Vector3.new(size.X + 3.5, 0.6, size.Z + 3.5), Vector3.new(position.X, roofY + 1.6, position.Z), spec.trimSwatch)

	model.PrimaryPart = model:FindFirstChild("Floor") :: BasePart
	return model
end

--- A paved strip between two points, laid on the ground.
function Build.road(parent: Instance, name: string, from: Vector3, to: Vector3, width: number, swatch: Palette.Swatch, y: number): Part
	local delta = to - from
	local length = Vector3.new(delta.X, 0, delta.Z).Magnitude
	local centre = Vector3.new((from.X + to.X) / 2, y, (from.Z + to.Z) / 2)
	local angle = math.atan2(delta.X, delta.Z)

	local road = Build.part(parent, name, Vector3.new(width, 0.4, length), centre, swatch, { castShadow = false })
	road.CFrame = CFrame.new(centre) * CFrame.Angles(0, angle, 0)
	return road
end

--- Posts and rails along a line.
function Build.fence(parent: Instance, name: string, from: Vector3, to: Vector3, height: number, swatch: Palette.Swatch, spacing: number?): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent

	local delta = to - from
	local length = Vector3.new(delta.X, 0, delta.Z).Magnitude
	local step = spacing or 12
	local count = math.max(2, math.floor(length / step))
	local angle = math.atan2(delta.X, delta.Z)

	for index = 0, count do
		local point = from:Lerp(to, index / count)
		local post = Build.part(model, "Post", Vector3.new(0.8, height, 0.8), point + Vector3.new(0, height / 2, 0), swatch)
		post.CastShadow = false
	end

	local centre = from:Lerp(to, 0.5)
	for _, level in ipairs({ 0.45, 0.8 }) do
		local rail = Build.part(model, "Rail", Vector3.new(0.4, 0.4, length), centre + Vector3.new(0, height * level, 0), swatch, { canCollide = false, castShadow = false })
		rail.CFrame = CFrame.new(centre + Vector3.new(0, height * level, 0)) * CFrame.Angles(0, angle, 0)
	end
	return model
end

--- A tapered support column with a cap, for arches and gateways.
function Build.pillar(parent: Instance, name: string, base: Vector3, height: number, radius: number, swatch: Palette.Swatch, capSwatch: Palette.Swatch?): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent

	Build.part(model, "Base", Vector3.new(radius * 2.4, 1.2, radius * 2.4), base + Vector3.new(0, 0.6, 0), capSwatch or swatch)
	Build.cylinder(model, "Shaft", Vector3.new(radius * 2, height, radius * 2), base + Vector3.new(0, height / 2 + 1.2, 0), swatch)
	Build.part(model, "Cap", Vector3.new(radius * 2.6, 1, radius * 2.6), base + Vector3.new(0, height + 1.8, 0), capSwatch or swatch)
	return model
end

return Build
