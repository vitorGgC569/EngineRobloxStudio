--!strict
-- Raw, policy-free visual quality measurement against the real DataModel.
--
-- The caller supplies classification names and landmark sampling geometry from
-- the versioned visual spec.  This module deliberately contains no acceptance
-- thresholds: it reports OBBs, area-weighted materials/colours and raycast
-- visibility so Python can apply independently versioned policy.

local CollectionService = game:GetService("CollectionService")

local Errors = require(script.Parent.Parent.Errors)
local Refs = require(script.Parent.Parent.Refs)
local Resolve = require(script.Parent.Parent.Resolve)
local Serialize = require(script.Parent.Parent.Serialize)

local QualityCommands = {}

local LIMIT_CEILINGS = {
	maxCandidates = 25000,
	maxRoots = 5000,
	maxRegions = 500,
	maxVisibilitySamples = 20000,
}

type Selector = {
	tag: string?,
	attributeEquals: { [string]: any }?,
	namePattern: string?,
}

type Bounds = {
	instance: Instance,
	cframe: CFrame,
	size: Vector3,
	ref: string,
	path: string,
	profile: string?,
}

type Destination = {
	instance: Instance,
	center: Vector3,
	cframe: CFrame?,
	size: Vector3?,
}

local function expectObject(parent: { [string]: any }, key: string, path: string): { [string]: any }
	local value = parent[key]
	if typeof(value) ~= "table" then
		Errors.raise(Errors.BAD_PARAMS, path .. "." .. key .. " must be an object")
	end
	return value :: { [string]: any }
end

local function expectString(parent: { [string]: any }, key: string, path: string): string
	local value = parent[key]
	if type(value) ~= "string" or value == "" then
		Errors.raise(Errors.BAD_PARAMS, path .. "." .. key .. " must be a non-empty string")
	end
	return value :: string
end

local function expectPositiveNumber(parent: { [string]: any }, key: string, path: string): number
	local value = parent[key]
	if type(value) ~= "number" or value <= 0 or value ~= value or value == math.huge then
		Errors.raise(Errors.BAD_PARAMS, path .. "." .. key .. " must be a finite positive number")
	end
	return value :: number
end

local function expectPositiveInteger(
	parent: { [string]: any },
	key: string,
	path: string,
	ceiling: number
): number
	local value = parent[key]
	if type(value) ~= "number" or value < 1 or value % 1 ~= 0 or value > ceiling then
		Errors.raise(
			Errors.BAD_PARAMS,
			string.format("%s.%s must be an integer from 1 through %d", path, key, ceiling)
		)
	end
	return value :: number
end

local function validateSelector(raw: any, path: string): Selector
	if typeof(raw) ~= "table" then
		Errors.raise(Errors.BAD_PARAMS, path .. " must be an object")
	end
	local selector = raw :: { [string]: any }
	local populated = false
	for key in pairs(selector) do
		if key ~= "tag" and key ~= "attributeEquals" and key ~= "namePattern" then
			Errors.raise(Errors.BAD_PARAMS, path .. "." .. tostring(key) .. " is not supported")
		end
	end
	if selector.tag ~= nil then
		expectString(selector, "tag", path)
		populated = true
	end
	if selector.attributeEquals ~= nil then
		if typeof(selector.attributeEquals) ~= "table" or next(selector.attributeEquals) == nil then
			Errors.raise(Errors.BAD_PARAMS, path .. ".attributeEquals must be a non-empty object")
		end
		for attribute, value in pairs(selector.attributeEquals) do
			if type(attribute) ~= "string" or attribute == "" then
				Errors.raise(Errors.BAD_PARAMS, path .. ".attributeEquals keys must be non-empty strings")
			end
			local valueType = type(value)
			if valueType ~= "string" and valueType ~= "number" and valueType ~= "boolean" then
				Errors.raise(
					Errors.BAD_PARAMS,
					path .. ".attributeEquals values must be strings, numbers or booleans"
				)
			end
		end
		populated = true
	end
	if selector.namePattern ~= nil then
		local pattern = expectString(selector, "namePattern", path)
		local valid = pcall(function()
			string.find("", pattern)
		end)
		if not valid then
			Errors.raise(Errors.BAD_PARAMS, path .. ".namePattern is not a valid Luau pattern")
		end
		populated = true
	end
	if not populated then
		Errors.raise(Errors.BAD_PARAMS, path .. " needs tag, attributeEquals or namePattern")
	end
	return selector :: Selector
