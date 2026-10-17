--!strict
-- Geometric measurement inside the real engine.
--
-- These are the commands that let a validator assert facts about the world from
-- measurement instead of from a hand-written fixture. Everything here is
-- deterministic: raycasts and bounding boxes, never computer vision.

local Config = require(script.Parent.Parent.Config)
local Errors = require(script.Parent.Parent.Errors)
local Navigation = require(script.Parent.Parent.Navigation)
local Refs = require(script.Parent.Parent.Refs)
local Resolve = require(script.Parent.Parent.Resolve)
local Serialize = require(script.Parent.Parent.Serialize)

local WorldCommands = {}

local function collectIgnored(paths: { string }?): { Instance }
	local ignored = {}
	if paths then
		for _, path in ipairs(paths) do
			-- Resolve raises. Swallowing that used to drop the exclude and
			-- still return a hit, which is a measurement of the wrong set.
			table.insert(ignored, Resolve.instance(path))
		end
	end
	return ignored
end

--- world.raycast: one ray, real engine, real collision geometry.
function WorldCommands.raycast(params: { [string]: any }): any
	local origin = Errors.expectVector(params, "origin")
	local direction = Errors.expectVector(params, "direction")

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = collectIgnored(params.ignore)
	raycastParams.IgnoreWater = params.ignoreWater == true

	local result = workspace:Raycast(origin, direction, raycastParams)
	if result == nil then
		return {
			hit = false,
			origin = Serialize.roundVector(origin),
			direction = Serialize.roundVector(direction),
		}
	end

	return {
		hit = true,
		origin = Serialize.roundVector(origin),
		direction = Serialize.roundVector(direction),
		instance = result.Instance:GetFullName(),
		className = result.Instance.ClassName,
		position = Serialize.roundVector(result.Position),
		normal = Serialize.roundVector(result.Normal),
		distance = Serialize.round(result.Distance),
		material = tostring(result.Material),
	}
end

--- world.bounds: the measured world-space extent of anything.
function WorldCommands.bounds(params: { [string]: any }): any
	local instance = Resolve.spatial(Errors.expect(params, "path", "string"))
	local cframe, size = Resolve.boundingBox(instance)
	local center = cframe.Position
	local half = size / 2

	local partCount = 0
	if instance:IsA("BasePart") then
		partCount = 1
	else
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("BasePart") then
				partCount += 1
			end
		end
	end

	return {
		path = instance:GetFullName(),
		className = instance.ClassName,
		center = Serialize.roundVector(center),
		size = Serialize.roundVector(size),
		min = Serialize.roundVector(center - half),
		max = Serialize.roundVector(center + half),
		volume = Serialize.round(size.X * size.Y * size.Z),
		partCount = partCount,
	}
end

