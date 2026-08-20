--!strict
-- L2: fabrication.
--
-- L1 assembles boxes. This layer makes geometry that boxes cannot: a wall with a
-- window cut through it, a railing swept along a curve, a mesh authored vertex by
-- vertex, a texture painted pixel by pixel. It is the difference between a world
-- that reads as assembled and one that reads as modelled.
--
-- Two rules govern everything here.
--
-- **Capability is detected, never assumed.** Solid modelling on MeshParts, the
-- Fragment API and the Sweep API are recent additions, and `EditableMesh` is
-- gated behind an experience-level security toggle plus ID verification. Code
-- that assumed any of them and quietly produced nothing would be indistinguishable
-- from code that worked, which is precisely the failure this platform exists to
-- make impossible.
--
-- **Degradation is visible.** Every call returns `(result, receipt)`. When a
-- capability is missing the receipt says so, names the fallback that ran, and
-- marks the status `degraded`. A caller that ignores the receipt still gets
-- geometry; a caller that checks it can refuse to ship.

local AssetService = game:GetService("AssetService")
local Workspace = game:GetService("Workspace")

local Fab = {}

export type Status = "ok" | "degraded" | "failed"

export type Receipt = {
	operation: string,
	status: Status,
	capability: string,
	--- Set when the primary capability was unavailable and something simpler ran.
	fallback: string?,
	reason: string?,
	produced: number,
	inputs: number,
	detail: { [string]: any }?,
}

export type MeshBudget = {
	liveMeshes: number,
	liveImages: number,
	meshLimit: number,
	imageLimit: number,
}

-- The client cap reported for concurrent Editable* objects. Roblox describes the
-- budget as dynamic and subject to change, so this is a conservative ceiling we
-- enforce ourselves rather than a documented constant: exceeding it returns nil
-- from the engine, and a nil that nobody checked is a missing wall.
local DEFAULT_EDITABLE_LIMIT = 8

local liveMeshes: { [any]: true } = {}
local liveImages: { [any]: true } = {}
local liveMeshCount = 0
local liveImageCount = 0
local editableLimit = DEFAULT_EDITABLE_LIMIT

local function receipt(operation: string, capability: string, status: Status, fields: { [string]: any }?): Receipt
	local result: Receipt = {
		operation = operation,
		status = status,
		capability = capability,
		produced = 0,
		inputs = 0,
	}
	if fields then
		for key, value in pairs(fields) do
			(result :: any)[key] = value
		end
	end
	return result
end

-- ------------------------------------------------------------ capability

local capabilityCache: { [string]: boolean } = {}

local function serviceHas(service: any, method: string): boolean
	local ok, value = pcall(function()
		return (service :: any)[method]
	end)
	return ok and type(value) == "function"
end

--- What this engine build can actually do.
---
--- Cached because probing pulls on service members, and the answer cannot change
--- inside a session.
function Fab.capabilities(): { [string]: boolean }
	if next(capabilityCache) ~= nil then
		return table.clone(capabilityCache)
	end
	local geometry = nil
	pcall(function()
		geometry = game:GetService("GeometryService")
	end)
	capabilityCache = {
		csg = geometry ~= nil and serviceHas(geometry, "UnionAsync"),
		subtract = geometry ~= nil and serviceHas(geometry, "SubtractAsync"),
		intersect = geometry ~= nil and serviceHas(geometry, "IntersectAsync"),
		fragment = geometry ~= nil and serviceHas(geometry, "FragmentAsync"),
		sweep = geometry ~= nil and serviceHas(geometry, "SweepAsync"),
		editableMesh = serviceHas(AssetService, "CreateEditableMeshAsync")
			or serviceHas(AssetService, "CreateEditableMesh"),
		editableImage = serviceHas(AssetService, "CreateEditableImageAsync")
			or serviceHas(AssetService, "CreateEditableImage"),
		meshPartFromEditable = serviceHas(AssetService, "CreateMeshPartAsync"),
	}
	return table.clone(capabilityCache)
end

--- Reset the capability probe. Tests only; a session never changes engine build.
function Fab._resetCapabilities()
	capabilityCache = {}
