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

--: One warning per missing topic. A placement loop asks a thousand times and
--: the first answer is the whole story.
local warnedTopics: { [string]: boolean } = {}

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
	--[[
		Scale to a height in studs instead, whatever the model's own size.

		The reason this exists: a blind multiplier assumes every model was
		authored at a sensible size and none of them were. A baked ore chunk
		measures one stud and a storage tank measures nineteen; asking for both
		at `scale = 1.3` gives an invisible pebble and a tower. Asking for both
		at `targetHeight = 4` gives two props that look like they belong in the
		same yard.

		Ignored when the prop has no measured height.
	]]
	targetHeight: number?,
	--[[
		A ceiling on how wide `targetHeight` may make it.

		Defaults to four times the target height. Exists because scaling a flat
		prop to a height multiplies its footprint by the same factor, and a
		furnace 0.8 studs tall asked to stand 8 became 48 studs across.
	]]
	maxFootprint: number?,
	--[[
		Fit the whole prop inside this, on its longest axis.

		Use instead of `targetHeight` when what matters is that it fits a slot
		rather than that it stands a given height. The two are mutually
		exclusive; this one wins.
	]]
	targetSize: number?,
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
function Prop.build(which: string, at: CFrame?, settings0: Options?): Model?
	local spec = StoreProps.get(which)
	if not spec then
		return nil
	end

	local settings = settings0 or {}
	local anchored = settings.anchored ~= false
	local collide = settings.canCollide == true

	local scale = settings.scale or 1
	local extents = spec.extents or { 0, 0, 0 }
	local height = extents[2] or 0
	local footprint = math.max(extents[1] or 0, extents[3] or 0)

	if settings.targetSize then
		--[[
			Fit the whole prop in a box, whichever axis is longest.

			The right request when what matters is that the thing fits
			somewhere -- a slot, a shelf, a cell -- rather than that it stands
			a particular height.
		]]
		local longest = math.max(extents[1] or 0, height, extents[3] or 0)
		if longest > 0.01 then
			scale = (settings.targetSize / longest) * scale
		end
	elseif settings.targetHeight and height > 0.01 then
		--[[
			Scale to a height, but never at any cost to the footprint.

			This was `targetHeight / height` alone, and height alone is a
			terrible handle on a flat prop. A furnace measuring 4.8 x 0.8 x 4.8
			asked to stand 8 studs tall scaled by ten and came back a 48-stud
			wall through the middle of the map -- correct by the arithmetic and
			absurd by every other measure.

			So the footprint is bounded too. `maxFootprint` defaults to four
			times the requested height, which is generous for anything upright
			and still refuses to turn a pancake into a plaza. The requested
			scale applies as a variation around the target rather than as the
			target itself.
		]]
		scale = (settings.targetHeight / height) * scale

		local limit = settings.maxFootprint or settings.targetHeight * 4
		if footprint > 0.01 and footprint * scale > limit then
			scale = limit / footprint
		end
	end

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
		--[[
			No PrimaryPart, deliberately.

			`WorldPivot` is ignored while a Model has a PrimaryPart -- the part's
			own CFrame wins. So setting both, as this did, left every prop
			pivoted to whichever part happened to be built first, which for a
			store model is frequently rotated.

			The damage was not to placement, which `PivotTo` still got right.
			It was to measurement: `GetExtentsSize` reports the box *oriented to
			the pivot*, so a storage tank whose true world box is 18.8 x 8.4 x
			8.4 measured 8.4 x 18.8 x 8.4, and an audit written against that
			number concluded the bake was wrong when the bake was right.

			`PivotTo` and `GetPivot` need no PrimaryPart. Nothing here welds.
		]]

		--[[
			An upright pivot at the model's own centre.

			Without this the pivot is inherited from `PrimaryPart`, which is
			whichever part happened to be first and is frequently rotated. Two
			things go wrong then, and both were measured rather than guessed:
			`PivotTo` lands the whole prop rotated by that part's angle, and
			`GetExtentsSize` -- which reports the box *oriented to the pivot* --
			answers with the axes permuted, so a crate asked to stand five studs
			tall reported fourteen.

			Setting `WorldPivot` explicitly makes placement mean what it says and
			makes the model measure the way it looks.
		]]
		local lowX, lowY, lowZ = math.huge, math.huge, math.huge
		local highX, highY, highZ = -math.huge, -math.huge, -math.huge
		for _, part in model:GetChildren() do
			if part:IsA("BasePart") then
				local cf, size = part.CFrame, part.Size
				local rx, ry, rz = cf.RightVector, cf.UpVector, cf.LookVector
				--: Half-extent of an oriented box on each world axis.
				local hx = math.abs(rx.X) * size.X + math.abs(ry.X) * size.Y
					+ math.abs(rz.X) * size.Z
				local hy = math.abs(rx.Y) * size.X + math.abs(ry.Y) * size.Y
					+ math.abs(rz.Y) * size.Z
				local hz = math.abs(rx.Z) * size.X + math.abs(ry.Z) * size.Y
					+ math.abs(rz.Z) * size.Z
				hx, hy, hz = hx * 0.5, hy * 0.5, hz * 0.5
				local at = cf.Position
				lowX = math.min(lowX, at.X - hx) highX = math.max(highX, at.X + hx)
				lowY = math.min(lowY, at.Y - hy) highY = math.max(highY, at.Y + hy)
				lowZ = math.min(lowZ, at.Z - hz) highZ = math.max(highZ, at.Z + hz)
			end
		end
		if lowX < math.huge then
			model.WorldPivot = CFrame.new(
				(lowX + highX) * 0.5, (lowY + highY) * 0.5, (lowZ + highZ) * 0.5)
		end

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
		--[[
			Say so, once, rather than returning nil into a placement loop.

			A silent nil here is how a world ends up with 17 props where 190
			were asked for: the loop skips, the count never mentions it, and the
			topic was misspelled or was never baked. Warned rather than raised
			because one absent topic should not take a world build down --
			but it must not be invisible either.
		]]
		if not warnedTopics[topic] then
			warnedTopics[topic] = true
			warn(string.format(
				"[Prop] no baked props under topic %q -- placement skipped. Known: %s",
				topic, table.concat(StoreProps.topics(), ", ")))
		end
		return nil
	end
	local spec = specs[(math.floor(math.abs(seed)) % #specs) + 1]

	local settings = options or {}
	local natural = spec.extents and spec.extents[2] or 0
	local scale = settings.scale or 1
	if settings.targetHeight and natural > 0.01 then
		scale = (settings.targetHeight / natural) * scale
	end
	local height = natural * scale
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
