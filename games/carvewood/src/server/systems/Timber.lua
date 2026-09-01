--!strict
--[[
	Timber — the trees, built rather than fetched.

	Why this is not `Catalog.Place`
	-------------------------------

	The catalogue holds 471 models and exactly three of them are trees. This
	game's entire progression is "unlock a rarer tree", so six species drawn
	from three models is three silhouettes recoloured twice -- an Amberheart
	that a player has saved six thousand coins for, arriving as the Pine they
	started with in a different green. The models are good; there are just
	almost none of the one thing this game is about, and the account cannot
	publish more right now.

	Parts solve that completely. A stylised tree is a trunk and a handful of
	spheres, every proportion is a number, and the result is the bright
	cartoon read the original has -- which a photoscanned mesh would not have
	given us anyway. Growth stages come free: the same recipe at 0.4 is a
	sapling.

	Recipes, not one tree with a palette
	------------------------------------

	Each species owns a silhouette. That is the point: the difference has to
	be legible from across a yard, at a glance, without reading a label, or
	the unlock does not feel like anything.
]]

local Recipe = {
	--: {x, y, z} radius multipliers, and where the blob sits up the trunk.
	blob = { at = Vector3.zero, size = Vector3.one, flat = 1 },
}

export type Blob = { at: Vector3, size: number, squash: number? }
export type Shape = {
	trunkHeight: number,
	trunkRadius: number,
	taper: number?,
	blobs: { Blob },
	branches: { { from: number, dir: Vector3, length: number } }?,
	glow: boolean?,
	litter: number?,
}

--[[
	The six silhouettes.

	Read down the `blobs` column and the progression is visible as shape alone:
	a narrow stack of three (conifer), a high pale pair (birch), one broad
	crown (oak), a triangle (maple), an asymmetric dark lean (ebony), and a
	tall crown with lights in it (amberheart).
]]
local SHAPES: { [string]: Shape } = {
	pine = {
		trunkHeight = 7, trunkRadius = 0.55, taper = 0.8,
		blobs = {
			{ at = Vector3.new(0, 5.4, 0), size = 3.1, squash = 0.72 },
			{ at = Vector3.new(0, 7.6, 0), size = 2.4, squash = 0.68 },
			{ at = Vector3.new(0, 9.4, 0), size = 1.5, squash = 0.66 },
		},
	},
	birch = {
		trunkHeight = 9.5, trunkRadius = 0.42, taper = 0.9,
		blobs = {
			{ at = Vector3.new(-0.5, 9.2, 0.3), size = 2.7, squash = 0.82 },
			{ at = Vector3.new(0.9, 10.4, -0.4), size = 2.2, squash = 0.8 },
		},
		branches = {
			{ from = 6.2, dir = Vector3.new(1, 0.9, 0.2), length = 2.4 },
			{ from = 7.4, dir = Vector3.new(-1, 0.8, -0.3), length = 2.1 },
		},
	},
	oak = {
		trunkHeight = 6.5, trunkRadius = 0.95, taper = 0.72,
		blobs = {
			{ at = Vector3.new(0, 8.2, 0), size = 4.6, squash = 0.86 },
			{ at = Vector3.new(-2.6, 7.0, 1.1), size = 2.6, squash = 0.9 },
			{ at = Vector3.new(2.4, 7.2, -1.3), size = 2.5, squash = 0.9 },
		},
		branches = {
			{ from = 5.0, dir = Vector3.new(1, 0.6, -0.4), length = 3.0 },
			{ from = 5.4, dir = Vector3.new(-1, 0.7, 0.5), length = 3.0 },
		},
	},
	maple = {
		trunkHeight = 7.5, trunkRadius = 0.8, taper = 0.76,
		blobs = {
			{ at = Vector3.new(0, 9.6, 0), size = 3.2, squash = 0.9 },
			{ at = Vector3.new(-2.5, 8.0, -0.6), size = 2.8, squash = 0.94 },
			{ at = Vector3.new(2.3, 8.2, 0.9), size = 2.8, squash = 0.94 },
		},
		branches = {
			{ from = 6.0, dir = Vector3.new(-1, 0.8, -0.2), length = 2.8 },
			{ from = 6.2, dir = Vector3.new(1, 0.8, 0.4), length = 2.8 },
		},
		litter = 6,
	},
	ebony = {
		--: Leaning, and thicker at the base than anything else. An Epic should
		--: look like it has been standing there longer.
		trunkHeight = 8.5, trunkRadius = 1.05, taper = 0.6,
		blobs = {
			{ at = Vector3.new(1.4, 9.8, -0.6), size = 3.6, squash = 0.78 },
			{ at = Vector3.new(-1.8, 8.4, 0.9), size = 2.6, squash = 0.74 },
			{ at = Vector3.new(0.4, 11.4, 0.2), size = 2.0, squash = 0.7 },
		},
		branches = {
			{ from = 6.4, dir = Vector3.new(1, 0.5, -0.5), length = 3.4 },
			{ from = 7.2, dir = Vector3.new(-1, 0.4, 0.7), length = 3.0 },
		},
	},
	amberheart = {
		trunkHeight = 11, trunkRadius = 1.0, taper = 0.7,
		blobs = {
			{ at = Vector3.new(0, 13.0, 0), size = 4.4, squash = 0.9 },
			{ at = Vector3.new(-2.8, 11.4, 1.2), size = 2.9, squash = 0.92 },
			{ at = Vector3.new(2.7, 11.6, -1.1), size = 2.9, squash = 0.92 },
			{ at = Vector3.new(0, 15.4, 0), size = 2.0, squash = 0.86 },
		},
		branches = {
			{ from = 8.0, dir = Vector3.new(1, 0.6, 0.3), length = 3.6 },
			{ from = 8.6, dir = Vector3.new(-1, 0.6, -0.4), length = 3.6 },
		},
		--: The only tree in the game that lights the ground under it. A
		--: Legendary should be visible from another player's yard, which is
		--: the whole reason six of them share a ring.
		glow = true,
		litter = 10,
	},
}

