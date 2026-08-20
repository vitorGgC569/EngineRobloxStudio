--!strict
-- L4: blockout grammar.
--
-- Greybox first. Build the level from simple shapes, prove it plays, and only
-- then spend anything on art -- the pipeline Roblox's own environmental-art
-- curriculum teaches, and the one this project skipped the first time round. The
-- cost of skipping it was visible: layout defects and art defects arrived
-- together in the same findings list, so neither could be fixed without
-- re-litigating the other.
--
-- A blockout is a declaration, not a build script:
--
--   regions      -- named areas with a footprint and a purpose
--   circulation  -- which regions connect to which, and how wide the route is
--   landmarks    -- what must be visible, from where, and how tall it has to be
--   sightlines   -- lines that must stay clear
--
-- `validate` answers the expensive questions **before** a single part exists:
-- do regions overlap, is every region reachable from spawn, is any corridor
-- narrower than a character can walk, is a landmark too short to see from the
-- place it is supposed to orient. Those are graph and arithmetic questions.
-- Discovering them from a pathfinding failure in a live session costs a whole
-- measurement run; discovering them here costs nothing.

local Build = require(script.Parent.Build)
local Semantics = require(script.Parent.Semantics)
local Tokens = require(script.Parent.Tokens)

local Blockout = {}

export type Region = {
	id: string,
	--- Free-form purpose used for validation policy and later dressing.
	kind: string,
	centre: Vector3,
	--- Footprint on the ground plane. Height is implied by the region kind.
	size: Vector2,
	--- Regions a player starts in. Exactly one region must set this.
	spawn: boolean?,
	elevation: number?,
}

export type Route = {
	from: string,
	to: string,
	width: number?,
}

export type Landmark = {
	id: string,
	at: Vector3,
	height: number,
	--- Regions that must be able to see this landmark.
	visibleFrom: { string },
}

export type Sightline = {
	from: string,
	to: string,
}

export type Spec = {
	id: string,
	regions: { Region },
	circulation: { Route },
	landmarks: { Landmark }?,
	sightlines: { Sightline }?,
}

export type BuildResult = {
	root: Folder,
	regions: { [string]: Model },
	routes: number,
	landmarks: number,
	--- Ground-plane area actually covered, for density rules downstream.
	coveredArea: number,
}

local function regionMin(region: Region): Vector2
	return Vector2.new(region.centre.X - region.size.X / 2, region.centre.Z - region.size.Y / 2)
end

local function regionMax(region: Region): Vector2
	return Vector2.new(region.centre.X + region.size.X / 2, region.centre.Z + region.size.Y / 2)
end

local function overlapArea(a: Region, b: Region): number
	local aMin, aMax = regionMin(a), regionMax(a)
	local bMin, bMax = regionMin(b), regionMax(b)
	local x = math.min(aMax.X, bMax.X) - math.max(aMin.X, bMin.X)
	local y = math.min(aMax.Y, bMax.Y) - math.max(aMin.Y, bMin.Y)
	if x <= 0 or y <= 0 then
		return 0
	end
	return x * y
end

--- Shortest distance from a point to a region's footprint, zero when inside.
local function distanceToRegion(point: Vector3, region: Region): number
	local low, high = regionMin(region), regionMax(region)
	local dx = math.max(low.X - point.X, 0, point.X - high.X)
	local dz = math.max(low.Y - point.Z, 0, point.Z - high.Y)
	local dy = math.abs(point.Y - (region.centre.Y + (region.elevation or 0)))
	return math.sqrt(dx * dx + dz * dz + dy * dy)
end

