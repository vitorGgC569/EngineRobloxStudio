--!strict
--- Terrain: the ground a professional Roblox game actually stands on.
---
--- Everything this factory built stood on boxes. A `Part` the size of the map,
--- painted green, is the single clearest tell that a place is a greybox -- and
--- the whole of the terrain capability was one function, `Fab.terrainBox`,
--- which writes a rectangle of voxels and nothing else. No hills, no water, no
--- material transitions, no way to carve.
---
--- Voxel terrain is fully scriptable and needs no upload, no asset id and no
--- moderation, which makes it the highest-value unclaimed ground in the engine.
---
--- **Three things this module knows that the raw API does not tell you.**
---
--- Terrain is on a 4-stud grid. `WriteVoxels` rejects a region that is not
--- aligned, and the error does not say so -- it says the region is invalid.
--- Every region here is expanded to alignment before it is used, and the
--- expansion is reported so a caller can see they got more ground than they
--- asked for.
---
--- Occupancy is not visibility. A voxel at 0.5 occupancy is a half-full cell
--- that renders as a slope, which is how smooth ground is made at all. Writing
--- 1.0 everywhere below the surface and 0.0 above gives you a staircase; the
--- surface cell has to carry the fraction.
---
--- Height is expensive in the wrong axis. A 512x512 stud field at 4-stud
--- resolution is 128x128 columns, which is fine -- but if the region spans 300
--- studs vertically that is 75 cells per column and 1.2 million voxels. So the
--- vertical extent is derived from the height range actually generated, not
--- from whatever the caller passed.

local Workspace = game:GetService("Workspace")

local Land = {}

--- Terrain's voxel size. Not configurable, and everything here depends on it.
local RESOLUTION = 4

export type Bounds = {
	centre: Vector3,
	size: Vector3,
}

export type HeightSpec = {
	centre: Vector3,
	--- Footprint in studs, on X and Z.
	size: Vector2,
	--- Ground level at zero displacement.
	baseHeight: number?,
	--- Peak-to-trough displacement, in studs. The field is rescaled to span
	--- exactly this, so the number means what it says.
	amplitude: number?,
	--- Studs per noise period. Larger is smoother.
	wavelength: number?,
	--- How many octaves of detail. Each is half the amplitude, double the
	--- frequency. Three is enough for hills; five starts costing frames.
	octaves: number?,
	seed: number?,
	material: Enum.Material?,
	--- Below this height, fill with water rather than leaving air.
	waterLevel: number?,
	--- Flatten to `baseHeight` inside these footprints, so a build plot stays
	--- buildable. Without this, terrain and architecture fight.
	flatten: { { centre: Vector3, size: Vector2 } }?,
}

export type Receipt = {
	operation: string,
	status: string,
	voxels: number,
	region: { min: { number }, max: { number } },
	detail: { [string]: any },
}

local function receipt(operation: string, status: string, voxels: number,
	region: Region3, detail: { [string]: any }?): Receipt

	local min = region.CFrame.Position - region.Size * 0.5
	local max = region.CFrame.Position + region.Size * 0.5
	return {
		operation = operation,
		status = status,
		voxels = voxels,
		region = {
			min = { min.X, min.Y, min.Z },
			max = { max.X, max.Y, max.Z },
		},
		detail = detail or {},
	}
end

--- Grow a region until it lands on the voxel grid.
---
--- `ExpandToGrid` is the supported way and it only ever grows, never shrinks,
--- so the caller reliably gets at least what they asked for.
local function aligned(centre: Vector3, size: Vector3): Region3
	local half = size * 0.5
	return Region3.new(centre - half, centre + half):ExpandToGrid(RESOLUTION)
end