end

local function matchesSelector(instance: Instance, selector: Selector): boolean
	if selector.tag ~= nil and not CollectionService:HasTag(instance, selector.tag) then
		return false
	end
	if selector.attributeEquals ~= nil then
		for attribute, expected in pairs(selector.attributeEquals) do
			if instance:GetAttribute(attribute) ~= expected then
				return false
			end
		end
	end
	if selector.namePattern ~= nil and string.find(instance.Name, selector.namePattern) == nil then
		return false
	end
	return true
end

local function sortedInstances(instances: { Instance }): { Instance }
	table.sort(instances, function(left, right)
		local leftPath = left:GetFullName()
		local rightPath = right:GetFullName()
		if leftPath == rightPath then
			return Refs.of(left) < Refs.of(right)
		end
		return leftPath < rightPath
	end)
	return instances
end

local function safeBounds(instance: Instance): (CFrame?, Vector3?)
	if not (
		instance:IsA("BasePart")
		or instance:IsA("Model")
		or instance:IsA("Folder")
		or instance:IsA("Workspace")
	) then
		return nil, nil
	end
	local ok, cframe, size = pcall(Resolve.boundingBox, instance)
	if not ok or typeof(cframe) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return nil, nil
	end
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		return nil, nil
	end
	return cframe, size
end

local function serializeObb(cframe: CFrame, size: Vector3): { [string]: any }
	return {
		center = Serialize.roundVector(cframe.Position),
		size = Serialize.roundVector(size),
		right = Serialize.roundVector(cframe.RightVector, 6),
		up = Serialize.roundVector(cframe.UpVector, 6),
		back = Serialize.roundVector(cframe.BackVector, 6),
	}
end

local function surfaceSummary(parts: { BasePart }): ({ any }, { any })
	local materialAreas: { [string]: number } = {}
	local colorAreas: { [string]: { rgb: { number }, area: number } } = {}
	for _, part in ipairs(parts) do
		local size = part.Size
		local area = 2 * (size.X * size.Y + size.X * size.Z + size.Y * size.Z)
		if area > 0 then
			local materialName = part.Material.Name
			materialAreas[materialName] = (materialAreas[materialName] or 0) + area
			local rgb = {
				math.round(part.Color.R * 255),
				math.round(part.Color.G * 255),
				math.round(part.Color.B * 255),
			}
			local key = table.concat(rgb, ",")
			local existing = colorAreas[key]
			if existing == nil then
				colorAreas[key] = { rgb = rgb, area = area }
			else
				existing.area += area
			end
		end
	end

	local materials = {}
	local materialNames = {}
	for name in pairs(materialAreas) do
		table.insert(materialNames, name)
	end
	table.sort(materialNames)
	for _, name in ipairs(materialNames) do
		table.insert(materials, {
			name = name,
			surfaceArea = Serialize.round(materialAreas[name], 4),
		})
	end

	local colors = {}
	local colorKeys = {}
	for key in pairs(colorAreas) do
		table.insert(colorKeys, key)
	end
	table.sort(colorKeys)
	for _, key in ipairs(colorKeys) do
		local row = colorAreas[key]
		table.insert(colors, {
			rgb = row.rgb,
			surfaceArea = Serialize.round(row.area, 4),
		})
	end
	return materials, colors
end

local function horizontalDistance(first: Vector3, second: Vector3): number
	local dx = first.X - second.X
	local dz = first.Z - second.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function halton(index: number, base: number): number
	local fraction = 1
	local result = 0
	local remaining = index
	while remaining > 0 do
		fraction /= base
		result += fraction * (remaining % base)
		remaining = math.floor(remaining / base)
	end
	return result
end