--- Everything wrong with a blockout, before anything is built from it.
function Blockout.validate(spec: Spec, tokens: Tokens.TokenSet): { string }
	local problems: { string } = {}

	if type(spec.id) ~= "string" or spec.id == "" then
		table.insert(problems, "blockout id must be a non-empty string")
	end
	if type(spec.regions) ~= "table" or #spec.regions == 0 then
		table.insert(problems, "blockout must declare at least one region")
		return problems
	end

	local byId: { [string]: Region } = {}
	local spawnRegions: { string } = {}
	local minimumDimension = tokens:grammar("roomMinDimension")

	for index, region in ipairs(spec.regions) do
		local label = string.format("regions[%d]", index)
		if type(region.id) ~= "string" or region.id == "" then
			table.insert(problems, label .. " must have an id")
			continue
		end
		if byId[region.id] ~= nil then
			table.insert(problems, string.format("region id %q is declared twice", region.id))
			continue
		end
		byId[region.id] = region
		if typeof(region.centre) ~= "Vector3" then
			table.insert(problems, label .. " centre must be a Vector3")
		end
		if typeof(region.size) ~= "Vector2" or region.size.X <= 0 or region.size.Y <= 0 then
			table.insert(problems, label .. " size must be a positive Vector2")
		elseif region.size.X < minimumDimension or region.size.Y < minimumDimension then
			table.insert(problems, string.format(
				"region %q is %.0fx%.0f, below the token grammar roomMinDimension %.0f; a player cannot use a space that size",
				region.id, region.size.X, region.size.Y, minimumDimension
			))
		end
		if region.spawn == true then
			table.insert(spawnRegions, region.id)
		end
	end

	if #spawnRegions == 0 then
		table.insert(problems, "no region is marked spawn; players would have nowhere to arrive")
	elseif #spawnRegions > 1 then
		table.insert(problems, "more than one region is marked spawn: " .. table.concat(spawnRegions, ", "))
	end

	-- Overlap. Two regions sharing ground is not automatically wrong -- a plaza
	-- can sit inside a hub -- but full containment of one by another means one of
	-- them will never be reachable as a distinct place.
	for i = 1, #spec.regions do
		for j = i + 1, #spec.regions do
			local a, b = spec.regions[i], spec.regions[j]
			if type(a.id) == "string" and type(b.id) == "string" and typeof(a.size) == "Vector2" and typeof(b.size) == "Vector2" then
				local shared = overlapArea(a, b)
				if shared > 0 then
					local smaller = math.min(a.size.X * a.size.Y, b.size.X * b.size.Y)
					if shared >= smaller - 1e-6 then
						table.insert(problems, string.format(
							"region %q is entirely inside region %q",
							if a.size.X * a.size.Y < b.size.X * b.size.Y then a.id else b.id,
							if a.size.X * a.size.Y < b.size.X * b.size.Y then b.id else a.id
						))
					end
				end
			end
		end
	end

	-- Circulation.
	local adjacency: { [string]: { string } } = {}
	for id in pairs(byId) do
		adjacency[id] = {}
	end
	local corridorWidth = tokens:grammar("corridorWidth")
	for index, route in ipairs(spec.circulation or {}) do
		local label = string.format("circulation[%d]", index)
		if byId[route.from] == nil then
			table.insert(problems, string.format("%s references unknown region %q", label, tostring(route.from)))
		end
		if byId[route.to] == nil then
			table.insert(problems, string.format("%s references unknown region %q", label, tostring(route.to)))
		end
		if route.from == route.to then
			table.insert(problems, label .. " connects a region to itself")
		end
		local width = route.width or corridorWidth
		if width < corridorWidth then
			table.insert(problems, string.format(
				"%s is %.1f wide, below the token grammar corridorWidth %.1f",
				label, width, corridorWidth
			))
		end
		if byId[route.from] ~= nil and byId[route.to] ~= nil then
			table.insert(adjacency[route.from], route.to)
			table.insert(adjacency[route.to], route.from)
		end
	end

	-- Reachability from spawn. This is the "is the shop reachable" question,
	-- answered as graph connectivity at design time rather than as a pathfinding
	-- failure in a live session.
	if #spawnRegions == 1 then
		local seen: { [string]: true } = { [spawnRegions[1]] = true }
		local queue = { spawnRegions[1] }
		while #queue > 0 do
			local current = table.remove(queue) :: string
			for _, neighbour in ipairs(adjacency[current] or {}) do
				if not seen[neighbour] then
					seen[neighbour] = true
					table.insert(queue, neighbour)
				end
			end
		end
		local unreachable: { string } = {}
		for id in pairs(byId) do
			if not seen[id] then
				table.insert(unreachable, id)
			end
		end
		table.sort(unreachable)
		if #unreachable > 0 then
			table.insert(problems, string.format(
				"regions unreachable from spawn %q: %s",
				spawnRegions[1], table.concat(unreachable, ", ")
			))
		end
	end

	-- Landmarks.
	local landmarkReadDistance = tokens:legibility("landmarkReadDistance")
	local landmarkMinHeight = tokens:grammar("landmarkMinHeight")
	local landmarkIds: { [string]: true } = {}
	for index, landmark in ipairs(spec.landmarks or {}) do
		local label = string.format("landmarks[%d]", index)
		if type(landmark.id) ~= "string" or landmark.id == "" then
			table.insert(problems, label .. " must have an id")
			continue
		end
		if landmarkIds[landmark.id] then
			table.insert(problems, string.format("landmark id %q is declared twice", landmark.id))
		end
		landmarkIds[landmark.id] = true
		if type(landmark.height) ~= "number" or landmark.height < landmarkMinHeight then
			table.insert(problems, string.format(
				"landmark %q is %.0f tall, below the token grammar landmarkMinHeight %.0f; it will not read as a landmark",
				landmark.id, tonumber(landmark.height) or 0, landmarkMinHeight
			))
		end
		if type(landmark.visibleFrom) ~= "table" or #landmark.visibleFrom == 0 then
			table.insert(problems, string.format(
				"landmark %q declares no region it must be visible from, so nothing about it can be checked",
				landmark.id
			))
		else
			for _, regionId in ipairs(landmark.visibleFrom) do
				local region = byId[regionId]
				if region == nil then
					table.insert(problems, string.format(
						"landmark %q must be visible from unknown region %q", landmark.id, tostring(regionId)
					))
				elseif typeof(landmark.at) == "Vector3" then
					local distance = distanceToRegion(landmark.at, region)
					if distance > landmarkReadDistance then
						table.insert(problems, string.format(
							"landmark %q is %.0f studs from region %q, beyond the token legibility landmarkReadDistance %.0f",
							landmark.id, distance, regionId, landmarkReadDistance
						))
					end
				end
			end
		end
	end

	for index, sightline in ipairs(spec.sightlines or {}) do
		local label = string.format("sightlines[%d]", index)
		if byId[sightline.from] == nil then
			table.insert(problems, string.format("%s references unknown region %q", label, tostring(sightline.from)))
		end
		if byId[sightline.to] == nil and not landmarkIds[sightline.to] then
			table.insert(problems, string.format(
				"%s references %q, which is neither a region nor a landmark", label, tostring(sightline.to)
			))
		end
	end

	return problems
