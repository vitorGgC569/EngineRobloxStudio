--!strict
-- World primitives that were missing: regions, navigation, spawn points, terrain.
--
-- Each one closes a question an agent could previously only answer by running
-- arbitrary Luau, which means the answer had no schema and nothing could check
-- it. Terrain in particular: `Fab.terrainBox` exists in the SDK and had no way
-- to reach a live place.

local PathfindingService = game:GetService("PathfindingService")
local Workspace = game:GetService("Workspace")

local Errors = require(script.Parent.Parent.Errors)
local History = require(script.Parent.Parent.History)
local Refs = require(script.Parent.Parent.Refs)
local Resolve = require(script.Parent.Parent.Resolve)
local Serialize = require(script.Parent.Parent.Serialize)

local TerrainCommands = {}

--- Terrain is a 4-stud voxel grid. Anything else is rounded to it, so the
--- caller is told what was actually written rather than what was asked for.
local VOXEL = 4

--- Bounded so a mistyped region cannot ask the plugin to write a cubic
--- kilometre and hang Studio until it is killed.
local MAX_VOXELS = 400000

local function vector(value: any, label: string): Vector3
	if type(value) ~= "table" or #value ~= 3 then
		Errors.raise("E_BAD_PARAMS", label .. " must be three numbers")
	end
	for _, component in ipairs(value) do
		if type(component) ~= "number" then
			Errors.raise("E_BAD_PARAMS", label .. " must be three numbers")
		end
	end
	return Vector3.new(value[1], value[2], value[3])
end

local function regionFrom(params: { [string]: any }): Region3
	local centre = vector(params.centre, "centre")
	local size = vector(params.size, "size")
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		Errors.raise("E_BAD_PARAMS", "size must be positive on every axis")
	end
	local half = size / 2
	return Region3.new(centre - half, centre + half)
end

--- world.region: everything inside a box, without walking the whole tree.
---
--- `GetPartBoundsInBox` rather than a descendant scan: on a real place the scan
--- is the difference between a millisecond and a stall, and it is what an agent
--- reaches for when it does not know this exists.
function TerrainCommands.region(params: { [string]: any }): any
	local centre = vector(params.centre, "centre")
	local size = vector(params.size, "size")
	local limit = math.clamp(tonumber(params.limit) or 200, 1, 2000)

	local overlapParams = OverlapParams.new()
	overlapParams.MaxParts = limit + 1
	if params.ignore ~= nil then
		local ignored: { Instance } = {}
		for _, path in ipairs(params.ignore) do
			table.insert(ignored, Resolve.instance(path))
		end
		overlapParams.FilterDescendantsInstances = ignored
		overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	end

	local parts = Workspace:GetPartBoundsInBox(CFrame.new(centre), size, overlapParams)
	local found: { any } = {}
	for index, part in ipairs(parts) do
		if index > limit then
			break
		end
		table.insert(found, {
			ref = Refs.of(part),
			name = part.Name,
			className = part.ClassName,
			path = part:GetFullName(),
			position = Serialize.roundVector(part.Position, 3),
			size = Serialize.roundVector(part.Size, 3),
		})
	end

	return {
		conclusive = true,
		centre = Serialize.roundVector(centre, 3),
		size = Serialize.roundVector(size, 3),
		parts = found,
		returned = #found,
		total = #parts,
		truncated = #parts > #found,
	}
end

--- world.spawn_points: where players actually arrive.
---
--- More than one enabled SpawnLocation without teams means arrival is random,
--- which is the kind of thing that makes a scenario flaky in a way nobody can
--- reproduce. Reported rather than judged.
function TerrainCommands.spawnPoints(_params: { [string]: any }): any
	local spawns: { any } = {}
	local enabled = 0
	local neutral = 0
	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant:IsA("SpawnLocation") then
			if descendant.Enabled then
				enabled += 1
			end
			if descendant.Neutral then
				neutral += 1
			end
			table.insert(spawns, {
				ref = Refs.of(descendant),
				name = descendant.Name,
				path = descendant:GetFullName(),
				position = Serialize.roundVector(descendant.Position, 3),
				enabled = descendant.Enabled,
				neutral = descendant.Neutral,
				duration = descendant.Duration,
				teamColor = tostring(descendant.TeamColor),
			})
		end
	end

	return {
		conclusive = true,
		spawns = spawns,
		count = #spawns,
		enabled = enabled,
		neutral = neutral,
		respawnLocation = if Workspace:FindFirstChildOfClass("SpawnLocation") ~= nil
			then "workspace"
			else nil,
		ambiguousArrival = enabled > 1 and neutral == enabled,
	}
end

