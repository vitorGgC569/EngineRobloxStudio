--!strict
-- Authored geometry, built at runtime from vertex data.
--
-- Every important object in every game this factory made was a Part. Not for
-- want of a modeller: the Blender pipeline works, produces validated packages
-- and scores them -- and then stops, because a `.glb` on disk is not something
-- Roblox can load. It needs an asset ID, an asset ID needs an upload, an upload
-- needs a credential and moderation, and so landmarks, hero assets and every
-- main prop stayed boxes with a fallback excuse attached.
--
-- `AssetService:CreateEditableMesh` and `CreateMeshPartAsync` remove the whole
-- chain. Given positions and triangle indices they return a real MeshPart --
-- collidable, materialised, castable shadows -- with no upload, no credential,
-- no moderation and no wait. Measured working in Studio 0.734 before this
-- module was written: four vertices in, a 4x5x4 MeshPart out.
--
-- What that costs, stated plainly so nobody is surprised later:
--
-- **Every client rebuilds it.** The data ships as a ModuleScript and the mesh
-- is constructed on load. Fine for a kit of a few thousand triangles; ruinous
-- for a 20,000-triangle hero, which is why `Catalogue` budgets are low.
--
-- **The data is source, not an asset.** It is in the place file, readable, and
-- it does not benefit from Roblox's mesh streaming. When a game is ready to
-- publish for real, the same JSON goes through Open Cloud and these calls are
-- replaced by asset IDs; nothing else about the world changes, because callers
-- ask for a name, not for a backend.
--
-- **It can fail.** On a client where the API is unavailable the caller gets nil
-- and is expected to fall back to the primitive it would otherwise have built.
-- A missing tree is worse than a blocky one.

local AssetService = game:GetService("AssetService")

local Tokens = require(script.Parent.Tokens)

local Mesh = {}

export type MeshData = {
	id: string,
	positions: { number },
	normals: { number }?,
	uvs: { number }?,
	indices: { number },
	materialSlots: { number }?,
}

export type MeshOptions = {
	name: string?,
	position: Vector3?,
	rotation: number?,
	scale: number?,
	role: string?,
	material: Enum.Material?,
	anchored: boolean?,
	canCollide: boolean?,
	parent: Instance?,
}

--- Cache by id. One EditableMesh per distinct asset, however many are placed.
---
--- Without this a forest of 150 trees builds 150 identical meshes and spends
--- most of a minute doing it. `CreateMeshPartAsync` is called per instance --
--- a MeshPart cannot be shared -- but the expensive half is the mesh.
local built: { [string]: any } = {}

--- One built MeshPart per asset, cloned per placement. See `Mesh.build`.
local templates: { [string]: MeshPart } = {}

local function fail(message: string): ()
	error("[WorldKit.Mesh] " .. message, 2)
end

