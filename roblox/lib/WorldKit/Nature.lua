--!strict
-- Vegetation and rock scatter.
--
-- Seeded on purpose. A map that regenerates differently every run cannot be
-- regression-tested: a screenshot diff would flag the scatter instead of the
-- change being reviewed. Same seed, same world.

local Build = require(script.Parent.Build)
local Palette = require(script.Parent.Palette)
local Semantics = require(script.Parent.Semantics)

local Nature = {}

export type ScatterSpec = {
	centre: Vector3,
	size: Vector2,
	count: number,
	seed: number,
	--- Areas to keep clear (plots, roads, the hub), as {centre, size} pairs.
	exclusions: { { centre: Vector3, size: Vector2 } }?,
	minSpacing: number?,
}

export type ScatterReceipt = {
	requested: number,
	placed: number,
	attempts: number,
	maxAttempts: number,
	truncated: boolean,
}

local function inExclusion(point: Vector3, exclusions, padding: number): boolean
	if exclusions == nil then
		return false
	end
	for _, zone in ipairs(exclusions) do
		local dx = math.abs(point.X - zone.centre.X)
		local dz = math.abs(point.Z - zone.centre.Z)
		if dx <= zone.size.X / 2 + padding and dz <= zone.size.Y / 2 + padding then
			return true
		end
	end
	return false
end

--- Pick scatter points that avoid the exclusion zones and each other.
function Nature.points(spec: ScatterSpec): ({ Vector3 }, ScatterReceipt)
	if spec.count < 0 or spec.count % 1 ~= 0 then
		error("scatter count must be a non-negative integer", 2)
	end
	if spec.size.X <= 0 or spec.size.Y <= 0 then
		error("scatter size must be positive", 2)
	end
	local random = Random.new(spec.seed)
	local spacing = spec.minSpacing or 12
	if spacing < 0 then
		error("scatter minSpacing must be non-negative", 2)
	end
	local placed: { Vector3 } = {}
	local attempts = 0
	local maxAttempts = spec.count * 40

	while #placed < spec.count and attempts < maxAttempts do
		attempts += 1
		local point = Vector3.new(
			spec.centre.X + random:NextNumber(-spec.size.X / 2, spec.size.X / 2),
			spec.centre.Y,
			spec.centre.Z + random:NextNumber(-spec.size.Y / 2, spec.size.Y / 2)
		)
		if inExclusion(point, spec.exclusions, 6) then
			continue
		end
		local tooClose = false
		for _, existing in ipairs(placed) do
			if (existing - point).Magnitude < spacing then
				tooClose = true
				break
			end
		end
		if not tooClose then
			table.insert(placed, point)
		end
	end

	return placed, {
		requested = spec.count,
		placed = #placed,
		attempts = attempts,
		maxAttempts = maxAttempts,
		truncated = #placed < spec.count,
	}
end

--- A conifer: trunk plus stacked canopy tiers.
function Nature.tree(parent: Instance, theme: Palette.Theme, position: Vector3, scale: number, random: Random): Model
	local model = Instance.new("Model")
	model.Name = "Tree"
	model.Parent = parent
	Semantics.root(model, "vegetation", "tree", "worldkit.tree")

	local bark = Palette.get(theme, "bark")
	local leaf = Palette.get(theme, "leaf")
	local leafDark = Palette.get(theme, "leafDark")

	local trunkHeight = 9 * scale
	Build.cylinder(model, "Trunk", Vector3.new(2.2 * scale, trunkHeight, 2.2 * scale), position + Vector3.new(0, trunkHeight / 2, 0), bark)

	local tiers = 3
	for tier = 1, tiers do
		local fraction = (tier - 1) / tiers
		local width = (13 - tier * 2.6) * scale
		local height = 6.5 * scale
		local y = trunkHeight * 0.72 + fraction * 8 * scale + height / 2
		local swatch = if tier % 2 == 0 then leafDark else leaf
		local canopy = Build.part(model, "Canopy" .. tier, Vector3.new(width, height, width), position + Vector3.new(0, y, 0), swatch)
		canopy.Shape = Enum.PartType.Cylinder
		canopy.Size = Vector3.new(height, width, width)
		canopy.CFrame = CFrame.new(position + Vector3.new(0, y, 0))
			* CFrame.Angles(0, random:NextNumber(0, math.pi * 2), math.rad(90))
	end

	return model
end

--- A boulder cluster.
function Nature.rock(parent: Instance, theme: Palette.Theme, position: Vector3, scale: number, random: Random): Model
	local model = Instance.new("Model")
	model.Name = "Rock"
	model.Parent = parent
	Semantics.root(model, "vegetation", "rock", "worldkit.rock")

	local rock = Palette.get(theme, "rock")
	local rockDark = Palette.get(theme, "rockDark")

	for index = 1, random:NextInteger(2, 4) do
		local size = random:NextNumber(3, 7) * scale
		local offset = Vector3.new(
			random:NextNumber(-3, 3) * scale,
			size * 0.3,
			random:NextNumber(-3, 3) * scale
		)
		local boulder = Build.sphere(model, "Boulder" .. index, size, position + offset, if index % 2 == 0 then rockDark else rock)
		boulder.Size = Vector3.new(size, size * random:NextNumber(0.6, 0.9), size * random:NextNumber(0.8, 1.2))
		boulder.Orientation = Vector3.new(0, random:NextNumber(0, 360), 0)
	end

	return model
end

--- Scatter a mixed treeline and rock field in one call.
function Nature.scatter(parent: Instance, theme: Palette.Theme, spec: ScatterSpec, treeRatio: number?): Model
	local folder = Instance.new("Model")
	folder.Name = "Vegetation"
	folder.Parent = parent

	local random = Random.new(spec.seed)
	local ratio = treeRatio or 0.7

	local points, receipt = Nature.points(spec)
	for _, point in ipairs(points) do
		local scale = random:NextNumber(0.85, 1.5)
		if random:NextNumber() < ratio then
			Nature.tree(folder, theme, point, scale, random)
		else
			Nature.rock(folder, theme, point, scale, random)
		end
	end
	folder:SetAttribute("ScatterRequested", receipt.requested)
	folder:SetAttribute("ScatterPlaced", receipt.placed)
	folder:SetAttribute("ScatterAttempts", receipt.attempts)
	folder:SetAttribute("ScatterTruncated", receipt.truncated)

	return folder
end

return Nature
