--!strict
--- Asking the world where things are.
---
--- Raycasts, overlaps, nearest, line of sight, ground under a point. Every one
--- of these is three or four lines of `RaycastParams` boilerplate that has to
--- be right, and the way it goes wrong is quiet: a filter list that should have
--- excluded the caster, a `FilterType` left on the default, a ray that starts
--- inside the thing it is looking for.
---
--- **The caster is excluded by default.** A ray fired from a creature that hits
--- the creature is the single most common raycast bug in Roblox, and it reads
--- as "the pathfinding is broken" rather than as what it is.

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")

local Spatial = {}

local function paramsFor(ignore: { Instance }?, include: { Instance }?): RaycastParams
	local params = RaycastParams.new()
	if include ~= nil then
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = include
	else
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = ignore or {}
	end
	params.IgnoreWater = false
	return params
end

local function rootOf(thing: any): Instance?
	if typeof(thing) ~= "Instance" then
		return nil
	end
	if thing:IsA("Model") then
		return thing
	end
	local model = thing:FindFirstAncestorOfClass("Model")
	return model or thing
end

export type Hit = {
	hit: boolean,
	instance: Instance?,
	position: Vector3?,
	normal: Vector3?,
	distance: number?,
	material: string?,
}

--- Cast a ray. `from` and `direction`; `direction` carries the length.
function Spatial.ray(from: Vector3, direction: Vector3, options: { [string]: any }?): Hit
	local opts = options or {}
	local ignore = opts.ignore or {}
	-- The caster, and everything attached to it.
	if opts.caster ~= nil then
		local root = rootOf(opts.caster)
		if root ~= nil then
			ignore = table.clone(ignore)
			table.insert(ignore, root)
		end
	end

	local result = workspace:Raycast(from, direction, paramsFor(ignore, opts.include))
	if result == nil then
		return { hit = false }
	end
	return {
		hit = true,
		instance = result.Instance,
		position = result.Position,
		normal = result.Normal,
		distance = (result.Position - from).Magnitude,
		material = result.Material.Name,
	}
end

--- Cast between two points, which is what you usually mean.
function Spatial.between(from: Vector3, to: Vector3, options: { [string]: any }?): Hit
	return Spatial.ray(from, to - from, options)
end

--- What is directly under a point, and how far.
function Spatial.ground(at: Vector3, options: { [string]: any }?): Hit
	local opts = table.clone(options or {})
	local reach = tonumber(opts.reach) or 512
	return Spatial.ray(at + Vector3.new(0, 2, 0), Vector3.new(0, -reach, 0), opts)
end

--- Drop a point onto whatever is below it. Placing things on uneven ground.
function Spatial.settle(at: Vector3, options: { [string]: any }?): Vector3
	local found = Spatial.ground(at, options)
	if not found.hit or found.position == nil then
		return at
	end
	local lift = tonumber((options or {}).lift) or 0
    return found.position + Vector3.new(0, lift, 0)
end

--- Can A see B? The check every guard, turret and jump-scare needs.
function Spatial.sees(from: Vector3, to: Vector3, options: { [string]: any }?): boolean
	local blocked = Spatial.between(from, to, options)
	if not blocked.hit then
		return true
	end
	-- Hitting the target itself is seeing it. Without this, a ray at a player
	-- always reports blocked, by the player.
	local target = (options or {}).target
	if target ~= nil and blocked.instance ~= nil then
		local root = rootOf(blocked.instance)
		if root == target or blocked.instance == target then
			return true
		end
	end
	return false
end

--- Everything whose parts fall inside a box.
function Spatial.inBox(centre: Vector3, size: Vector3, options: { [string]: any }?): { Instance }
	local opts = options or {}
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = opts.ignore or {}
	params.MaxParts = tonumber(opts.maxParts) or 500

	local seen: { [Instance]: boolean } = {}
	local out = {}
	for _, part in ipairs(workspace:GetPartBoundsInBox(CFrame.new(centre), size, params)) do
		local subject = if opts.parts == true then part else (rootOf(part) or part)
		if not seen[subject] then
			seen[subject] = true
			table.insert(out, subject)
		end
	end
	return out
end