--- world.navigation: the navmesh's own opinion, not a path query's side effect.
---
--- A path failing tells you nothing about why. This probes the mesh directly
--- with a control path across open ground, which separates "the destination is
--- unreachable" from "pathfinding is not working here at all".
function TerrainCommands.navigation(params: { [string]: any }): any
	local origin = if params.origin ~= nil then vector(params.origin, "origin") else nil

	if origin == nil then
		local spawn = Workspace:FindFirstChildOfClass("SpawnLocation")
		origin = if spawn ~= nil then spawn.Position + Vector3.new(0, 3, 0) else Vector3.new(0, 10, 0)
	end

	local agentRadius = tonumber(params.agentRadius) or 2
	local agentHeight = tonumber(params.agentHeight) or 5
	local path = PathfindingService:CreatePath({
		AgentRadius = agentRadius,
		AgentHeight = agentHeight,
		AgentCanJump = params.agentCanJump ~= false,
		WaypointSpacing = tonumber(params.waypointSpacing) or 4,
	})

	-- A short hop across open ground. If even this fails, the problem is the
	-- navmesh rather than the destination the caller cares about.
	local probeDistance = tonumber(params.probeDistance) or 12
	local ok, failure = pcall(function()
		path:ComputeAsync(origin, origin + Vector3.new(probeDistance, 0, 0))
	end)

	local status = if ok then tostring(path.Status) else "Error"
	local waypoints = if ok and path.Status == Enum.PathStatus.Success then #path:GetWaypoints() else 0

	return {
		conclusive = ok,
		navmeshResponsive = ok and path.Status == Enum.PathStatus.Success,
		controlProbe = {
			origin = Serialize.roundVector(origin, 3),
			distance = probeDistance,
			status = status,
			waypoints = waypoints,
		},
		agent = {
			radius = agentRadius,
			height = agentHeight,
			canJump = params.agentCanJump ~= false,
		},
		error = if ok then nil else tostring(failure),
	}
end

--- world.terrain: read the voxel grid, or write it.
---
--- `WriteVoxels` rather than a `FillBlock` loop: filling a large region one
--- block at a time is the documented way to make terrain generation too slow to
--- use.
function TerrainCommands.terrain(params: { [string]: any }): any
	local mode = params.mode or "read"
	local terrain = Workspace.Terrain

	if mode == "read" then
		if params.centre == nil then
			return {
				conclusive = true,
				mode = "summary",
				voxelSize = VOXEL,
				maxExtents = {
					min = Serialize.roundVector(terrain.MaxExtents.Min, 1),
					max = Serialize.roundVector(terrain.MaxExtents.Max, 1),
				},
				waterColor = Serialize.value(terrain.WaterColor),
				waterTransparency = terrain.WaterTransparency,
			}
		end
		local region = regionFrom(params):ExpandToGrid(VOXEL)
		local counts = region.Size / VOXEL
		local voxels = counts.X * counts.Y * counts.Z
		if voxels > MAX_VOXELS then
			Errors.raise("E_BAD_PARAMS", string.format(
				"that region is %d voxels, above the %d limit; read it in slices",
				voxels, MAX_VOXELS
			))
		end
		local materials, occupancies = terrain:ReadVoxels(region, VOXEL)
		local histogram: { [string]: number } = {}
		local filled = 0
		for x = 1, counts.X do
			for y = 1, counts.Y do
				for z = 1, counts.Z do
					local occupancy = occupancies[x][y][z]
					if occupancy > 0 then
						filled += 1
						local name = materials[x][y][z].Name
						histogram[name] = (histogram[name] or 0) + 1
					end
				end
			end
		end
		return {
			conclusive = true,
			mode = "read",
			voxelSize = VOXEL,
			region = {
				min = Serialize.roundVector(region.CFrame.Position - region.Size / 2, 1),
				size = Serialize.roundVector(region.Size, 1),
			},
			voxels = voxels,
			filled = filled,
			occupancy = Serialize.round(filled / math.max(voxels, 1), 4),
			materials = histogram,
		}
	end

	if mode ~= "write" and mode ~= "clear" then
		Errors.raise("E_BAD_PARAMS", 'mode must be "read", "write" or "clear"')
	end

	local region = regionFrom(params):ExpandToGrid(VOXEL)
	local counts = region.Size / VOXEL
	local voxels = counts.X * counts.Y * counts.Z
	if voxels > MAX_VOXELS then
		Errors.raise("E_BAD_PARAMS", string.format(
			"that region is %d voxels, above the %d limit", voxels, MAX_VOXELS
		))
	end

	local materialName = if mode == "clear" then "Air" else (params.material or "Grass")
	local material = (Enum.Material :: any)[materialName]
	if typeof(material) ~= "EnumItem" then
		Errors.raise("E_BAD_PARAMS", "unknown terrain material: " .. tostring(materialName))
	end
	local occupancy = if mode == "clear" then 0 else math.clamp(tonumber(params.occupancy) or 1, 0, 1)

	local materials = {}
	local occupancies = {}
	for x = 1, counts.X do
		materials[x] = {}
		occupancies[x] = {}
		for y = 1, counts.Y do
			materials[x][y] = {}
			occupancies[x][y] = {}
			for z = 1, counts.Z do
				materials[x][y][z] = material
				occupancies[x][y][z] = occupancy
			end
		end
	end

	terrain:WriteVoxels(region, VOXEL, materials, occupancies)

	return {
		conclusive = true,
		mode = mode,
		voxelSize = VOXEL,
		material = materialName,
		occupancy = occupancy,
		voxelsWritten = voxels,
		-- The caller asked for a box; the grid rounded it. Saying so stops the
		-- difference being discovered from a screenshot.
		requestedSize = Serialize.roundVector(vector(params.size, "size"), 3),
		snappedSize = Serialize.roundVector(region.Size, 3),
	}
end

local terrainImpl=TerrainCommands.terrain

TerrainCommands.terrain=function(params:{[string]:any}):any
	local mode=params.mode or "read"
	if mode=="write" or mode=="clear" then
		return History.record("RQE world.terrain "..mode,function()
			return terrainImpl(params)
		end)
	end
	return terrainImpl(params)
end

return TerrainCommands