end

--- Build the grey world.
---
--- Deliberately ugly and deliberately complete: flat planes, plain corridors,
--- marker columns at landmark heights. Everything a scenario or a pathfinder
--- needs is present, and nothing that would distract a reviewer into commenting
--- on the art is.
function Blockout.build(spec: Spec, tokens: Tokens.TokenSet, parent: Instance): BuildResult
	local problems = Blockout.validate(spec, tokens)
	if #problems > 0 then
		error("[WorldKit.Blockout] blockout is invalid:\n- " .. table.concat(problems, "\n- "), 2)
	end

	local root = Instance.new("Folder")
	root.Name = "Blockout_" .. spec.id
	root.Parent = parent

	-- Mid value, not near-white. `pavement` is 214,214,208 and it floors every
	-- region, so under a daylight mood it clipped: an eye-level capture came
	-- back with 33% of the frame blown to pure white, which destroys the
	-- detail, hue and material that everything else here is measured on.
	local greyGround = tokens:swatch("stoneSecondary")
	local greyRoute = tokens:swatch("stonePrimary")
	local greyMass = tokens:swatch("stoneSecondary")
	local greyPanel = tokens:swatch("slate")

	local byId: { [string]: Region } = {}
	local regionModels: { [string]: Model } = {}
	local coveredArea = 0

	for index, region in ipairs(spec.regions) do
		byId[region.id] = region
		local model = Instance.new("Model")
		model.Name = "Region_" .. region.id
		model.Parent = root
		Semantics.region(model, region.kind, region.id)

		local elevation = region.elevation or 0
		local slab = Build.part(
			model,
			"Ground",
			Vector3.new(region.size.X, 2, region.size.Y),
			Vector3.new(region.centre.X, region.centre.Y + elevation - 1, region.centre.Z),
			greyGround
		)
		slab:SetAttribute("BlockoutRegion", region.id)
		coveredArea += region.size.X * region.size.Y

		-- Panelled rather than poured.
		--
		-- One slab per region is the largest single surface in any generated
		-- world, and at eye level a scene critique read 60% of the frame as one
		-- unbroken plane -- this plane. A grid of panels at two tones, with a
		-- seam between them, gives the eye something to measure distance
		-- against, which is most of what separates a floor from a backdrop.
		--
		-- Panels are sized from the token grammar so they stay in proportion to
		-- doors and corridors rather than to the region, which would make a
		-- large plaza and a small one look like different materials.
		-- Half a corridor, not a whole one.
		--
		-- A 12-stud panel is in proportion to a door, which is why it was chosen,
		-- and it is still a 12-stud flat rectangle. From a raised approach the
		-- new `primitiveAppearance` measurement read 28% of the frame as large
		-- untextured rectangles and it was reading this floor. Six studs is one
		-- stride, which is the scale a player measures ground at anyway.
		local panel = tokens:grammar("corridorWidth") / 2
		local across = math.clamp(math.floor(region.size.X / panel), 1, 24)
		local along = math.clamp(math.floor(region.size.Y / panel), 1, 24)
		if across > 1 or along > 1 then
			local shading = Random.new(#region.id * 7919 + index)
			for row = 0, along - 1 do
				for column = 0, across - 1 do
					-- Both tones sit below mid. `stonePrimary` at 178,182,190 is fine
					-- at distance and blows out underfoot: 19% of the near third of
					-- an eye-level frame came back clipped once the floor was
					-- panelled, and a clipped panel has no seam, no tone and no
					-- texture -- it undoes exactly what panelling was for.
					local tone = if (row + column) % 2 == 0 then greyMass else greyPanel
					if shading:NextNumber() > 0.86 then
						tone = greyGround
					end
					local width = region.size.X / across
					local depth = region.size.Y / along
					local centre = Vector3.new(
						region.centre.X - region.size.X / 2 + (column + 0.5) * width,
						region.centre.Y + elevation + 0.2,
						region.centre.Z - region.size.Y / 2 + (row + 0.5) * depth)
					local tile = Build.part(
						model,
						"Panel",
						Vector3.new(width - 0.6, 0.4, depth - 0.6),
						centre,
						tone
					)
					tile:SetAttribute("BlockoutRegion", region.id)

					-- A course of setts around every fourth panel.
					--
					-- Two tones in a checker is a pattern; a pattern at one size
					-- is still one texture, and the eye reads the whole floor as a
					-- single surface with a grid drawn on it. An inset border on a
					-- minority of panels puts a second, smaller grain in the same
					-- plane -- which is what makes real paving read as laid rather
					-- than printed. Kept to a quarter of the tiles so the part
					-- count rises by a quarter, not fourfold.
					if (row * 3 + column) % 4 == 0 then
						local inset = Build.part(
							model,
							"Sett",
							Vector3.new(width * 0.52, 0.5, depth * 0.52),
							centre + Vector3.new(0, 0.06, 0),
							if tone == greyMass then greyPanel else greyMass
						)
						inset:SetAttribute("BlockoutRegion", region.id)
					end
				end
			end
		end

		if region.spawn then
			local spawnLocation = Instance.new("SpawnLocation")
			spawnLocation.Name = "Spawn"
			spawnLocation.Size = Vector3.new(12, 1, 12)
			spawnLocation.Anchored = true
			spawnLocation.CanCollide = true
			spawnLocation.Transparency = 0.4
			spawnLocation.Color = tokens:color("accentGold")
			spawnLocation.Position = Vector3.new(region.centre.X, region.centre.Y + elevation + 0.5, region.centre.Z)
			spawnLocation.Parent = model
		end

		regionModels[region.id] = model
	end

	local corridorWidth = tokens:grammar("corridorWidth")
	local routes = 0
	for _, route in ipairs(spec.circulation or {}) do
		local from, to = byId[route.from], byId[route.to]
		local width = route.width or corridorWidth
		local a = Vector3.new(from.centre.X, from.centre.Y + (from.elevation or 0), from.centre.Z)
		local b = Vector3.new(to.centre.X, to.centre.Y + (to.elevation or 0), to.centre.Z)
		local delta = b - a
		local length = delta.Magnitude
		if length > 1e-3 then
			local path = Instance.new("Part")
			path.Name = string.format("Route_%s_%s", route.from, route.to)
			path.Anchored = true
			path.CanCollide = true
			path.Size = Vector3.new(width, 1, length)
			path.CFrame = CFrame.lookAt(a + delta / 2, b) * CFrame.new(0, -0.5, 0)
			path.Color = greyRoute.color
			path.Material = greyRoute.material
			path.Parent = root
			path:SetAttribute("RouteWidth", width)
			Semantics.exclude(path)
			routes += 1
		end
	end

	local landmarks = 0
	for _, landmark in ipairs(spec.landmarks or {}) do
		local model = Instance.new("Model")
		model.Name = "Landmark_" .. landmark.id
		model.Parent = root
		local column = Build.part(
			model,
			"Mass",
			Vector3.new(16, landmark.height, 16),
			landmark.at + Vector3.new(0, landmark.height / 2, 0),
			greyMass
		)
		Semantics.root(model, "building", "blockout-landmark-" .. landmark.id)
		Semantics.landmark(model, landmark.id)
		-- Two anchors: one at the top for long-range silhouette checks, one at
		-- eye level for approach checks. A single anchor answers only half the
		-- question a landmark exists to answer.
		Semantics.anchor(model, landmark.id, landmark.at + Vector3.new(0, landmark.height, 0))
		Semantics.anchor(model, landmark.id, landmark.at + Vector3.new(0, tokens:character("height"), 0))
		column:SetAttribute("LandmarkHeight", landmark.height)
		landmarks += 1
	end

	root:SetAttribute("BlockoutId", spec.id)
	root:SetAttribute("BlockoutRegions", #spec.regions)
	root:SetAttribute("BlockoutRoutes", routes)
	root:SetAttribute("BlockoutLandmarks", landmarks)
	root:SetAttribute("BlockoutCoveredArea", coveredArea)

	return {
		root = root,
		regions = regionModels,
		routes = routes,
		landmarks = landmarks,
		coveredArea = coveredArea,
	}
end

--- Total walkable footprint, for density rules that need a denominator.
---
--- Density measured against a bounding box lies whenever a map is not a
--- rectangle: the empty corners count as area nobody was ever meant to fill.
function Blockout.walkableArea(spec: Spec): number
	local total = 0
	for _, region in ipairs(spec.regions) do
		total += region.size.X * region.size.Y
	end
	for i = 1, #spec.regions do
		for j = i + 1, #spec.regions do
			total -= overlapArea(spec.regions[i], spec.regions[j])
		end
	end
	return math.max(total, 0)
end

return Blockout