local function aimPoint(target: Destination, rayIndex: number): Vector3
	if rayIndex == 1 or target.cframe == nil or target.size == nil then
		return target.center
	end
	local index = rayIndex - 1
	local offset = Vector3.new(
		(halton(index, 2) - 0.5) * (target.size :: Vector3).X * 0.9,
		(halton(index, 3) - 0.5) * (target.size :: Vector3).Y * 0.9,
		(halton(index, 5) - 0.5) * (target.size :: Vector3).Z * 0.9
	)
	return (target.cframe :: CFrame):PointToWorldSpace(offset)
end

local function isDestination(instance: Instance, targets: { Destination }): boolean
	for _, target in ipairs(targets) do
		if instance == target.instance
			or instance:IsDescendantOf(target.instance)
			or target.instance:IsDescendantOf(instance)
		then
			return true
		end
	end
	return false
end

local function orderedDestinations(origin: Vector3, targets: { Destination }): { Destination }
	local ordered = table.clone(targets)
	table.sort(ordered, function(left, right)
		local leftDistance = (left.center - origin).Magnitude
		local rightDistance = (right.center - origin).Magnitude
		if leftDistance == rightDistance then
			return Refs.of(left.instance) < Refs.of(right.instance)
		end
		return leftDistance < rightDistance
	end)
	return ordered
end

