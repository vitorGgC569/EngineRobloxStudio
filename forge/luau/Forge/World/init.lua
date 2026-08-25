--!strict
--[[
	World — terrain as a composable function, not a fixed generator.

	A heightfield here is a stack of layers you declare. Forge does not know
	what an island is; it knows how to add noise, ridges, basins and flats
	together and how to turn the result into voxels without freezing the server.

		local hf = World.heightfield({
			size = 1024,
			seed = 20260819,
			base = { { frequency = 0.0018, octaves = 4, weight = 0.60 },
			         { frequency = 0.0074, octaves = 5, weight = 0.32 },
			         { frequency = 0.0280, octaves = 3, weight = 0.08 } },
			range = { 4, 96 },
			falloff = { power = 2.7 },
			features = {
				{ kind = "ridge", center = Vector2.new(-320, 305), radius = 300, amount = 118, sharpness = 1.7 },
				{ kind = "basin", center = Vector2.new(255, -290), radius = 190, amount = 26 },
				{ kind = "flat",  center = Vector2.new(0, 0),      radius = 90,  height = 36, blend = 1.9 },
			},
		})

		World.paint(hf, {
			seaLevel = 20,
			material = function(x, z, height, slope) ... return Enum.Material.Grass end,
			onProgress = function(done, total) end,
		})

	The material function is where biomes live, and it is yours. Forge never
	ships a biome table, because a biome table is a game.
]]

local Workspace = game:GetService("Workspace")

local Rng = require(script.Parent.Core.Rng)
local Sched = require(script.Parent.Core.Sched)

local World = {}

local terrain = Workspace.Terrain

-- ============================== heightfield =================================
local Heightfield = {}
Heightfield.__index = Heightfield

export type FieldConfig = {
	size: number?,
	seed: number?,
	base: { { frequency: number, octaves: number?, weight: number?, persistence: number? } }?,
	range: { number }?, -- { minHeight, maxHeight } before features
	falloff: { power: number?, radius: number? }?, -- island edge; omit for infinite plane
	features: { any }?,
	floor: number?,
}

function World.heightfield(config: FieldConfig): any
	local cfg = config or {}
	local self = setmetatable({
		size = cfg.size or 1024,
		seed = cfg.seed or Rng.masterSeed(),
		base = cfg.base or { { frequency = 0.004, octaves = 4, weight = 1 } },
		range = cfg.range or { 4, 90 },
		falloff = cfg.falloff,
		features = cfg.features or {},
		floor = cfg.floor or 2,
		_cache = {},
		_cacheCount = 0,
	}, Heightfield)
	self.half = self.size / 2
	return self
end

function Heightfield:addFeature(feature: any)
	table.insert(self.features, feature)
	self:clearCache()
end

function Heightfield:clearCache()
	table.clear(self._cache)
	self._cacheCount = 0
end