--- world.ground_support: does this thing actually stand on something?
---
--- Samples a grid across the footprint and casts downward from just under the
--- bottom face. A gap larger than maxGap means the object floats; no hit at all
--- means there is nothing below it within maxDistance.
function WorldCommands.groundSupport(params: { [string]: any }): any
	local instance = Resolve.spatial(Errors.expect(params, "path", "string"))
	local requested = math.clamp(tonumber(params.samples) or 9, 1, 121)
	local maxGap = tonumber(params.maxGap) or 1.5
	local maxDistance = tonumber(params.maxDistance) or 200

	local cframe, size = Resolve.boundingBox(instance)
	local center = cframe.Position
	local half = size / 2
	local bottomY = center.Y - half.Y

	-- Square-ish grid across the footprint, inset so rays do not graze the edge.
	local perSide = math.max(1, math.floor(math.sqrt(requested) + 0.5))
	local inset = 0.9

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	local ignored = collectIgnored(params.ignore)
	table.insert(ignored, instance)
	raycastParams.FilterDescendantsInstances = ignored
	raycastParams.IgnoreWater = params.ignoreWater == true

	local samples = {}
	local unsupported = {}

	for xIndex = 1, perSide do
		for zIndex = 1, perSide do
			local xFraction = if perSide == 1 then 0.5 else (xIndex - 1) / (perSide - 1)
			local zFraction = if perSide == 1 then 0.5 else (zIndex - 1) / (perSide - 1)
			local offsetX = (xFraction - 0.5) * 2 * half.X * inset
			local offsetZ = (zFraction - 0.5) * 2 * half.Z * inset

			-- Start slightly above the bottom face so a part resting exactly on
			-- the floor is not reported as intersecting it.
			local origin = Vector3.new(center.X + offsetX, bottomY + 0.05, center.Z + offsetZ)
			local result = workspace:Raycast(origin, Vector3.new(0, -maxDistance, 0), raycastParams)

			local sample: { [string]: any } = {
				point = { xIndex, zIndex },
				origin = Serialize.roundVector(origin),
			}

			if result == nil then
				sample.supported = false
				sample.gap = nil
				sample.reason = "no_surface_within_" .. tostring(maxDistance) .. "_studs"
				table.insert(unsupported, sample)
			else
				local gap = math.max(0, origin.Y - result.Position.Y - 0.05)
				sample.supported = gap <= maxGap
				sample.gap = Serialize.round(gap)
				sample.surface = result.Instance:GetFullName()
				sample.material = tostring(result.Material)
				if not sample.supported then
					sample.reason = "gap_exceeds_max"
					table.insert(unsupported, sample)
				end
			end

			table.insert(samples, sample)
		end
	end

	local supportedCount = #samples - #unsupported
	return {
		path = instance:GetFullName(),
		sampledPoints = #samples,
		grid = { perSide, perSide },
		maxGap = maxGap,
		supportCoverage = Serialize.round(if #samples > 0 then supportedCount / #samples else 0),
		supported = #unsupported == 0,
		unsupportedPoints = unsupported,
		samples = samples,
		boundingBox = {
			center = Serialize.roundVector(center),
			size = Serialize.roundVector(size),
		},
	}
end

--- world.overlaps: which of these regions intersect each other?
---
--- Generic on purpose. Plots, zones, buildings and rooms are all "regions that
--- must not intersect"; this answers the question for any set of paths rather
--- than for one game's plot layout.
function WorldCommands.overlaps(params: { [string]: any }): any
	local paths = params.paths
	if typeof(paths) ~= "table" or #paths < 2 then
		Errors.raise(Errors.BAD_PARAMS, "world.overlaps needs a 'paths' array with at least two entries")
	end
	local tolerance = tonumber(params.tolerance) or 0

	local boxes = {}
	for _, path in ipairs(paths) do
		local instance = Resolve.spatial(path)
		local cframe, size = Resolve.boundingBox(instance)
		local half = size / 2
		table.insert(boxes, {
			instance = instance,
			path = instance:GetFullName(),
			ref = Refs.of(instance),
			min = cframe.Position - half,
			max = cframe.Position + half,
			size = size,
		})
	end

	local collisions = {}
	local skippedNested = 0
	for i = 1, #boxes do
		for j = i + 1, #boxes do
			local a = boxes[i]
			local b = boxes[j]

			-- A container always encloses its contents, and the same instance
			-- can be listed twice. Neither is an exclusivity violation.
			if a.instance == b.instance
				or a.instance:IsDescendantOf(b.instance)
				or b.instance:IsDescendantOf(a.instance)
			then
				skippedNested += 1
				continue
			end

			local overlapX = math.min(a.max.X, b.max.X) - math.max(a.min.X, b.min.X)
			local overlapY = math.min(a.max.Y, b.max.Y) - math.max(a.min.Y, b.min.Y)
			local overlapZ = math.min(a.max.Z, b.max.Z) - math.max(a.min.Z, b.min.Z)

			if overlapX > tolerance and overlapY > tolerance and overlapZ > tolerance then
				table.insert(collisions, {
					a = a.path,
					b = b.path,
					aRef = a.ref,
					bRef = b.ref,
					overlap = {
						Serialize.round(overlapX),
						Serialize.round(overlapY),
						Serialize.round(overlapZ),
					},
					overlapVolume = Serialize.round(overlapX * overlapY * overlapZ),
					-- The smallest push along an axis that separates the pair:
					-- an agent can act on this directly.
					minimumSeparation = Serialize.round(math.min(overlapX, overlapY, overlapZ)),
					separationAxis = if overlapX <= overlapY and overlapX <= overlapZ
						then "X"
						elseif overlapY <= overlapZ then "Y"
						else "Z",
				})
			end
		end
	end

	return {
		regions = #boxes,
		tolerance = tolerance,
		overlapping = #collisions,
		clean = #collisions == 0,
		skippedNestedPairs = skippedNested,
		collisions = collisions,
		boxes = (function()
			local serialized = {}
			for _, box in ipairs(boxes) do
				table.insert(serialized, {
					path = box.path,
					ref = box.ref,
					min = Serialize.roundVector(box.min),
					max = Serialize.roundVector(box.max),
					size = Serialize.roundVector(box.size),
				})
			end
			return serialized
		end)(),
	}
end

--- world.path: can a character actually get from A to B?
---
--- Uses the engine's own navigation mesh, so the answer accounts for collision
--- geometry a bounding-box check would miss entirely. A decorative disc rotated
--- into a wall looks fine in a hierarchy dump and returns NoPath here.
---
--- Includes a control probe: a short hop next to the origin. If the control
--- fails, the navmesh is unavailable and a NoPath verdict says nothing about
--- the level -- reporting it as a level defect would be a false accusation.
---
--- Targets are approached, not entered. An objective is a solid object and its
--- geometric centre is inside that solid, where no character can ever stand;
--- pathfinding to it always returns NoPath and would libel a perfectly
--- reachable shop counter. So candidate standing points around the object are
--- tried, and the one a character could actually occupy is used.
function WorldCommands.path(params: { [string]: any }): any
	local from: Vector3
	if params.from ~= nil then
		from = Errors.expectVector(params, "from")
	elseif params.fromPath ~= nil then
		local instance = Resolve.spatial(tostring(params.fromPath))
		local cframe = Resolve.boundingBox(instance)
		from = Navigation.standablePoint(cframe.Position) or cframe.Position
	else
		Errors.raise(Errors.BAD_PARAMS, "world.path needs 'from' or 'fromPath'")
		error("unreachable")
	end

	local targets = Navigation.targetsFrom(params, "to", "toPath")
	if #targets == 0 then
		Errors.raise(Errors.BAD_PARAMS, "world.path needs 'to' or 'toPath'")
	end

	local agent = Navigation.agentFrom(params)
	local navmeshUsable, controlStatus = Navigation.navmeshUsable(from, agent)
	local reachable, chosen, path, attempts = Navigation.firstReachable(from, targets, agent)

	local waypoints = {}
	if reachable and path ~= nil then
		for _, waypoint in ipairs(path:GetWaypoints()) do
			table.insert(waypoints, {
				position = Serialize.roundVector(waypoint.Position, 2),
				action = tostring(waypoint.Action),
			})
		end
	end

	local to = chosen.point
	return {
		reachable = reachable,
		status = if reachable then "Enum.PathStatus.Success" else (attempts[#attempts] and attempts[#attempts].status or "NoPath"),
		navmeshUsable = navmeshUsable,
		controlStatus = controlStatus,
		-- Only meaningful when the control passed.
		conclusive = navmeshUsable,
		from = Serialize.roundVector(from, 2),
		to = Serialize.roundVector(to, 2),
		approach = chosen.name,
		attempts = attempts,
		straightLineDistance = Serialize.round((to - from).Magnitude, 2),
		agent = agent,
		waypointCount = #waypoints,
		waypoints = waypoints,
	}
end

--- world.summary: cheap census of the place, for budgets and drift detection.
function WorldCommands.summary(_params: { [string]: any }): any
	local classCounts: { [string]: number } = {}
	local total = 0
	local parts = 0
	local unanchored = 0
	local scripts = 0
	local belowFloor = 0
	local floorY = -50

	for _, descendant in ipairs(workspace:GetDescendants()) do
		total += 1
		local className = descendant.ClassName
		classCounts[className] = (classCounts[className] or 0) + 1
		if descendant:IsA("BasePart") then
			parts += 1
			if not descendant.Anchored then
				unanchored += 1
			end
			if descendant.Position.Y < floorY then
				belowFloor += 1
			end
		elseif descendant:IsA("LuaSourceContainer") then
			scripts += 1
		end
		if total >= Config.MAX_TREE_NODES * 40 then
			break
		end
	end

	return {
		workspaceDescendants = total,
		parts = parts,
		unanchoredParts = unanchored,
		scripts = scripts,
		partsBelowY = { threshold = floorY, count = belowFloor },
		classCounts = classCounts,
	}
end

return WorldCommands