local Timber = {}

Timber.shapes = SHAPES

local function piece(name: string, parent: Instance, colour: Color3,
                     material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Color = colour
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[
	One tree, standing on `base`.

	`base` is the point the trunk meets the ground, not the model's centre.
	Every placement bug in this repo has come from a caller assuming a pivot
	sits somewhere it does not, so this takes the one position a caller
	actually knows.
]]
function Timber.grow(species: any, base: Vector3, parent: Instance,
                     options: { scale: number?, yaw: number?, seed: number? }?)
	local o = options or {}
	local shape = SHAPES[species.id] or SHAPES.pine
	local scale = o.scale or 1
	local yaw = o.yaw or 0

	local model = Instance.new("Model")
	model.Name = species.name

	local trunkHeight = shape.trunkHeight * scale
	local trunkRadius = shape.trunkRadius * scale
	local pivot = CFrame.new(base) * CFrame.Angles(0, yaw, 0)

	--: Cylinder parts lie down the X axis, so the trunk is turned upright.
	--: Getting this backwards produces a tree lying in its own soil, which is
	--: exactly what the first pass did.
	local trunk = piece("Trunk", model, species.trunk, Enum.Material.Wood)
	trunk.Shape = Enum.PartType.Cylinder
	trunk.Size = Vector3.new(trunkHeight, trunkRadius * 2, trunkRadius * 2)
	trunk.CFrame = pivot * CFrame.new(0, trunkHeight / 2, 0)
		* CFrame.Angles(0, 0, math.pi / 2)
	model.PrimaryPart = trunk

	--: A wider foot. Two seconds of work and it is most of why these read as
	--: drawn rather than as cylinders pushed into a lawn.
	local root = piece("Root", model, species.trunk, Enum.Material.Wood)
	root.Shape = Enum.PartType.Cylinder
	root.Size = Vector3.new(trunkRadius * 1.6, trunkRadius * 2.9,
		trunkRadius * 2.9)
	root.CFrame = pivot * CFrame.new(0, trunkRadius * 0.8, 0)
		* CFrame.Angles(0, 0, math.pi / 2)

	for _, branch in shape.branches or {} do
		local dir = branch.dir.Unit
		local length = branch.length * scale
		local arm = piece("Branch", model, species.trunk, Enum.Material.Wood)
		arm.Shape = Enum.PartType.Cylinder
		arm.Size = Vector3.new(length, trunkRadius * 0.9, trunkRadius * 0.9)
		arm.CanCollide = false
		local from = pivot * CFrame.new(0, branch.from * scale, 0)
		arm.CFrame = CFrame.new(from.Position + pivot:VectorToWorldSpace(dir) * (length / 2),
			from.Position + pivot:VectorToWorldSpace(dir) * length)
			* CFrame.Angles(0, math.pi / 2, 0)
	end

	for index, blob in shape.blobs do
		local leaf = piece("Leaves" .. index, model, species.colour,
			Enum.Material.SmoothPlastic)
		leaf.Shape = Enum.PartType.Ball
		local d = blob.size * 2 * scale
		leaf.Size = Vector3.new(d, d * (blob.squash or 1), d)
		leaf.CFrame = pivot * CFrame.new(blob.at * scale)
		--: Foliage never collides. A player who walks into a canopy and stops
		--: dead learns the tree is a wall, and every one of these is standing
		--: on a plot they have to reach.
		leaf.CanCollide = false
	end

	if shape.glow then
		local light = Instance.new("PointLight")
		light.Color = species.colour
		light.Brightness = 1.6
		light.Range = 26 * scale
		light.Parent = model.PrimaryPart
	end

	model.Parent = parent
	return model
end

return Timber