function Heightfield:height(x: number, z: number): number
	local key = math.floor(x) * 8192 + math.floor(z)
	local cached = self._cache[key]
	if cached then
		return cached
	end

	local totalWeight = 0
	local value = 0
	for _, layer in self.base do
		local w = layer.weight or 1
		totalWeight += w
		value += Rng.fbm01(x, z, {
			frequency = layer.frequency,
			octaves = layer.octaves or 4,
			persistence = layer.persistence or 0.5,
			seed = self.seed,
		}) * w
	end
	if totalWeight > 0 then
		value /= totalWeight
	end

	local edge = 1
	if self.falloff then
		local radius = self.falloff.radius or self.half
		local d = math.sqrt(x * x + z * z) / radius
		edge = math.clamp(1 - d ^ (self.falloff.power or 2.5), 0, 1)
	end

	local y = self.range[1] + value * (self.range[2] - self.range[1]) * edge

	for _, feature in self.features do
		local dist = (Vector2.new(x, z) - feature.center).Magnitude
		if dist >= feature.radius then
			continue
		end
		local t = 1 - dist / feature.radius

		if feature.kind == "ridge" then
			-- ridged noise inside the falloff keeps peaks from looking like domes
			local ridge = Rng.ridge(x, z, { frequency = feature.frequency or 0.006, octaves = 4, seed = self.seed + 55 })
			y += (t ^ (feature.sharpness or 1.6)) * feature.amount * (0.65 + 0.35 * ridge) * edge
		elseif feature.kind == "basin" then
			y -= (t ^ (feature.sharpness or 1.6)) * feature.amount
		elseif feature.kind == "flat" then
			-- smoothstep blend so a plateau does not end in a cliff
			local blendRadius = feature.radius * (feature.blend or 1.5)
			local inner = feature.radius * 0.55
			local a = 1 - math.clamp((dist - inner) / math.max(blendRadius - inner, 1), 0, 1)
			local s = a * a * (3 - 2 * a)
			y = y + (feature.height - y) * s
		elseif feature.kind == "mound" then
			y += (t ^ (feature.sharpness or 2)) * feature.amount
		elseif feature.kind == "rim" then
			-- The inverse of a mound: ground rises toward the edge of the
			-- radius instead of the centre. This is how you get a bowl, a
			-- crater or an arena wall. Without it the obvious composition
			-- ("flat floor plus a mound") silently produces a hill, because a
			-- mound peaks where you wanted the floor.
			local inner = feature.inner or 0
			if dist > inner then
				local span = math.max(feature.radius - inner, 1)
				local u = math.clamp((dist - inner) / span, 0, 1)
				y += (u ^ (feature.sharpness or 2)) * feature.amount
			end
		end
	end

	y = math.max(y, self.floor)

	if self._cacheCount > 300000 then
		self:clearCache()
	end
	self._cache[key] = y
	self._cacheCount += 1
	return y
end

-- Surface normal's Y component by finite difference. 1 = flat, 0 = vertical.
function Heightfield:slope(x: number, z: number, epsilon: number?): number
	local e = epsilon or 6
	local hL, hR = self:height(x - e, z), self:height(x + e, z)
	local hD, hU = self:height(x, z - e), self:height(x, z + e)
	return Vector3.new(hL - hR, 2 * e, hD - hU).Unit.Y
end

function Heightfield:normal(x: number, z: number, epsilon: number?): Vector3
	local e = epsilon or 6
	local hL, hR = self:height(x - e, z), self:height(x + e, z)
	local hD, hU = self:height(x, z - e), self:height(x, z + e)
	return Vector3.new(hL - hR, 2 * e, hD - hU).Unit
end

function Heightfield:point(x: number, z: number, offsetY: number?): Vector3
	return Vector3.new(x, self:height(x, z) + (offsetY or 0), z)
end

-- ============================== voxel painting ==============================
export type PaintConfig = {
	seaLevel: number?,
	resolution: number?, -- must be a multiple of 4
	chunk: number?,
	material: ((x: number, z: number, height: number, slope: number) -> Enum.Material)?,
	waterMaterial: Enum.Material?,
	clear: boolean?,
	budgetMs: number?,
	onProgress: ((done: number, total: number) -> ())?,
	bounds: { min: Vector2, max: Vector2 }?,
}