--- Build the EditableMesh for one asset, or return what was built before.
function Mesh.editable(data: MeshData): any?
	if built[data.id] ~= nil then
		return built[data.id]
	end
	if typeof(AssetService.CreateEditableMesh) ~= "function" then
		return nil
	end

	local positions = data.positions
	local indices = data.indices
	if #positions % 3 ~= 0 then
		fail(string.format("%s has %d position values, which is not a multiple of 3",
			data.id, #positions))
	end
	if #indices % 3 ~= 0 then
		fail(string.format("%s has %d indices, which is not a whole number of triangles",
			data.id, #indices))
	end

	local ok, result = pcall(function()
		local mesh = AssetService:CreateEditableMesh({})
		local handles = table.create(#positions // 3)
		for index = 1, #positions, 3 do
			local handle = mesh:AddVertex(
				Vector3.new(positions[index], positions[index + 1], positions[index + 2]))
			table.insert(handles, handle)
			local vertex = #handles
			if data.normals ~= nil and #data.normals >= index + 2 then
				local normals = data.normals
				pcall(function()
					mesh:SetVertexNormal(handle,
						Vector3.new(normals[index], normals[index + 1], normals[index + 2]))
				end)
			end
			if data.uvs ~= nil then
				local uvs = data.uvs
				local at = (vertex - 1) * 2 + 1
				if #uvs >= at + 1 then
					pcall(function()
						mesh:SetVertexUV(handle, Vector2.new(uvs[at], uvs[at + 1]))
					end)
				end
			end
		end
		-- Indices arrive zero-based, the way every mesh format writes them, and
		-- `AddVertex` returns opaque handles rather than integers. Mapping here
		-- rather than at export keeps the data file portable.
		for index = 1, #indices, 3 do
			mesh:AddTriangle(
				handles[indices[index] + 1],
				handles[indices[index + 1] + 1],
				handles[indices[index + 2] + 1])
		end
		return mesh
	end)

	if not ok then
		warn("[WorldKit.Mesh] " .. data.id .. " could not be built: " .. tostring(result))
		return nil
	end
	built[data.id] = result
	return result
end

--- One placed MeshPart, or nil when this client cannot build meshes.
---
--- Returning nil rather than raising is deliberate: the caller has a primitive
--- it can build instead, and a world with blocky trees beats a world with an
--- error where the trees were.
function Mesh.build(data: MeshData, tokens: Tokens.TokenSet, options: MeshOptions?): MeshPart?
	local opts = options or {}
	local editable = Mesh.editable(data)
	if editable == nil then
		return nil
	end

	-- One MeshPart per kit entry, cloned for every placement.
	--
	-- `CreateMeshPartAsync` yields. Called once per prop it is slow enough that
	-- a world of a few hundred was still building when a capture was taken:
	-- successive runs photographed 28 trees, then 6, and nothing errored --
	-- the scatter loops simply had not finished. `Clone` is synchronous and
	-- cheap, so the async call happens once per distinct asset and never again.
	local template = templates[data.id]
	if template == nil then
		local made, result = pcall(function()
			return AssetService:CreateMeshPartAsync(Content.fromObject(editable))
		end)
		if made and result ~= nil then
			template = result
			templates[data.id] = template
		end
	end
	local ok, part = template ~= nil, if template ~= nil then template:Clone() else nil
	if not ok or part == nil then
		warn("[WorldKit.Mesh] " .. data.id .. " built but would not become a MeshPart: "
			.. tostring(part))
		return nil
	end

	local mesh = part :: MeshPart

	-- A mesh that came back as a stub is worse than no mesh.
	--
	-- `CreateMeshPartAsync` can return a MeshPart whose bounds collapse -- the
	-- result on screen is a small cube where a tree should be, and a forest of
	-- them reads as debris rather than as woodland. The caller has a Part
	-- version it can build instead, so refusing here is strictly better than
	-- placing the stub. Half a stud is far below anything this kit contains.
	if math.min(mesh.Size.X, mesh.Size.Y, mesh.Size.Z) < 0.5 then
		warn(string.format(
			"[WorldKit.Mesh] %s built with collapsed bounds %s; falling back to parts",
			data.id, tostring(mesh.Size)))
		mesh:Destroy()
		return nil
	end

	mesh.Name = opts.name or data.id
	mesh.Anchored = if opts.anchored ~= nil then opts.anchored else true
	mesh.CanCollide = if opts.canCollide ~= nil then opts.canCollide else true
	mesh.Color = tokens:color(opts.role or "structurePrimary")
	mesh.Material = opts.material or Enum.Material.Slate

	local scale = opts.scale or 1
	if scale ~= 1 then
		mesh.Size = mesh.Size * scale
	end
	local position = opts.position or Vector3.zero
	-- Seated on the ground, not centred in it. Every caller here places by the
	-- point the object stands on, because that is what a world spec records.
	mesh.CFrame = CFrame.new(position + Vector3.new(0, mesh.Size.Y / 2, 0))
		* CFrame.Angles(0, math.rad(opts.rotation or 0), 0)
	mesh.Parent = opts.parent
	return mesh
end

--- What the runtime backend can carry, and what it refuses.
---
--- A budget rather than a hope: the data lives in the place file and is rebuilt
--- on every client, so an asset that would be fine as an uploaded mesh can be
--- the wrong choice here. `Catalogue` checks against this before a program is
--- ever sent to Blender.
Mesh.LIMITS = {
	trianglesPerAsset = 2400,
	trianglesPerKit = 14000,
	note = "runtime-built meshes ship as source and are rebuilt per client; "
		.. "past these the same data should go through Open Cloud instead",
}

function Mesh.problems(data: MeshData): { string }
	local found: { string } = {}
	local triangles = #data.indices // 3
	if triangles > Mesh.LIMITS.trianglesPerAsset then
		table.insert(found, string.format(
			"%s is %d triangles, above the runtime budget of %d",
			data.id, triangles, Mesh.LIMITS.trianglesPerAsset))
	end
	if triangles == 0 then
		table.insert(found, data.id .. " has no triangles")
	end
	return found
end

return Mesh