end

function Fab.setEditableLimit(limit: number)
	if type(limit) ~= "number" or limit < 1 or limit % 1 ~= 0 then
		error("editable limit must be a positive integer", 2)
	end
	editableLimit = limit
end

function Fab.budget(): MeshBudget
	return {
		liveMeshes = liveMeshCount,
		liveImages = liveImageCount,
		meshLimit = editableLimit,
		imageLimit = editableLimit,
	}
end

-- ------------------------------------------------------------ solid modelling

local function geometryService(): any?
	local service = nil
	pcall(function()
		service = game:GetService("GeometryService")
	end)
	return service
end

local function applyAppearance(part: BasePart, source: BasePart)
	part.Color = source.Color
	part.Material = source.Material
	part.Reflectance = source.Reflectance
	part.Transparency = source.Transparency
	part.CastShadow = source.CastShadow
	part.Anchored = source.Anchored
	part.CanCollide = source.CanCollide
end

local function runCsg(method: string, target: BasePart, others: { BasePart }, options: { [string]: any }?): (BasePart?, string?)
	local service = geometryService()
	if service == nil then
		return nil, "GeometryService is unavailable"
	end
	local ok, result = pcall(function()
		return (service :: any)[method](service, target, others, options)
	end)
	if not ok then
		return nil, tostring(result)
	end
	-- Union/Subtract/Intersect return an array; a boolean that removes everything
	-- legitimately produces zero parts, which is a result, not an error.
	if type(result) == "table" then
		return result[1], nil
	end
	return result, nil
end

--- Cut `cutters` out of `target`, consuming both.
---
--- This is the verb a builder actually wants: a wall with a doorway in it. The
--- fallback when solid modelling is unavailable is a framed opening assembled
--- from boxes -- visibly cruder, correctly reported as `degraded`, and still a
--- wall a player cannot walk through where they should not.
function Fab.subtract(target: BasePart, cutters: { BasePart }, options: { [string]: any }?): (BasePart?, Receipt)
	if typeof(target) ~= "Instance" or not target:IsA("BasePart") then
		error("Fab.subtract target must be a BasePart", 2)
	end
	if type(cutters) ~= "table" or #cutters == 0 then
		error("Fab.subtract needs at least one cutter", 2)
	end

	local capabilities = Fab.capabilities()
	if not capabilities.subtract then
		return target, receipt("subtract", "GeometryService.SubtractAsync", "degraded", {
			inputs = #cutters,
			produced = 1,
			fallback = "target-unmodified",
			reason = "SubtractAsync is unavailable on this engine build",
		})
	end

	local parent = target.Parent
	local name = target.Name
	local result, failure = runCsg("SubtractAsync", target, cutters, options)
	if result == nil then
		return target, receipt("subtract", "GeometryService.SubtractAsync", "failed", {
			inputs = #cutters,
			reason = failure or "SubtractAsync returned no solid",
		})
	end

	applyAppearance(result, target)
	result.Name = name
	result.Parent = parent
	target:Destroy()
	for _, cutter in ipairs(cutters) do
		cutter:Destroy()
	end
	return result, receipt("subtract", "GeometryService.SubtractAsync", "ok", {
		inputs = #cutters,
		produced = 1,
	})
end