--- Layered Perlin, which Luau has built in as `math.noise`.
---
--- One octave is a rolling swell and reads as artificial the moment you look at
--- it twice. Three octaves is a landscape. The seed shifts the sample point
--- rather than changing the function, so the same seed is the same hills --
--- which is what makes a scatter, a blockout and a heightfield agree.
local function height(x: number, z: number, spec: HeightSpec): number
	local wavelength = math.max(spec.wavelength or 90, 1)
	local octaves = math.clamp(spec.octaves or 3, 1, 6)
	local seed = (spec.seed or 1) * 0.37

	local total, amplitude, frequency, normal = 0, 1, 1, 0
	for _ = 1, octaves do
		total += math.noise(
			x / wavelength * frequency + seed,
			z / wavelength * frequency + seed,
			seed) * amplitude
		normal += amplitude
		amplitude *= 0.5
		frequency *= 2
	end

	return (total / normal) * (spec.amplitude or 24) * 0.5
end

--- How much of `footprint` a point sits inside, 0 outside, 1 well within.
---
--- A hard edge on a flattened plot leaves a cliff round the build site. The
--- falloff is what makes terrain meet architecture instead of colliding with it.
local function flattenWeight(x: number, z: number,
	zones: { { centre: Vector3, size: Vector2 } }): number

	local strongest = 0
	for _, zone in ipairs(zones) do
		local halfX, halfZ = zone.size.X * 0.5, zone.size.Y * 0.5
		local dx = math.abs(x - zone.centre.X)
		local dz = math.abs(z - zone.centre.Z)
		-- A quarter of the zone is the blend band, so the flat area is the
		-- footprint asked for and the transition happens outside it.
		local blend = math.max(math.min(halfX, halfZ) * 0.25, 1)
		local inside = math.min(
			math.clamp((halfX + blend - dx) / blend, 0, 1),
			math.clamp((halfZ + blend - dz) / blend, 0, 1))
		strongest = math.max(strongest, inside)
	end
	return strongest
end

--- Sculpt a heightfield. The main event.
function Land.heightfield(spec: HeightSpec): Receipt
	if spec.size.X <= 0 or spec.size.Y <= 0 then
		error("heightfield size must be positive on both axes", 2)
	end

	local base = spec.baseHeight or 0
	local amplitude = spec.amplitude or 24
	local zones = spec.flatten or {}
	local material = spec.material or Enum.Material.Grass
	local water = spec.waterLevel

	local halfX = spec.size.X * 0.5
	local halfZ = spec.size.Y * 0.5
	local originX = spec.centre.X - halfX
	local originZ = spec.centre.Z - halfZ

	-- Sample first, write second. The vertical extent of the region has to be
	-- known before the region exists, and guessing it either clips the peaks or
	-- pays for hundreds of empty cells per column.
	local columns = math.max(math.floor(spec.size.X / RESOLUTION), 1)
	local rows = math.max(math.floor(spec.size.Y / RESOLUTION), 1)

	local heights: { { number } } = {}
	local lowest, highest = math.huge, -math.huge
	for i = 1, columns do
		heights[i] = {}
		local x = originX + (i - 0.5) * RESOLUTION
		for k = 1, rows do
			local z = originZ + (k - 0.5) * RESOLUTION
			heights[i][k] = height(x, z, spec)
		end
	end

	-- **Rescale, or `amplitude` is a lie.** Layered Perlin normalised by the sum
	-- of its octave weights almost never reaches +/-1: asking for 34 studs of
	-- relief measured 15.1 across the whole field, and the number in the call
	-- meant nothing. Stretching the sampled field to the requested span makes
	-- `amplitude` the peak-to-trough it claims to be.
	local rawLow, rawHigh = math.huge, -math.huge
	for i = 1, columns do
		for k = 1, rows do
			rawLow = math.min(rawLow, heights[i][k])
			rawHigh = math.max(rawHigh, heights[i][k])
		end
	end
	local rawSpan = rawHigh - rawLow
	local scale = if rawSpan > 1e-4 then amplitude / rawSpan else 0

	for i = 1, columns do
		local x = originX + (i - 0.5) * RESOLUTION
		for k = 1, rows do
			local z = originZ + (k - 0.5) * RESOLUTION
			local raised = base + (heights[i][k] - (rawLow + rawHigh) * 0.5) * scale
			if #zones > 0 then
				local weight = flattenWeight(x, z, zones)
				raised = raised * (1 - weight) + base * weight
			end
			heights[i][k] = raised
			lowest = math.min(lowest, raised)
			highest = math.max(highest, raised)
		end
	end

	local floor = math.min(lowest, water or lowest) - RESOLUTION * 2
	local ceiling = math.max(highest, water or highest) + RESOLUTION
	local centre = Vector3.new(
		spec.centre.X,
		(floor + ceiling) * 0.5,
		spec.centre.Z)
	local region = aligned(centre,
		Vector3.new(spec.size.X, ceiling - floor, spec.size.Y))

	local size = region.Size / RESOLUTION
	local countX = math.floor(size.X + 0.5)
	local countY = math.floor(size.Y + 0.5)
	local countZ = math.floor(size.Z + 0.5)
	local regionFloor = region.CFrame.Position.Y - region.Size.Y * 0.5

	local materials = {}
	local occupancies = {}
	for i = 1, countX do
		materials[i] = {}
		occupancies[i] = {}
		local column = heights[math.clamp(i, 1, columns)]
		for j = 1, countY do
			materials[i][j] = {}
			occupancies[i][j] = {}
			local cellBottom = regionFloor + (j - 1) * RESOLUTION
			for k = 1, countZ do
				local surface = column[math.clamp(k, 1, rows)]
				-- The fraction is the whole trick: a cell straddling the
				-- surface is partly full, and that is what renders as a slope
				-- rather than a step.
				local fill = math.clamp((surface - cellBottom) / RESOLUTION, 0, 1)
				if fill > 0 then
					materials[i][j][k] = material
					occupancies[i][j][k] = fill
				elseif water ~= nil and cellBottom + RESOLUTION <= water then
					materials[i][j][k] = Enum.Material.Water
					occupancies[i][j][k] = 1
				else
					materials[i][j][k] = Enum.Material.Air
					occupancies[i][j][k] = 0
				end
			end
		end
	end

	local ok, err = pcall(function()
		Workspace.Terrain:WriteVoxels(region, RESOLUTION, materials, occupancies)
	end)
	if not ok then
		return receipt("heightfield", "failed", 0, region, { error = tostring(err) })
	end

	return receipt("heightfield", "ok", countX * countY * countZ, region, {
		columns = countX,
		rows = countZ,
		layers = countY,
		lowest = math.floor(lowest * 10) / 10,
		highest = math.floor(highest * 10) / 10,
		flattened = #zones,
		water = water,
		material = material.Name,
	})