--[[
	Writes the heightfield into Roblox terrain.

	Two details that matter and are easy to get wrong:

	1. Occupancy is a linear ramp across the surface voxel, not 0/1. Binary
	   occupancy produces visible stair-stepping on every slope in the game.

	2. Each chunk computes its own vertical extent. A flat meadow chunk writes
	   ten voxels of height instead of fifty, which is the difference between a
	   world that generates in eight seconds and one that generates in forty.
]]
function World.paint(field: any, config: PaintConfig?)
	local cfg = config or {}
	local res = cfg.resolution or 4
	assert(res % 4 == 0, "[World] resolution must be a multiple of 4")
	local chunkStuds = cfg.chunk or 64
	local seaLevel = cfg.seaLevel or -math.huge
	local waterMaterial = cfg.waterMaterial or Enum.Material.Water
	local materialFn = cfg.material or function()
		return Enum.Material.Grass
	end

	if cfg.clear then
		terrain:Clear()
	end

	local minX, maxX, minZ, maxZ
	if cfg.bounds then
		minX, maxX = cfg.bounds.min.X, cfg.bounds.max.X
		minZ, maxZ = cfg.bounds.min.Y, cfg.bounds.max.Y
	else
		minX, maxX = -field.half, field.half
		minZ, maxZ = -field.half, field.half
	end

	local chunksX = math.ceil((maxX - minX) / chunkStuds)
	local chunksZ = math.ceil((maxZ - minZ) / chunkStuds)
	local total = chunksX * chunksZ
	local done = 0
	local startClock = os.clock()
	local budget = (cfg.budgetMs or 8) / 1000

	for cx = 0, chunksX - 1 do
		for cz = 0, chunksZ - 1 do
			local x0 = minX + cx * chunkStuds
			local z0 = minZ + cz * chunkStuds
			local x1 = math.min(x0 + chunkStuds, maxX)
			local z1 = math.min(z0 + chunkStuds, maxZ)

			local cols = math.max(1, math.floor((x1 - x0) / res))
			local rows = math.max(1, math.floor((z1 - z0) / res))

			local heights = table.create(cols)
			local slopes = table.create(cols)
			local minH, maxH = math.huge, -math.huge
			for i = 1, cols do
				local wx = x0 + (i - 0.5) * res
				local hRow = table.create(rows)
				local sRow = table.create(rows)
				for j = 1, rows do
					local wz = z0 + (j - 0.5) * res
					local h = field:height(wx, wz)
					hRow[j] = h
					sRow[j] = field:slope(wx, wz)
					if h < minH then
						minH = h
					end
					if h > maxH then
						maxH = h
					end
				end
				heights[i] = hRow
				slopes[i] = sRow
			end

			local yLow = math.max(0, math.floor(minH) - 12)
			local yHigh = math.ceil(math.max(maxH, seaLevel == -math.huge and maxH or seaLevel) + res * 2)

			local region = Region3.new(Vector3.new(x0, yLow, z0), Vector3.new(x1, yHigh, z1)):ExpandToGrid(res)
			local dims = region.Size / res
			local nx, ny, nz = math.floor(dims.X), math.floor(dims.Y), math.floor(dims.Z)

			if nx > 0 and ny > 0 and nz > 0 then
				local origin = region.CFrame.Position - region.Size / 2
				local materials = table.create(nx)
				local occupancy = table.create(nx)

				for i = 1, nx do
					local wx = origin.X + (i - 0.5) * res
					local hi = math.clamp(i, 1, cols)
					local matCol = table.create(ny)
					local occCol = table.create(ny)
					for j = 1, ny do
						local wy = origin.Y + (j - 0.5) * res
						local matRow = table.create(nz)
						local occRow = table.create(nz)
						for kk = 1, nz do
							local ki = math.clamp(kk, 1, rows)
							local h = heights[hi][ki]
							local fill = math.clamp((h - (wy - res * 0.5)) / res, 0, 1)
							if fill > 0.02 then
								local wz = origin.Z + (kk - 0.5) * res
								matRow[kk] = materialFn(wx, wz, h, slopes[hi][ki])
								occRow[kk] = fill
							elseif wy < seaLevel then
								matRow[kk] = waterMaterial
								occRow[kk] = 1
							else
								matRow[kk] = Enum.Material.Air
								occRow[kk] = 0
							end
						end
						matCol[j] = matRow
						occCol[j] = occRow
					end
					materials[i] = matCol
					occupancy[i] = occCol
				end

				terrain:WriteVoxels(region, res, materials, occupancy)
			end

			done += 1
			if cfg.onProgress then
				cfg.onProgress(done, total)
			end
			if os.clock() - startClock > budget then
				task.wait()
				startClock = os.clock()
			end
		end
	end

	return { chunks = total, seconds = os.clock() - startClock }