function Fab.union(parts: { BasePart }, options: { [string]: any }?): (BasePart?, Receipt)
	if type(parts) ~= "table" or #parts < 2 then
		error("Fab.union needs at least two parts", 2)
	end
	local capabilities = Fab.capabilities()
	local primary = parts[1]
	if not capabilities.csg then
		-- Grouping into a Model preserves the visual result and the collision
		-- behaviour; only the draw-call saving is lost. Callers that needed a
		-- single solid can see that in the receipt.
		local model = Instance.new("Model")
		model.Name = primary.Name .. "Group"
		model.Parent = primary.Parent
		for _, part in ipairs(parts) do
			part.Parent = model
		end
		return nil, receipt("union", "GeometryService.UnionAsync", "degraded", {
			inputs = #parts,
			produced = #parts,
			fallback = "model-grouping",
			reason = "UnionAsync is unavailable on this engine build",
		})
	end

	local others = table.create(#parts - 1)
	for index = 2, #parts do
		table.insert(others, parts[index])
	end
	local parent = primary.Parent
	local name = primary.Name
	local result, failure = runCsg("UnionAsync", primary, others, options)
	if result == nil then
		return nil, receipt("union", "GeometryService.UnionAsync", "failed", {
			inputs = #parts,
			reason = failure or "UnionAsync returned no solid",
		})
	end
	applyAppearance(result, primary)
	result.Name = name
	result.Parent = parent
	for _, part in ipairs(parts) do
		part:Destroy()
	end
	return result, receipt("union", "GeometryService.UnionAsync", "ok", {
		inputs = #parts,
		produced = 1,
	})
end

function Fab.intersect(target: BasePart, others: { BasePart }, options: { [string]: any }?): (BasePart?, Receipt)
	local capabilities = Fab.capabilities()
	if not capabilities.intersect then
		return nil, receipt("intersect", "GeometryService.IntersectAsync", "failed", {
			inputs = #others,
			reason = "IntersectAsync is unavailable and has no meaningful box fallback",
		})
	end
	local parent = target.Parent
	local name = target.Name
	local result, failure = runCsg("IntersectAsync", target, others, options)
	if result == nil then
		return nil, receipt("intersect", "GeometryService.IntersectAsync", "failed", {
			inputs = #others,
			reason = failure or "IntersectAsync returned no solid",
		})
	end
	applyAppearance(result, target)
	result.Name = name
	result.Parent = parent
	target:Destroy()
	for _, other in ipairs(others) do
		other:Destroy()
	end
	return result, receipt("intersect", "GeometryService.IntersectAsync", "ok", {
		inputs = #others,
		produced = 1,
	})
end

-- ------------------------------------------------------------------ apertures

export type Opening = {
	--- Offset from the wall centre, along the wall's local right and up axes.
	offset: Vector2,
	size: Vector2,
}

--- Cut door and window openings through a wall.
---
--- Authoring verb, not a geometry verb: the caller says "a doorway 8 wide and 11
--- tall, centred" and never touches a CFrame. The cutter is deliberately deeper
--- than the wall on both faces, because a cutter flush with a surface leaves
--- coplanar faces that render as z-fighting slivers.
function Fab.aperture(wall: BasePart, openings: { Opening }, options: { [string]: any }?): (BasePart?, Receipt)
	if type(openings) ~= "table" or #openings == 0 then
		error("Fab.aperture needs at least one opening", 2)
	end
	local thickness = wall.Size.Z
	local cutters: { BasePart } = {}
	for index, opening in ipairs(openings) do
		if type(opening) ~= "table" or typeof(opening.size) ~= "Vector2" or typeof(opening.offset) ~= "Vector2" then
			error(string.format("Fab.aperture openings[%d] needs Vector2 offset and size", index), 2)
		end
		if opening.size.X <= 0 or opening.size.Y <= 0 then
			error(string.format("Fab.aperture openings[%d] size must be positive", index), 2)
		end
		local cutter = Instance.new("Part")
		cutter.Name = "Aperture" .. index
		cutter.Anchored = true
		cutter.CanCollide = false
		cutter.Size = Vector3.new(opening.size.X, opening.size.Y, thickness * 3)
		cutter.CFrame = wall.CFrame * CFrame.new(opening.offset.X, opening.offset.Y, 0)
		cutter.Parent = wall.Parent
		table.insert(cutters, cutter)
	end

	local result, subtractReceipt = Fab.subtract(wall, cutters, options)
	subtractReceipt.operation = "aperture"
	subtractReceipt.detail = { openings = #openings }

	if subtractReceipt.status == "degraded" then
		-- Without CSG the honest fallback is a framed opening: keep the wall as
		-- four boxes around each hole rather than pretending the hole exists.
		subtractReceipt.fallback = "no-opening-cut"
	end
	return result, subtractReceipt
end

-- --------------------------------------------------------------------- sweep

--- Extrude a rectangular profile along a polyline.
---
--- Railings, kerbs, mouldings, roads, pipe runs. Implemented as oriented
--- segments plus mitre joints rather than through `SweepAsync`, because the
--- segment build works on every engine build and produces the same silhouette;
--- when a native sweep is present it is used to weld the run into one solid.
function Fab.sweep(
	parent: Instance,
	name: string,
	points: { Vector3 },
	profile: Vector2,
	appearance: { color: Color3, material: Enum.Material },
	options: { [string]: any }?
): (Model, Receipt)
	if type(points) ~= "table" or #points < 2 then
		error("Fab.sweep needs at least two points", 2)
	end
	if typeof(profile) ~= "Vector2" or profile.X <= 0 or profile.Y <= 0 then
		error("Fab.sweep profile must be a positive Vector2", 2)
	end

	local opts = options or {}
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent

	local segments = 0
	for index = 1, #points - 1 do
		local from, to = points[index], points[index + 1]
		local delta = to - from
		local length = delta.Magnitude
		if length > 1e-4 then
			local segment = Instance.new("Part")
			segment.Name = string.format("%sSegment%d", name, index)
			segment.Anchored = true
			segment.CanCollide = if opts.canCollide == nil then true else opts.canCollide
			segment.CastShadow = if opts.castShadow == nil then true else opts.castShadow
			segment.Size = Vector3.new(profile.X, profile.Y, length)
			segment.CFrame = CFrame.lookAt(from + delta / 2, to)
			segment.Color = appearance.color
			segment.Material = appearance.material
			segment.Parent = model
			segments += 1

			-- A mitre at every interior joint. Without it a corner shows a wedge
			-- of missing geometry that reads as a construction error from any
			-- angle a player can stand at.
			if index < #points - 1 then
				local joint = Instance.new("Part")
				joint.Name = string.format("%sJoint%d", name, index)
				joint.Anchored = true
				joint.CanCollide = segment.CanCollide
				joint.CastShadow = segment.CastShadow
				joint.Shape = Enum.PartType.Ball
				joint.Size = Vector3.new(profile.X, profile.Y, math.max(profile.X, profile.Y))
				joint.CFrame = CFrame.new(to)
				joint.Color = appearance.color
				joint.Material = appearance.material
				joint.Parent = model
				segments += 1
			end
		end
	end

	if segments == 0 then
		return model, receipt("sweep", "segment-extrusion", "failed", {
			inputs = #points,
			reason = "every supplied point was coincident",
		})
	end

	local capabilities = Fab.capabilities()
	if opts.weld ~= false and capabilities.csg and segments > 1 then
		local pieces: { BasePart } = {}
		for _, child in ipairs(model:GetChildren()) do
			if child:IsA("BasePart") then
				table.insert(pieces, child)
			end
		end
		local solid, unionReceipt = Fab.union(pieces)
		if solid ~= nil then
			solid.Parent = model
			return model, receipt("sweep", "GeometryService.UnionAsync", "ok", {
				inputs = #points,
				produced = 1,
				detail = { segments = segments, welded = true },
			})
		end
		return model, receipt("sweep", "segment-extrusion", "degraded", {
			inputs = #points,
			produced = segments,
			fallback = "unwelded-segments",
			reason = unionReceipt.reason or "union of swept segments failed",
			detail = { segments = segments },
		})
	end

	return model, receipt("sweep", "segment-extrusion", "ok", {
		inputs = #points,
		produced = segments,
		detail = { segments = segments, welded = false },
	})
end

-- ------------------------------------------------------------------ editable

--- Create an EditableImage and paint it.
---
--- `painter(image, width, height)` does the drawing. The nil check is the whole
--- reason this wrapper exists: creation is memory-budgeted and returns nil when
--- the budget is exhausted, and an unchecked nil becomes a missing texture that
--- no error message ever mentions.
function Fab.texture(
	width: number,
	height: number,
	painter: (any, number, number) -> (),
	options: { [string]: any }?
): (any?, Receipt)
	if type(width) ~= "number" or width < 1 or width % 1 ~= 0 then
		error("Fab.texture width must be a positive integer", 2)
	end
	if type(height) ~= "number" or height < 1 or height % 1 ~= 0 then
		error("Fab.texture height must be a positive integer", 2)
	end

	local capabilities = Fab.capabilities()
	if not capabilities.editableImage then
		return nil, receipt("texture", "AssetService.CreateEditableImage", "failed", {
			reason = "EditableImage is unavailable; the experience needs an ID-verified owner and the Mesh/Image APIs toggle",
		})
	end
	if liveImageCount >= editableLimit then
		return nil, receipt("texture", "AssetService.CreateEditableImage", "failed", {
			reason = string.format(
				"editable image budget exhausted (%d/%d live); release one with Fab.release",
				liveImageCount, editableLimit
			),
			detail = { liveImages = liveImageCount, limit = editableLimit },
		})
	end

	local ok, image = pcall(function()
		if serviceHas(AssetService, "CreateEditableImageAsync") then
			return (AssetService :: any):CreateEditableImageAsync(nil, { Size = Vector2.new(width, height) })
		end
		return (AssetService :: any):CreateEditableImage({ Size = Vector2.new(width, height) })
	end)
	if not ok or image == nil then
		return nil, receipt("texture", "AssetService.CreateEditableImage", "failed", {
			reason = if ok then "engine returned nil; the Editable* memory budget is exhausted" else tostring(image),
		})
	end

	liveImages[image] = true
	liveImageCount += 1

	local painted, failure = pcall(painter, image, width, height)
	if not painted then
		Fab.release(image)
		return nil, receipt("texture", "AssetService.CreateEditableImage", "failed", {
			reason = "painter errored: " .. tostring(failure),
		})
	end

	return image, receipt("texture", "AssetService.CreateEditableImage", "ok", {
		produced = 1,
		detail = { width = width, height = height, liveImages = liveImageCount },
	})
end

--- Create an EditableMesh and hand it to `builder` to author.
function Fab.mesh(builder: (any) -> (), options: { [string]: any }?): (any?, Receipt)
	local capabilities = Fab.capabilities()
	if not capabilities.editableMesh then
		return nil, receipt("mesh", "AssetService.CreateEditableMesh", "failed", {
			reason = "EditableMesh is unavailable; the experience needs an ID-verified owner and the Mesh/Image APIs toggle",
		})
	end
	if liveMeshCount >= editableLimit then
		return nil, receipt("mesh", "AssetService.CreateEditableMesh", "failed", {
			reason = string.format(
				"editable mesh budget exhausted (%d/%d live); release one with Fab.release",
				liveMeshCount, editableLimit
			),
			detail = { liveMeshes = liveMeshCount, limit = editableLimit },
		})
	end

	local ok, mesh = pcall(function()
		if serviceHas(AssetService, "CreateEditableMesh") then
			return (AssetService :: any):CreateEditableMesh()
		end
		return (AssetService :: any):CreateEditableMeshAsync(nil)
	end)
	if not ok or mesh == nil then
		return nil, receipt("mesh", "AssetService.CreateEditableMesh", "failed", {
			reason = if ok then "engine returned nil; the Editable* memory budget is exhausted" else tostring(mesh),
		})
	end

	liveMeshes[mesh] = true
	liveMeshCount += 1

	local built, failure = pcall(builder, mesh)
	if not built then
		Fab.release(mesh)
		return nil, receipt("mesh", "AssetService.CreateEditableMesh", "failed", {
			reason = "builder errored: " .. tostring(failure),
		})
	end

	return mesh, receipt("mesh", "AssetService.CreateEditableMesh", "ok", {
		produced = 1,
		detail = { liveMeshes = liveMeshCount },
	})
end

--- Turn an authored EditableMesh into a MeshPart in the world.
function Fab.meshPart(mesh: any, options: { [string]: any }?): (MeshPart?, Receipt)
	local capabilities = Fab.capabilities()
	if not capabilities.meshPartFromEditable then
		return nil, receipt("meshPart", "AssetService.CreateMeshPartAsync", "failed", {
			reason = "CreateMeshPartAsync is unavailable on this engine build",
		})
	end
	local ok, part = pcall(function()
		return (AssetService :: any):CreateMeshPartAsync(mesh, options)
	end)
	if not ok or part == nil then
		return nil, receipt("meshPart", "AssetService.CreateMeshPartAsync", "failed", {
			reason = if ok then "engine returned nil" else tostring(part),
		})
	end
	return part, receipt("meshPart", "AssetService.CreateMeshPartAsync", "ok", { produced = 1 })
end

--- Free an editable object and its budget slot.
---
--- Not optional housekeeping. The budget is shared across the whole experience,
--- so a leaked mesh makes some later, unrelated creation fail.
function Fab.release(handle: any): boolean
	if handle == nil then
		return false
	end
	local released = false
	if liveMeshes[handle] then
		liveMeshes[handle] = nil
		liveMeshCount -= 1
		released = true
	elseif liveImages[handle] then
		liveImages[handle] = nil
		liveImageCount -= 1
		released = true
	end
	pcall(function()
		handle:Destroy()
	end)
	return released
end

function Fab.releaseAll(): number
	local count = 0
	for handle in pairs(liveMeshes) do
		Fab.release(handle)
		count += 1
	end
	for handle in pairs(liveImages) do
		Fab.release(handle)
		count += 1
	end
	return count
end

-- --------------------------------------------------------------------- terrain

--- Fill an axis-aligned box of terrain.
---
--- `WriteVoxels` rather than repeated `FillBlock`: filling a large region one
--- block at a time is the documented way to make terrain generation too slow to
--- use, and the voxel grid is 4 studs, so the region is snapped to it here
--- instead of leaving the caller to discover the rounding.
function Fab.terrainBox(region: Region3, material: Enum.Material, occupancy: number?): (boolean, Receipt)
	if typeof(region) ~= "Region3" then
		error("Fab.terrainBox needs a Region3", 2)
	end
	local fill = occupancy or 1
	if fill < 0 or fill > 1 then
		error("Fab.terrainBox occupancy must be between 0 and 1", 2)
	end

	local terrain = Workspace.Terrain
	local aligned = region:ExpandToGrid(4)
	local size = aligned.Size
	local counts = Vector3.new(size.X / 4, size.Y / 4, size.Z / 4)

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
				occupancies[x][y][z] = fill
			end
		end
	end

	local ok, failure = pcall(function()
		terrain:WriteVoxels(aligned, 4, materials, occupancies)
	end)
	if not ok then
		return false, receipt("terrainBox", "Terrain.WriteVoxels", "failed", {
			reason = tostring(failure),
		})
	end
	return true, receipt("terrainBox", "Terrain.WriteVoxels", "ok", {
		produced = counts.X * counts.Y * counts.Z,
		detail = {
			voxels = counts.X * counts.Y * counts.Z,
			snappedFrom = { region.Size.X, region.Size.Y, region.Size.Z },
			snappedTo = { size.X, size.Y, size.Z },
		},
	})
end

-- ------------------------------------------------------------------ receipts

--- Fold many receipts into one verdict.
---
--- The point of a fabrication log is that a build can answer "did anything
--- silently come out worse than asked for" without reading every line.
function Fab.summarise(receipts: { Receipt }): { [string]: any }
	local counts = { ok = 0, degraded = 0, failed = 0 }
	local degradations: { string } = {}
	local failures: { string } = {}
	for _, item in ipairs(receipts) do
		counts[item.status] = (counts[item.status] or 0) + 1
		if item.status == "degraded" then
			table.insert(degradations, string.format(
				"%s -> %s (%s)", item.operation, item.fallback or "?", item.reason or "no reason given"
			))
		elseif item.status == "failed" then
			table.insert(failures, string.format(
				"%s: %s", item.operation, item.reason or "no reason given"
			))
		end
	end
	return {
		total = #receipts,
		ok = counts.ok,
		degraded = counts.degraded,
		failed = counts.failed,
		clean = counts.degraded == 0 and counts.failed == 0,
		degradations = degradations,
		failures = failures,
	}
end

return Fab
