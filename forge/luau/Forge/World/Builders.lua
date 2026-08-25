--!strict
--[[
	Builders — idempotent find-or-create helpers for code-built worlds.

	Worlds built from scripts must be rebuildable: every helper looks for
	the instance first and creates it only when missing, so running the
	builder twice yields one world, not two. Physical defaults live here
	so no builder invents its own.
]]

local Builders = {}

export type PartSpec = {
	name: string,
	size: { x: number, y: number, z: number },
	position: { x: number, y: number, z: number },
	color: { r: number, g: number, b: number }?,
	material: string?,
	anchored: boolean?,
	canCollide: boolean?,
}

local function clamp01(v: number): number
	return math.clamp(v, 0, 1)
end

local function ensureChild(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance
end

function Builders.ensureFolder(parent: Instance, name: string): Instance
	return ensureChild(parent, "Folder", name)
end

function Builders.ensureModel(parent: Instance, name: string): Instance
	return ensureChild(parent, "Model", name)
end

-- Creates or updates a part; returns (part, created).
function Builders.ensurePart(parent: Instance, spec: PartSpec): (Instance, boolean)
	local existing = parent:FindFirstChild(spec.name)
	local created = false
	local part: Instance
	if existing and existing:IsA("BasePart") then
		part = existing
	else
		part = Instance.new("Part")
		part.Name = spec.name
		part.Parent = parent
		created = true
	end

	local p = part :: any
	p.Size = Vector3.new(spec.size.x, spec.size.y, spec.size.z)
	p.Position = Vector3.new(spec.position.x, spec.position.y, spec.position.z)
	p.Anchored = if spec.anchored ~= nil then spec.anchored else true
	p.CanCollide = if spec.canCollide ~= nil then spec.canCollide else true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if spec.color then
		p.Color = Color3.new(clamp01(spec.color.r), clamp01(spec.color.g), clamp01(spec.color.b))
	end
	if spec.material then
		p.Material = (Enum.Material :: any)[spec.material]
	end
	return part, created
end

return Builders