end

--- Fill a box, ball, cylinder or wedge with one material.
function Land.fill(shape: string, bounds: Bounds, material: Enum.Material?): Receipt
	local kind = string.lower(shape)
	local fill = material or Enum.Material.Rock
	local terrain = Workspace.Terrain
	local frame = CFrame.new(bounds.centre)
	local region = aligned(bounds.centre, bounds.size)

	local ok, err = pcall(function()
		if kind == "ball" then
			terrain:FillBall(bounds.centre, math.max(bounds.size.X, 1) * 0.5, fill)
		elseif kind == "cylinder" then
			terrain:FillCylinder(frame, math.max(bounds.size.Y, 1),
				math.max(bounds.size.X, 1) * 0.5, fill)
		elseif kind == "wedge" then
			terrain:FillWedge(frame, bounds.size, fill)
		elseif kind == "box" then
			terrain:FillBlock(frame, bounds.size, fill)
		else
			error("fill shape must be box, ball, cylinder or wedge, got " .. shape, 0)
		end
	end)
	if not ok then
		return receipt("fill:" .. kind, "failed", 0, region, { error = tostring(err) })
	end
	return receipt("fill:" .. kind, "ok", 0, region, { material = fill.Name })
end

--- Cut terrain away. Carving is filling with Air, which is not obvious.
function Land.carve(shape: string, bounds: Bounds): Receipt
	local result = Land.fill(shape, bounds, Enum.Material.Air)
	result.operation = "carve:" .. string.lower(shape)
	return result
end