end

-- ================================ scatter ===================================
--[[
	Places things on the surface with a density function.

		World.scatter(hf, {
			step = 13,
			budget = 1500,
			density = function(x, z, height, slope)
				if height < 22 or slope < 0.8 then return 0 end
				return 0.08
			end,
			place = function(position, stream) makeTree(position) end,
		})

	Deterministic for a given seed, because placement uses a per-cell stream.
	Regenerating the world puts the same tree in the same place.
]]
function World.scatter(field: any, config: any)
	local step = config.step or 12
	local budget = config.budget or 1000
	local jitter = config.jitter ~= false
	local place = assert(config.place, "[World] scatter needs a place function")
	local density = assert(config.density, "[World] scatter needs a density function")

	local minX = config.min and config.min.X or -field.half
	local maxX = config.max and config.max.X or field.half
	local minZ = config.min and config.min.Y or -field.half
	local maxZ = config.max and config.max.Y or field.half

	local placed = 0
	local startClock = os.clock()
	local budgetSeconds = (config.budgetMs or 4) / 1000

	for x = minX, maxX, step do
		for z = minZ, maxZ, step do
			if placed >= budget then
				return placed
			end
			local stream = Rng.at(config.id or "scatter", x, z)
			local px = jitter and x + stream:number(-step / 2, step / 2) or x
			local pz = jitter and z + stream:number(-step / 2, step / 2) or z

			local h = field:height(px, pz)
			local slope = field:slope(px, pz)
			local chance = density(px, pz, h, slope)
			if chance > 0 and stream:number() < chance then
				local ok, err = pcall(place, Vector3.new(px, h, pz), stream)
				if ok then
					placed += 1
				else
					warn("[World] scatter place failed: " .. tostring(err))
				end
			end
		end
		if os.clock() - startClock > budgetSeconds then
			task.wait()
			startClock = os.clock()
		end
	end
	return placed
end

-- ============================== surface queries =============================
-- The heightfield is the plan; this is the ground that actually exists. Use it
-- for anything that must stand on the world after it was written, because
-- voxel rounding means the two differ by up to half a voxel.
function World.surface(x: number, z: number, options: any?): Vector3?
	local opts = options or {}
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = opts.include or { terrain }
	params.IgnoreWater = opts.ignoreWater ~= false

	local from = Vector3.new(x, opts.from or 400, z)
	local result = Workspace:Raycast(from, Vector3.new(0, -(opts.distance or 600), 0), params)
	if result then
		return result.Position + Vector3.new(0, opts.offset or 0, 0)
	end
	return nil
end

-- Finds standable ground near a point: what a spawner should call instead of
-- trusting a heightfield value on a cliff face.
function World.findGround(around: Vector3, radius: number, options: any?): Vector3?
	local opts = options or {}
	local tries = opts.tries or 12
	local maxSlope = opts.maxSlope or 0.75
	local stream = opts.stream or Rng.stream("ground")

	for _ = 1, tries do
		local offset = stream:inDisc(radius)
		local x, z = around.X + offset.X, around.Z + offset.Y
		local point = World.surface(x, z, opts)
		if point then
			if opts.field then
				if opts.field:slope(x, z) >= maxSlope then
					return point + Vector3.new(0, opts.offset or 3, 0)
				end
			else
				return point + Vector3.new(0, opts.offset or 3, 0)
			end
		end
	end
	return nil
end