local function observationVisible(
	origin: Vector3,
	ignored: { Instance },
	targets: { Destination },
	maximumDistance: number,
	raysPerAnchor: number,
	consumeRay: () -> boolean
): (boolean, boolean)
	local ordered = orderedDestinations(origin, targets)

	for rayIndex = 1, raysPerAnchor do
		local targetIndex = ((rayIndex - 1) % #ordered) + 1
		local pass = math.floor((rayIndex - 1) / #ordered) + 1
		local destination = aimPoint(ordered[targetIndex], pass)
		local direction = destination - origin
		local distance = direction.Magnitude
		if distance > 0 and distance <= maximumDistance then
			local rayIgnored = table.clone(ignored)
			for _ = 1, 16 do
				if not consumeRay() then
					return false, true
				end
				local raycastParams = RaycastParams.new()
				raycastParams.FilterType = Enum.RaycastFilterType.Exclude
				raycastParams.FilterDescendantsInstances = rayIgnored
				raycastParams.IgnoreWater = false
				local hit = workspace:Raycast(origin, direction, raycastParams)
				-- A nil hit means no queryable geometry occluded the target point. It
				-- also handles visible landmark meshes with CanQuery disabled.
				if hit == nil or isDestination(hit.Instance, targets) then
					return true, false
				end
				-- Fully transparent query geometry is not a visual occluder. Pierce it
				-- deterministically instead of reporting a false blind spot.
				if hit.Instance:IsA("BasePart") and hit.Instance.Transparency >= 0.999 then
					table.insert(rayIgnored, hit.Instance)
					if #rayIgnored - #ignored >= 16 then
						return false, true
					end
				else
					break
				end
			end
		end
	end
	return false, false
end

local function maximumCircularGap(angles: { number }): number
	if #angles <= 1 then
		return 360
	end
	table.sort(angles)
	local maximum = 0
	for index = 1, #angles - 1 do
		maximum = math.max(maximum, angles[index + 1] - angles[index])
	end
	maximum = math.max(maximum, angles[1] + 360 - angles[#angles])
	return Serialize.round(maximum, 3)
end

local function angleFrom(target: Vector3, anchor: Vector3): number
	local angle = math.deg(math.atan2(anchor.Z - target.Z, anchor.X - target.X))
	return if angle < 0 then angle + 360 else angle
end

local function boundedTagged(tag: string, maximum: number): ({ Instance }, boolean)
	local instances = sortedInstances(CollectionService:GetTagged(tag))
	if #instances <= maximum then
		return instances, false
	end
	local bounded = {}
	for index = 1, maximum do
		table.insert(bounded, instances[index])
	end
	return bounded, true
end

local function hasTagInAncestry(instance: Instance, tag: string): boolean
	local current: Instance? = instance
	while current ~= nil and current ~= workspace.Parent do
		if CollectionService:HasTag(current, tag) then
			return true
		end
		if current == workspace then
			break
		end
		current = current.Parent
	end
	return false
end

local function visualParts(excludeTag: string, maximum: number): ({ BasePart }, number, boolean)
	local included: { BasePart } = {}
	local excluded = 0
	local candidates: { BasePart } = {}
	for _, instance in ipairs(workspace:GetDescendants()) do
		if instance:IsA("BasePart") and (instance.Transparency < 1 or instance.CanQuery) then
			table.insert(candidates, instance)
		end
	end
	table.sort(candidates, function(left, right)
		local leftPath = left:GetFullName()
		local rightPath = right:GetFullName()
		if leftPath == rightPath then
			return Refs.of(left) < Refs.of(right)
		end
		return leftPath < rightPath
	end)
	local truncated = #candidates > maximum
	for index = 1, math.min(#candidates, maximum) do
		local part = candidates[index]
		if hasTagInAncestry(part, excludeTag) then
			excluded += 1
		else
			table.insert(included, part)
		end
	end
	return included, excluded, truncated
end


local function rootPool(rootTag: string, candidateTag: string, maximumCandidates: number): ({ Instance }, boolean)
	local unique: { [Instance]: boolean } = {}
	local roots: { Instance } = {}
	-- Explicit roots take precedence when the combined discovery budget is hit;
	-- candidateTag is only a fallback way to define a root.
	for _, tag in ipairs({ rootTag, candidateTag }) do
		local tagged = sortedInstances(CollectionService:GetTagged(tag))
		for _, instance in ipairs(tagged) do
			if instance:IsDescendantOf(workspace) and not unique[instance] then
				unique[instance] = true
				table.insert(roots, instance)
			end
		end
	end
	if #roots <= maximumCandidates then
		return roots, false
	end
	local bounded = {}
	for index = 1, maximumCandidates do
		table.insert(bounded, roots[index])
	end
	return bounded, true
end

local function nearestRoot(part: BasePart, roots: { [Instance]: Bounds }): Bounds?
	local current: Instance? = part
	while current ~= nil and current ~= workspace.Parent do
		local root = roots[current]
		if root ~= nil then
			return root
		end
		if current == workspace then
			break
		end
		current = current.Parent
	end
	return nil
end

local function destinationFor(instance: Instance): Destination?
	if instance:IsA("Attachment") then
		return {
			instance = instance,
			center = instance.WorldPosition,
			cframe = nil,
			size = nil,
		}
	end
	local cframe, size = safeBounds(instance)
	if cframe == nil or size == nil then
		return nil
	end
	return {
		instance = instance,
		center = cframe.Position,
		cframe = cframe,
		size = size,
	}
end

local function nearestDestinationDistance(point: Vector3, destinations: { Destination }): number
	local distance = math.huge
	for _, destination in ipairs(destinations) do
		distance = math.min(distance, horizontalDistance(point, destination.center))
	end
	return distance
end

local function regionGrid(region: Bounds, spacing: number, maximum: number): ({ Vector3 }, boolean)
	local xCount = math.max(1, math.ceil(region.size.X / spacing))
	local zCount = math.max(1, math.ceil(region.size.Z / spacing))
	local total = xCount * zCount
	local points = {}
	-- A low-discrepancy traversal avoids concentrating a truncated run in one
	-- corner while preserving a spacing-derived, deterministic sample count.
	for index = 1, math.min(total, maximum) do
		local localX = (halton(index, 2) - 0.5) * region.size.X
		local localZ = (halton(index, 3) - 0.5) * region.size.Z
		local plane = region.cframe:PointToWorldSpace(Vector3.new(localX, 0, localZ))
		table.insert(points, plane)
	end
	return points, total > maximum
end

local function playableSurface(
	region: Bounds,
	plane: Vector3,
	consumeRay: () -> boolean
): (Vector3?, boolean)
	local top = region.cframe.Position.Y + region.size.Y / 2 + 64
	local remaining = region.size.Y + 320
	local origin = Vector3.new(plane.X, top, plane.Z)
	local ignored = {}
	if region.instance:IsA("BasePart")
		and (region.instance.Transparency >= 0.999 or not region.instance.CanCollide)
	then
		table.insert(ignored, region.instance)
	end
	for attempt = 1, 16 do
		if not consumeRay() then
			return nil, true
		end
		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude
		raycastParams.FilterDescendantsInstances = ignored
		raycastParams.IgnoreWater = false
		local hit = workspace:Raycast(origin, Vector3.new(0, -remaining, 0), raycastParams)
		if hit == nil then
			return nil, false
		end
		local surface = hit.Instance
		local playable = surface:IsA("Terrain")
			or (surface:IsA("BasePart") and surface.CanCollide and hit.Normal.Y > 0)
		if playable then
			return hit.Position, false
		end
		table.insert(ignored, surface)
		local travelled = math.max(0.01, (origin - hit.Position).Magnitude + 0.01)
		remaining -= travelled
		if remaining <= 0 then
			return nil, false
		end
		origin = hit.Position - Vector3.new(0, 0.01, 0)
		if attempt == 16 then
			return nil, true
		end
	end
	return nil, true
end

local function boundsFor(instance: Instance, profile: string?): Bounds?
	local cframe, size = safeBounds(instance)
	if cframe == nil or size == nil then
		return nil
	end
	return {
		instance = instance,
		cframe = cframe,
		size = size,
		ref = Refs.of(instance),
		path = instance:GetFullName(),
		profile = profile,
	}
end

--- quality.snapshot: raw geometry and visibility facts for the quality engine.
function QualityCommands.snapshot(params: { [string]: any }): any
	local classification = expectObject(params, "classification", "params")
	local classificationKeys = {
		"candidateTag",
		"rootTag",
		"typeAttribute",
		"variantAttribute",
		"assetKeyAttribute",
		"regionTag",
		"regionProfileAttribute",
		"landmarkTag",
		"landmarkAnchorTag",
		"excludeTag",
	}
	local classificationValues: { [string]: string } = {}
	for _, key in ipairs(classificationKeys) do
		classificationValues[key] = expectString(classification, key, "params.classification")
	end
	for key in pairs(classification) do
		if classificationValues[key] == nil then
			Errors.raise(Errors.BAD_PARAMS, "params.classification." .. tostring(key) .. " is not supported")
		end
	end

	local limitsRaw = expectObject(params, "limits", "params")
	local limits = {
		maxCandidates = expectPositiveInteger(
			limitsRaw,
			"maxCandidates",
			"params.limits",
			LIMIT_CEILINGS.maxCandidates
		),
		maxRoots = expectPositiveInteger(limitsRaw, "maxRoots", "params.limits", LIMIT_CEILINGS.maxRoots),
		maxRegions = expectPositiveInteger(limitsRaw, "maxRegions", "params.limits", LIMIT_CEILINGS.maxRegions),
		maxVisibilitySamples = expectPositiveInteger(
			limitsRaw,
			"maxVisibilitySamples",
			"params.limits",
			LIMIT_CEILINGS.maxVisibilitySamples
		),
	}
	for key in pairs(limitsRaw) do
		if limits[key] == nil then
			Errors.raise(Errors.BAD_PARAMS, "params.limits." .. tostring(key) .. " is not supported")
		end
	end

	local landmarkRows = params.landmarks
	if typeof(landmarkRows) ~= "table" or #landmarkRows < 1 or #landmarkRows > 64 then
		Errors.raise(Errors.BAD_PARAMS, "params.landmarks must contain from 1 through 64 entries")
	end
	local landmarks = {}
	local landmarkIds: { [string]: boolean } = {}
	for index, raw in ipairs(landmarkRows) do
		local path = "params.landmarks[" .. tostring(index) .. "]"
		if typeof(raw) ~= "table" then
			Errors.raise(Errors.BAD_PARAMS, path .. " must be an object")
		end
		local row = raw :: { [string]: any }
		local id = expectString(row, "id", path)
		if landmarkIds[id] then
			Errors.raise(Errors.BAD_PARAMS, path .. ".id must be unique")
		end
		landmarkIds[id] = true
		local landmark = {
			id = id,
			selector = validateSelector(row.selector, path .. ".selector"),
			anchorSelector = validateSelector(row.anchorSelector, path .. ".anchorSelector"),
			maximumDistance = expectPositiveNumber(row, "maximumDistance", path),
			sampleSpacing = expectPositiveNumber(row, "sampleSpacing", path),
			eyeHeight = expectPositiveNumber(row, "eyeHeight", path),
			raysPerAnchor = expectPositiveInteger(row, "raysPerAnchor", path, 64),
		}
		if landmark.sampleSpacing < 0.000001 then
			Errors.raise(Errors.BAD_PARAMS, path .. ".sampleSpacing must be at least 0.000001")
		end
		for key in pairs(row) do
			if landmark[key] == nil then
				Errors.raise(Errors.BAD_PARAMS, path .. "." .. tostring(key) .. " is not supported")
			end
		end
		table.insert(landmarks, landmark)
	end

	local truncated = false
	local eligibleParts, excluded, candidatesTruncated = visualParts(
		classificationValues.excludeTag,
		limits.maxCandidates
	)
	truncated = truncated or candidatesTruncated
	local eligible = #eligibleParts

	-- A game's candidate tag may help identify semantic roots, but it never
	-- defines the eligible universe.  Every visible/queryable Workspace part is
	-- counted above, then classified only when self/ancestor binds to a valid
	-- root.  This prevents a game from obtaining perfect coverage by tagging
	-- only the few objects it wants the validator to see.
	local rootInstances, rootsTruncated = rootPool(
		classificationValues.rootTag,
		classificationValues.candidateTag,
		limits.maxCandidates
	)
	truncated = truncated or rootsTruncated
	local rootBoundsByInstance: { [Instance]: Bounds } = {}
	local rootMetadata: { [Instance]: { [string]: any } } = {}
	local validRootCount = 0
	for _, instance in ipairs(rootInstances) do
		if hasTagInAncestry(instance, classificationValues.excludeTag) then
			continue
		end
		local visualType = instance:GetAttribute(classificationValues.typeAttribute)
		local variant = instance:GetAttribute(classificationValues.variantAttribute)
		if type(visualType) ~= "string" or visualType == "" or type(variant) ~= "string" or variant == "" then
			continue
		end
		local bounds = boundsFor(instance, nil)
		if bounds == nil then
			continue
		end
		if validRootCount >= limits.maxRoots then
			truncated = true
			continue
		end
		rootBoundsByInstance[instance] = bounds
		validRootCount += 1
		rootMetadata[instance] = { visualType = visualType, variant = variant }
		local assetKey = instance:GetAttribute(classificationValues.assetKeyAttribute)
		if type(assetKey) == "string" and assetKey ~= "" then
			rootMetadata[instance].assetKey = assetKey
		end
	end

	local classified = 0
	local ownedParts: { [Instance]: { BasePart } } = {}
	for _, part in ipairs(eligibleParts) do
		local root = nearestRoot(part, rootBoundsByInstance)
		if root ~= nil then
			classified += 1
			local parts = ownedParts[root.instance]
			if parts == nil then
				parts = {}
				ownedParts[root.instance] = parts
			end
			table.insert(parts, part)
		end
	end

	local roots = {}
	for _, instance in ipairs(rootInstances) do
		local bounds = rootBoundsByInstance[instance]
		local metadata = rootMetadata[instance]
		local parts = ownedParts[instance]
		if bounds == nil or metadata == nil or parts == nil or #parts == 0 then
			continue
		end
		local materials, colors = surfaceSummary(parts)
		local root = {
			ref = bounds.ref,
			path = bounds.path,
			type = metadata.visualType,
			variant = metadata.variant,
			obb = serializeObb(bounds.cframe, bounds.size),
			materials = materials,
			colors = colors,
		}
		if metadata.assetKey ~= nil then
			root.assetKey = metadata.assetKey
		end
		table.insert(roots, root)
	end

	local regionOutputs = {}
	local regionBounds: { Bounds } = {}
	local taggedRegions, regionsTruncated = boundedTagged(
		classificationValues.regionTag,
		limits.maxRegions
	)
	truncated = truncated or regionsTruncated
	for _, instance in ipairs(taggedRegions) do
		local profile = instance:GetAttribute(classificationValues.regionProfileAttribute)
		if type(profile) ~= "string" or profile == "" then
			continue
		end
		local bounds = boundsFor(instance, profile)
		if bounds == nil then
			continue
		end
		table.insert(regionBounds, bounds)
		table.insert(regionOutputs, {
			ref = bounds.ref,
			path = bounds.path,
			profile = profile,
			obb = serializeObb(bounds.cframe, bounds.size),
		})
	end

	local broadTargets, targetsTruncated = boundedTagged(
		classificationValues.landmarkTag,
		limits.maxCandidates
	)
	local broadAnchors, anchorsTruncated = boundedTagged(
		classificationValues.landmarkAnchorTag,
		limits.maxCandidates
	)
	truncated = truncated or targetsTruncated or anchorsTruncated
	local visibility = {}
	local rayBudgetUsed = 0
	local function consumeRay(): boolean
		if rayBudgetUsed >= limits.maxVisibilitySamples then
			return false
		end
		rayBudgetUsed += 1
		return true
	end

	for _, landmark in ipairs(landmarks) do
		local destinations: { Destination } = {}
		local seenDestinations: { [Instance]: boolean } = {}
		for _, instance in ipairs(broadTargets) do
			if matchesSelector(instance, landmark.selector) then
				local destination = destinationFor(instance)
				if destination ~= nil and not seenDestinations[instance] then
					seenDestinations[instance] = true
					table.insert(destinations, destination)
				end
			end
		end
		for _, instance in ipairs(broadAnchors) do
			if matchesSelector(instance, landmark.anchorSelector) then
				local destination = destinationFor(instance)
				if destination ~= nil and not seenDestinations[instance] then
					seenDestinations[instance] = true
					table.insert(destinations, destination)
				end
			end
		end
		if #destinations == 0 then
			continue
		end
		local referenceCenter = Vector3.zero
		for _, destination in ipairs(destinations) do
			referenceCenter += destination.center
		end
		referenceCenter /= #destinations

		for _, region in ipairs(regionBounds) do
			local sampled = 0
			local visible = 0
			local visibleAngles = {}
			local conclusive = true
			local grid, gridTruncated = regionGrid(
				region,
				landmark.sampleSpacing,
				limits.maxVisibilitySamples
			)
			if gridTruncated then
				truncated = true
				conclusive = false
			end
			for _, plane in ipairs(grid) do
				if nearestDestinationDistance(plane, destinations) > landmark.maximumDistance then
					continue
				end
				local surface, groundTruncated = playableSurface(region, plane, consumeRay)
				if groundTruncated then
					truncated = true
					conclusive = false
					break
				end
				if surface == nil then
					continue
				end
				local origin = surface + Vector3.new(0, landmark.eyeHeight, 0)
				local ignored = {}
				if region.instance:IsA("BasePart")
					and (region.instance.Transparency >= 0.999 or not region.instance.CanCollide)
				then
					table.insert(ignored, region.instance)
				end
				local isVisible, visibilityTruncated = observationVisible(
					origin,
					ignored,
					destinations,
					landmark.maximumDistance,
					landmark.raysPerAnchor,
					consumeRay
				)
				if visibilityTruncated then
					truncated = true
					conclusive = false
					break
				end
				sampled += 1
				if isVisible then
					visible += 1
					table.insert(visibleAngles, angleFrom(referenceCenter, surface))
				end
			end
			if sampled > 0 then
				table.insert(visibility, {
					landmarkId = landmark.id,
					regionRef = region.ref,
					sampled = sampled,
					visible = visible,
					visibleFraction = Serialize.round(visible / sampled, 6),
					maximumBlindSpotDegrees = maximumCircularGap(visibleAngles),
					conclusive = conclusive,
				})
			end
		end
	end

	return {
		schemaVersion = 1,
		capturedAt = DateTime.now():ToIsoDate(),
		truncated = truncated,
		classification = {
			eligible = eligible,
			classified = classified,
			excluded = excluded,
		},
		roots = roots,
		regions = regionOutputs,
		visibility = visibility,
	}
end

return QualityCommands