--- Repaint one material as another inside a region, leaving the shape alone.
---
--- The cheapest way to make ground read as two places: the same hills, grass on
--- one side of the ridge and sand on the other.
function Land.paint(bounds: Bounds, from: Enum.Material, to: Enum.Material): Receipt
	local region = aligned(bounds.centre, bounds.size)
	local ok, err = pcall(function()
		Workspace.Terrain:ReplaceMaterial(region, RESOLUTION, from, to)
	end)
	if not ok then
		return receipt("paint", "failed", 0, region, { error = tostring(err) })
	end
	return receipt("paint", "ok", 0, region, { from = from.Name, to = to.Name })
end

--- Tint a terrain material for the whole place.
---
--- Terrain materials have fixed textures and a settable colour, which is how a
--- terrain palette is made to agree with the token palette instead of shipping
--- Roblox's default green.
function Land.tint(material: Enum.Material, colour: Color3): boolean
	local ok = pcall(function()
		Workspace.Terrain:SetMaterialColor(material, colour)
	end)
	return ok
end

--- Water's look, which is four properties nobody remembers the names of.
function Land.water(settings: { [string]: any }): { [string]: any }
	local terrain = Workspace.Terrain
	local applied = {}
	for property, value in pairs(settings) do
		local ok = pcall(function()
			(terrain :: any)[property] = value
		end)
		applied[property] = ok
	end
	return applied
end

function Land.clear(): Receipt
	local extents = Workspace.Terrain.MaxExtents
	Workspace.Terrain:Clear()
	return receipt("clear", "ok", 0,
		Region3.new(extents.Min, extents.Max), {})
end

--- What is actually on the ground, so terrain can be judged without a picture.
---
--- **`MaxExtents` is not the size of the terrain.** It is the volume terrain is
--- *allowed* to occupy -- a constant 64000 studs cubed -- and reporting it as
--- the extent of the ground made a 512-stud island look like it filled the
--- world. Worse, a caller framing a camera on `Terrain` gets pulled back to
--- that nominal box and photographs a speck.
---
--- Roblox exposes no "what is filled" query, so this samples: a grid of
--- downward rays, counting what they land on. That is slower than reading a
--- property and it is the only answer that is true.
function Land.report(options: { [string]: any }?): { [string]: any }
	local opts = options or {}
	local reach = tonumber(opts.reach) or 512
	local step = math.max(tonumber(opts.step) or 32, RESOLUTION)
	local terrain = Workspace.Terrain

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { terrain }

	local land, water, empty = 0, 0, 0
	local lowest, highest = math.huge, -math.huge
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	local materials: { [string]: number } = {}

	for x = -reach, reach, step do
		for z = -reach, reach, step do
			local hit = Workspace:Raycast(
				Vector3.new(x, reach * 2, z), Vector3.new(0, -reach * 4, 0), params)
			if hit == nil then
				empty += 1
			else
				local name = hit.Material.Name
				materials[name] = (materials[name] or 0) + 1
				if hit.Material == Enum.Material.Water then
					water += 1
				else
					land += 1
				end
				lowest = math.min(lowest, hit.Position.Y)
				highest = math.max(highest, hit.Position.Y)
				minX, maxX = math.min(minX, x), math.max(maxX, x)
				minZ, maxZ = math.min(minZ, z), math.max(maxZ, z)
			end
		end
	end

	local found = land + water
	return {
		hasTerrain = found > 0,
		sampled = found + empty,
		land = land,
		water = water,
		empty = empty,
		materials = materials,
		-- The footprint that actually has ground under it, which is what a
		-- camera should frame and what a scatter should stay inside.
		footprint = if found > 0
			then { minX, minZ, maxX, maxZ } else nil,
		heightRange = if found > 0
			then { math.floor(lowest * 10) / 10, math.floor(highest * 10) / 10 }
			else nil,
		allowedVolume = "64000 studs cubed; not the size of your terrain",
		waterColor = { terrain.WaterColor.R, terrain.WaterColor.G, terrain.WaterColor.B },
		waterTransparency = terrain.WaterTransparency,
		resolution = RESOLUTION,
		sampleStep = step,
	}
end

return Land