-- Flattens real terrain in a radius. For dropping a structure onto a world
-- that has already been written.
function World.level(center: Vector3, radius: number, height: number, material: Enum.Material?)
	local res = 4
	local region = Region3.new(
		Vector3.new(center.X - radius, height - 40, center.Z - radius),
		Vector3.new(center.X + radius, height + 40, center.Z + radius)
	):ExpandToGrid(res)

	local dims = region.Size / res
	local nx, ny, nz = math.floor(dims.X), math.floor(dims.Y), math.floor(dims.Z)
	local origin = region.CFrame.Position - region.Size / 2

	local materials, occupancy = table.create(nx), table.create(nx)
	for i = 1, nx do
		local wx = origin.X + (i - 0.5) * res
		local matCol, occCol = table.create(ny), table.create(ny)
		for j = 1, ny do
			local wy = origin.Y + (j - 0.5) * res
			local matRow, occRow = table.create(nz), table.create(nz)
			for kk = 1, nz do
				local wz = origin.Z + (kk - 0.5) * res
				local inside = Vector2.new(wx - center.X, wz - center.Z).Magnitude <= radius
				if inside and wy < height then
					matRow[kk] = material or Enum.Material.Ground
					occRow[kk] = math.clamp((height - (wy - res * 0.5)) / res, 0, 1)
				else
					matRow[kk] = Enum.Material.Air
					occRow[kk] = 0
				end
			end
			matCol[j] = matRow
			occCol[j] = occRow
		end
		materials[i] = matCol
		occupancy[i] = occCol
	end
	terrain:WriteVoxels(region, res, materials, occupancy)
end

function World.describe(field: any?): { [string]: any }
	-- `Terrain.MaxExtents` is a Region3int16: it has Min and Max, and no Size.
	-- Reading `.Size` errored on every snapshot until the seam surfaced it.
	-- Subtracting the two vectors directly then reported -1536 on every axis,
	-- because Vector3int16 arithmetic wraps at 16 bits. Pull the components out
	-- as plain numbers first.
	-- `Terrain.MaxExtents` is the engine's *allowed* region, not the occupied
	-- one, so it reports the same 256000-stud cube in an empty place and a full
	-- one. Useless as evidence. What actually answers "did the world generate"
	-- is whether rays find ground where the game expects it — the same
	-- technique the Quality Engine's `world.ground_support` uses.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { terrain }

	local samples, hits = 0, 0
	local probeRadius = field and field.half or 128
	for _, offset in { { 0, 0 }, { 0.5, 0 }, { 0, 0.5 }, { -0.5, 0 }, { 0, -0.5 }, { 0.35, 0.35 }, { -0.35, -0.35 } } do
		samples += 1
		local x = offset[1] * probeRadius
		local z = offset[2] * probeRadius
		local hit = Workspace:Raycast(Vector3.new(x, 500, z), Vector3.new(0, -900, 0), params)
		if hit then
			hits += 1
		end
	end

	local out: { [string]: any } = {
		groundSamples = samples,
		groundHits = hits,
		terrainPresent = hits > 0,
		workspaceParts = #Workspace:GetDescendants(),
	}
	if field then
		out.size = field.size
		out.seed = field.seed
		out.features = #field.features
		local samples = {}
		for _, p in { { 0, 0 }, { 100, 100 }, { -200, 150 }, { 300, -300 } } do
			table.insert(samples, { x = p[1], z = p[2], height = field:height(p[1], p[2]) })
		end
		out.samples = samples
	end
	return out
end


--[[
	Siblings, resolved on the first thing that asks for one.

	This family holds modules beside this file, and until now the only way to
	reach them was to require the instance directly — so `Forge.World.Areas`
	was nil while `require(ReplicatedStorage.Forge.World.Areas)` worked. Two
	conventions in one engine, and the inconsistency is the defect: the first
	game written against `Forge.Core.Boot` died on `attempt to index nil`.

	Lazy rather than eager, matching `Forge` itself. Touching one family must
	not drag in every module it contains — several of them build tables and
	open connections at load, and paying for all of that to read one constant
	is how a require graph becomes a frame budget.
]]
return setmetatable(World, {
	__index = function(self, key: string): any
		local child = script:FindFirstChild(key)
		if not child or not child:IsA("ModuleScript") then
			return nil
		end
		local module = require(child) :: any
		rawset(self, key, module)
		return module
	end,
})