--- Everything within a radius.
function Spatial.inRadius(centre: Vector3, radius: number, options: { [string]: any }?): { Instance }
	local opts = options or {}
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = opts.ignore or {}
	params.MaxParts = tonumber(opts.maxParts) or 500

	local seen: { [Instance]: boolean } = {}
	local out = {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(centre, radius, params)) do
		local subject = if opts.parts == true then part else (rootOf(part) or part)
		if not seen[subject] then
			seen[subject] = true
			table.insert(out, subject)
		end
	end
	return out
end

--- Do these two overlap, and by how much?
function Spatial.overlaps(a: Instance, b: Instance): (boolean, number)
	-- Two returns cannot be made optional as a group: `(Vector3, Vector3)?`
	-- is a syntax error, not a nullable tuple. Each half is optional.
	local function box(thing: Instance): (Vector3?, Vector3?)
		if thing:IsA("BasePart") then
			return thing.Position, thing.Size
		end
		if thing:IsA("Model") then
			local cframe, size = thing:GetBoundingBox()
			return cframe.Position, size
		end
		return nil
	end
	local aCentre, aSize = box(a)
	local bCentre, bSize = box(b)
	if aCentre == nil or bCentre == nil then
		return false, 0
	end

	local overlap = Vector3.new(
		(aSize.X + bSize.X) * 0.5 - math.abs(aCentre.X - bCentre.X),
		(aSize.Y + bSize.Y) * 0.5 - math.abs(aCentre.Y - bCentre.Y),
		(aSize.Z + bSize.Z) * 0.5 - math.abs(aCentre.Z - bCentre.Z))
	if overlap.X <= 0 or overlap.Y <= 0 or overlap.Z <= 0 then
		return false, 0
	end
	return true, overlap.X * overlap.Y * overlap.Z
end

--- The closest thing to a point, optionally filtered.
function Spatial.nearest(point: Vector3, candidates: { Instance },
	filter: ((Instance) -> boolean)?): (Instance?, number)

	local best, bestDistance = nil, math.huge
	for _, candidate in ipairs(candidates) do
		if filter == nil or filter(candidate) then
			local ok, position = pcall(function()
				if candidate:IsA("BasePart") then
					return candidate.Position
				end
				return candidate:GetPivot().Position
			end)
			if ok then
				local distance = (position - point).Magnitude
				if distance < bestDistance then
					best, bestDistance = candidate, distance
				end
			end
		end
	end
	return best, bestDistance
end

--- The nearest living player character.
function Spatial.nearestPlayer(point: Vector3, within: number?): (Model?, number)
	local characters = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character ~= nil then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil and humanoid.Health > 0 then
				table.insert(characters, character)
			end
		end
	end
	local found, distance = Spatial.nearest(point, characters)
	if within ~= nil and distance > within then
		return nil, distance
	end
	return found :: any, distance
end

--- A walkable path, or why there is not one.
function Spatial.path(from: Vector3, to: Vector3, options: { [string]: any }?): { [string]: any }
	local opts = options or {}
	local path = PathfindingService:CreatePath({
		AgentRadius = tonumber(opts.radius) or 2.5,
		AgentHeight = tonumber(opts.height) or 5,
		AgentCanJump = opts.canJump ~= false,
		-- Without a Costs table every PathfindingLink in the place is ignored,
		-- and a creature simply refuses to cross a gap somebody built for it.
		Costs = opts.costs or { Jump = 4, Climb = 2 },
	})
	local ok, err = pcall(function()
		path:ComputeAsync(from, to)
	end)
	if not ok then
		return { ok = false, status = "error", error = tostring(err), waypoints = {} }
	end
	local waypoints = {}
	if path.Status == Enum.PathStatus.Success then
		for _, point in ipairs(path:GetWaypoints()) do
			table.insert(waypoints, {
				position = point.Position,
				action = point.Action.Name,
				label = point.Label,
			})
		end
	end
	return {
		ok = path.Status == Enum.PathStatus.Success,
		status = path.Status.Name,
		waypoints = waypoints,
	}
end

--- The bounding box of anything, as centre and size.
function Spatial.bounds(thing: Instance): { [string]: any }?
	if thing:IsA("BasePart") then
		return {
			centre = thing.Position, size = thing.Size,
			min = thing.Position - thing.Size * 0.5,
			max = thing.Position + thing.Size * 0.5,
		}
	end
	if thing:IsA("Model") then
		local cframe, size = thing:GetBoundingBox()
		return {
			centre = cframe.Position, size = size,
			min = cframe.Position - size * 0.5,
			max = cframe.Position + size * 0.5,
		}
	end
	return nil
end

return Spatial
