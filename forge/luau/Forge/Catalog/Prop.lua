--!strict
--[[
	Prop — rebuild a Creator Store model from baked geometry.

	`StoreProps` holds specs read out of real store models; this turns one into
	instances. Nothing is fetched: the geometry is data in the place, so this
	works in a live game where `InsertService` and `game:GetObjects` do not.

		local Prop = Forge.Catalog.Prop
		local rock = Prop.build("rock", CFrame.new(0, 5, 0))
		rock.Parent = workspace

	What a rebuilt prop is and is not
	---------------------------------

	Meshed parts come back as a `Part` carrying a `SpecialMesh`, because
	`MeshPart.MeshId` cannot be written -- not at runtime and not from a plugin.
	Two consequences worth knowing before using one for something load-bearing:

	  * **No PBR.** `SurfaceAppearance` is a child of a MeshPart and has no
	    SpecialMesh equivalent, so a prop that shipped with colour, normal and
	    roughness maps comes back with its flat colour and material.

	  * **Box collision.** A SpecialMesh is decoration on a Part, and the Part's
	    box is what a player collides with. Fine for scenery, wrong for anything
	    somebody has to stand on precisely.

	Everything is built anchored and non-colliding by default. A store model's
	own anchoring is whatever its author happened to leave, and a third of the
	catalogued ones carry unanchored parts -- each one a physics body the server
	simulates for as long as it exists. Scenery needs none of that, and a caller
	who wants a prop to fall says so.
]]

local StoreProps = require(script.Parent.StoreProps)

local Prop = {}

local MATERIALS: { [string]: Enum.Material } = {}
for _, material in Enum.Material:GetEnumItems() do
	MATERIALS[material.Name] = material
end

local SHAPES: { [string]: Enum.PartType } = {}
for _, shape in Enum.PartType:GetEnumItems() do
	SHAPES[shape.Name] = shape
end

export type Options = {
	--: Anchored unless a caller has a reason. See the header.
	anchored: boolean?,
	canCollide: boolean?,
	--: Multiplied through every part's size and offset, so a prop scales as one
	--: object rather than as a pile of parts that drift apart.
	scale: number?,
	name: string?,
	parent: Instance?,
}

local function colourOf(rgb: { number }?): Color3
	if not rgb or #rgb < 3 then
		return Color3.fromRGB(163, 162, 165)
	end
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

--[[
	One part from its baked row.

	The twelve `cf` numbers are a CFrame's components in the order
	`CFrame.new` takes them, which is why they are stored flat: a table of
	twelve numbers survives JSON, and a CFrame does not.
]]
local function buildPart(row: any, scale: number): BasePart
	local part: BasePart
	if row.mesh then
		part = Instance.new("Part")
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.MeshId = row.mesh
		if row.texture then
			mesh.TextureId = row.texture
		end
		local meshScale = row.scale or { 1, 1, 1 }
		mesh.Scale = Vector3.new(meshScale[1], meshScale[2], meshScale[3]) * scale
		mesh.Parent = part
	else
		part = Instance.new("Part")
		if row.shape and SHAPES[row.shape] then
			(part :: Part).Shape = SHAPES[row.shape]
		end
	end

	part.Size = Vector3.new(row.size[1], row.size[2], row.size[3]) * scale
	part.Color = colourOf(row.color)
	part.Material = MATERIALS[row.material] or Enum.Material.Plastic
	part.Transparency = row.transparency or 0
	part.Reflectance = row.reflectance or 0

	local c = row.cf
	--: Position scales with the prop; the rotation basis must not, or a scaled
	--: prop comes back sheared.
	part.CFrame = CFrame.new(
		c[1] * scale, c[2] * scale, c[3] * scale,
		c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12])
	return part
end

--[[
	Build one prop by its spec id or topic.

	A topic returns the first spec filed under it, which the bake orders best
	first. Nil when nothing matches -- a missing prop is a real answer and
	should not be an error that takes a world build down with it.
]]
function Prop.build(which: string, at: CFrame?, options: Options?): Model?
	local spec = StoreProps.get(which)
	if not spec then
		return nil
	end

	local settings = options or {}
	local scale = settings.scale or 1
	local anchored = settings.anchored ~= false
	local collide = settings.canCollide == true

	local model = Instance.new("Model")
	model.Name = settings.name or spec.name

	local primary: BasePart? = nil
	for _, row in spec.parts do
		local part = buildPart(row, scale)
		part.Anchored = anchored
		part.CanCollide = collide
		--: Off for every part: a decorative prop that queries touch events is
		--: paying for events nothing reads.
		part.CanTouch = false
		part.CanQuery = collide
		part.Parent = model
		primary = primary or part
	end

	if primary then
		model.PrimaryPart = primary
		if at then
			model:PivotTo(at)
		end
	end

	if settings.parent then
		model.Parent = settings.parent
	end
	return model
end

--[[
	Build one of a topic's props, chosen by a seed rather than at random.

	Scenery wants variety and reproducibility at once: two runs of the same
	world generator should place the same rocks, or a scene cannot be authored
	against. The seed is the caller's, so the same world layout gives the same
	result every time.
]]
function Prop.variant(topic: string, seed: number, at: CFrame?, options: Options?): Model?
	local specs = StoreProps.byTopic(topic)
	if #specs == 0 then
		return nil
	end
	local index = (math.floor(math.abs(seed)) % #specs) + 1
	return Prop.build(tostring(specs[index].id), at, options)
end

--[[
	Place a prop standing on a point, rather than centred on it.

	`PivotTo` puts a model's centre where you ask, which for scenery is almost
	never what is wanted: a rock placed on the ground sinks halfway into it and
	a tree floats with its trunk cut off. This lifts by half the prop's own
	height so its base meets the point.

	`yaw` is taken rather than left to the caller because a scattered prop that
	is not rotated reads as a repeated stamp -- the single most obvious tell
	that a field of rocks came out of a loop.
]]
function Prop.place(topic: string, seed: number, on: Vector3, options: Options?): Model?
	local specs = StoreProps.byTopic(topic)
	if #specs == 0 then
		return nil
	end
	local spec = specs[(math.floor(math.abs(seed)) % #specs) + 1]

	local settings = options or {}
	local scale = settings.scale or 1
	local height = (spec.extents and spec.extents[2] or 0) * scale
	--: Sunk very slightly, so a prop with an uneven base does not stand on a
	--: visible seam of terrain.
	local lift = height * 0.5 - math.min(height * 0.08, 0.6)

	--: Yaw from the seed, so the same world generates the same field twice.
	local yaw = (seed * 0.61803398875 % 1) * math.pi * 2
	local frame = CFrame.new(on + Vector3.new(0, lift, 0)) * CFrame.Angles(0, yaw, 0)
	return Prop.build(tostring(spec.id), frame, options)
end

function Prop.describe(): { [string]: any }
	return {
		props = StoreProps.count,
		topics = StoreProps.topics(),
		rebuild = "Part + SpecialMesh; no SurfaceAppearance, box collision",
	}
end

return Prop
