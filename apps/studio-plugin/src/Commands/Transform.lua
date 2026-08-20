--!strict
-- Putting things where you want them, by coordinate or by relation.
--
-- An agent cannot drag. Every placement it makes is arithmetic, and the
-- arithmetic that matters is not "at these coordinates" but "against that
-- wall", "on top of this", "centred in that room". Those are the sentences a
-- person uses, and computing them by hand from bounding boxes is where an hour
-- goes.
--
-- Everything here reads back what it did: where the thing ended up, what it
-- now touches, what it overlaps. A move you cannot verify is a move you have
-- to screenshot.

local Errors = require(script.Parent.Parent.Errors)

local TransformCommands = {}

local function resolve(path: string): Instance
	local node: Instance = game
	for piece in string.gmatch(path, "[^%.]+") do
		if piece ~= "game" then
			local child = node:FindFirstChild(piece)
			if child == nil then
				Errors.raise(Errors.NOT_FOUND, ("no instance at %s"):format(path))
			end
			node = child
		end
	end
	return node
end

local function boundsOf(thing: Instance): (Vector3, Vector3)
	if thing:IsA("BasePart") then
		return thing.Position, thing.Size
	end
	if thing:IsA("Model") then
		local cframe, size = thing:GetBoundingBox()
		return cframe.Position, size
	end
	Errors.raise(Errors.BAD_PARAMS,
		("%s is a %s and has no bounds"):format(thing:GetFullName(), thing.ClassName))
	return Vector3.zero, Vector3.zero
end

local function pivotTo(thing: Instance, position: Vector3)
	if thing:IsA("BasePart") then
		thing.Position = position
	elseif thing:IsA("Model") then
		thing:PivotTo(CFrame.new(position) * (thing:GetPivot() - thing:GetPivot().Position))
	end
end

local function describe(thing: Instance): { [string]: any }
	local centre, size = boundsOf(thing)
	return {
		path = thing:GetFullName(),
		centre = { centre.X, centre.Y, centre.Z },
		size = { size.X, size.Y, size.Z },
		min = { centre.X - size.X / 2, centre.Y - size.Y / 2, centre.Z - size.Z / 2 },
		max = { centre.X + size.X / 2, centre.Y + size.Y / 2, centre.Z + size.Z / 2 },
	}
end

--- What this thing currently overlaps, so a placement can be checked.
local function touching(thing: Instance): { string }
	local centre, size = boundsOf(thing)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { thing }
	params.MaxParts = 24

	local names = {}
	local seen: { [Instance]: boolean } = {}
	local ok, parts = pcall(function()
		-- Shrunk slightly: two parts placed flush against each other are
		-- touching, not overlapping, and reporting every neighbour as a
		-- collision makes the check useless.
		return workspace:GetPartBoundsInBox(CFrame.new(centre), size * 0.98, params)
	end)
	if ok then
		for _, part in ipairs(parts) do
			local owner: Instance = part:FindFirstAncestorOfClass("Model") or part
			if not seen[owner] then
				seen[owner] = true
				table.insert(names, owner:GetFullName())
			end
		end
	end
	return names
end

--- transform.bounds: where something is and how big.
function TransformCommands.bounds(params: { [string]: any }): any
	local thing = resolve(Errors.expect(params, "path", "string"))
	local out = describe(thing)
	out.overlaps = touching(thing)
	return out
end

--- transform.move: absolute or relative.
function TransformCommands.move(params: { [string]: any }): any
	local thing = resolve(Errors.expect(params, "path", "string"))
	local to = params.to
	local by = params.by

	if type(to) == "table" then
		pivotTo(thing, Vector3.new(to[1], to[2], to[3]))
	elseif type(by) == "table" then
		local centre = boundsOf(thing)
		pivotTo(thing, centre + Vector3.new(by[1], by[2], by[3]))
	else
		Errors.raise(Errors.BAD_PARAMS, "move needs `to` or `by`")
	end

	local out = describe(thing)
	out.overlaps = touching(thing)
	return out
end

--- transform.rotate / scale, in degrees and factors.
function TransformCommands.orient(params: { [string]: any }): any
	local thing = resolve(Errors.expect(params, "path", "string"))

	local rotate = params.rotate
	if type(rotate) == "table" then
		local turn = CFrame.Angles(
			math.rad(rotate[1] or 0), math.rad(rotate[2] or 0), math.rad(rotate[3] or 0))
		if thing:IsA("BasePart") then
			thing.CFrame = CFrame.new(thing.Position) * turn
		elseif thing:IsA("Model") then
			thing:PivotTo(CFrame.new(thing:GetPivot().Position) * turn)
		end
	end

	local scale = tonumber(params.scale)
	if scale ~= nil and scale > 0 then
		if thing:IsA("BasePart") then
			thing.Size *= scale
		elseif thing:IsA("Model") then
			local ok = pcall(function()
				thing:ScaleTo(thing:GetScale() * scale)
			end)
			if not ok then
				for _, item in ipairs(thing:GetDescendants()) do
					if item:IsA("BasePart") then
						item.Size *= scale
					end
				end
			end
		end
	end

	local out = describe(thing)
	out.overlaps = touching(thing)
	return out
end

--- transform.align: put A against a face of B.
---
--- The call an agent actually wants. "Against the north wall" is one sentence
--- and about fifteen lines of bounding-box arithmetic, every time.
function TransformCommands.align(params: { [string]: any }): any
	local subject = resolve(Errors.expect(params, "path", "string"))
	local anchor = resolve(Errors.expect(params, "to", "string"))
	local face = string.lower(tostring(params.face or "top"))
	local gap = tonumber(params.gap) or 0

	local subjectCentre, subjectSize = boundsOf(subject)
	local anchorCentre, anchorSize = boundsOf(anchor)

	local offsets: { [string]: Vector3 } = {
		top = Vector3.new(0, (anchorSize.Y + subjectSize.Y) * 0.5 + gap, 0),
		bottom = Vector3.new(0, -((anchorSize.Y + subjectSize.Y) * 0.5 + gap), 0),
		left = Vector3.new(-((anchorSize.X + subjectSize.X) * 0.5 + gap), 0, 0),
		right = Vector3.new((anchorSize.X + subjectSize.X) * 0.5 + gap, 0, 0),
		front = Vector3.new(0, 0, -((anchorSize.Z + subjectSize.Z) * 0.5 + gap)),
		back = Vector3.new(0, 0, (anchorSize.Z + subjectSize.Z) * 0.5 + gap),
		centre = Vector3.zero,
	}

	local offset = offsets[face]
	if offset == nil then
		local names = {}
		for name in pairs(offsets) do
			table.insert(names, name)
		end
		table.sort(names)
		Errors.raise(Errors.BAD_PARAMS,
			("no face %q; have %s"):format(face, table.concat(names, ", ")))
	end

	-- Keep the axes the caller did not name. Aligning to `top` should not also
	-- centre the thing horizontally unless that was asked for.
	local target = anchorCentre + offset
	if params.centred ~= true then
		if face == "top" or face == "bottom" then
			target = Vector3.new(subjectCentre.X, target.Y, subjectCentre.Z)
		elseif face == "left" or face == "right" then
			target = Vector3.new(target.X, subjectCentre.Y, subjectCentre.Z)
		elseif face == "front" or face == "back" then
			target = Vector3.new(subjectCentre.X, subjectCentre.Y, target.Z)
		end
	end

	pivotTo(subject, target)
	local out = describe(subject)
	out.alignedTo = anchor:GetFullName()
	out.face = face
	out.overlaps = touching(subject)
	return out
end

--- transform.snap: round a position onto a grid.
function TransformCommands.snap(params: { [string]: any }): any
	local thing = resolve(Errors.expect(params, "path", "string"))
	local grid = tonumber(params.grid) or 4
	local axes = params.axes or "xz"

	local centre = boundsOf(thing)
	local function round(value: number): number
		return math.floor(value / grid + 0.5) * grid
	end
	local snapped = Vector3.new(
		if string.find(axes, "x") then round(centre.X) else centre.X,
		if string.find(axes, "y") then round(centre.Y) else centre.Y,
		if string.find(axes, "z") then round(centre.Z) else centre.Z)

	pivotTo(thing, snapped)
	local out = describe(thing)
	out.grid = grid
	out.moved = (snapped - centre).Magnitude
	return out
end

--- transform.settle: drop something onto whatever is under it.
function TransformCommands.settle(params: { [string]: any }): any
	local thing = resolve(Errors.expect(params, "path", "string"))
	local centre, size = boundsOf(thing)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { thing }

	local from = centre + Vector3.new(0, size.Y, 0)
	local result = workspace:Raycast(from, Vector3.new(0, -(tonumber(params.reach) or 512), 0), rayParams)
	if result == nil then
		return { settled = false, reason = "nothing underneath", path = thing:GetFullName() }
	end

	pivotTo(thing, result.Position + Vector3.new(0, size.Y * 0.5, 0))
	local out = describe(thing)
	out.settled = true
	out.onto = result.Instance:GetFullName()
	out.overlaps = touching(thing)
	return out
end

--- transform.nearest: what is closest to a point.
function TransformCommands.nearest(params: { [string]: any }): any
	local point = params.point
	if type(point) ~= "table" then
		Errors.raise(Errors.BAD_PARAMS, "nearest needs a point")
	end
	local at = Vector3.new(point[1], point[2], point[3])
	local root = if params.within ~= nil then resolve(params.within) else workspace
	local className = params.className

	local best, bestDistance = nil, math.huge
	for _, item in ipairs(root:GetDescendants()) do
		if className == nil or item:IsA(className) then
			local ok, centre = pcall(function()
				if item:IsA("BasePart") then
					return item.Position
				end
				return item:GetPivot().Position
			end)
			if ok then
				local distance = (centre - at).Magnitude
				if distance < bestDistance then
					best, bestDistance = item, distance
				end
			end
		end
	end

	if best == nil then
		return { found = false }
	end
	return {
		found = true,
		path = best:GetFullName(),
		className = best.ClassName,
		distance = bestDistance,
	}
end

--- transform.overlaps: are these two in each other's space, and by how much.
function TransformCommands.overlaps(params: { [string]: any }): any
	local a = resolve(Errors.expect(params, "a", "string"))
	local b = resolve(Errors.expect(params, "b", "string"))
	local aCentre, aSize = boundsOf(a)
	local bCentre, bSize = boundsOf(b)

	local overlap = Vector3.new(
		(aSize.X + bSize.X) * 0.5 - math.abs(aCentre.X - bCentre.X),
		(aSize.Y + bSize.Y) * 0.5 - math.abs(aCentre.Y - bCentre.Y),
		(aSize.Z + bSize.Z) * 0.5 - math.abs(aCentre.Z - bCentre.Z))

	local intersecting = overlap.X > 0 and overlap.Y > 0 and overlap.Z > 0
	return {
		overlaps = intersecting,
		volume = if intersecting then overlap.X * overlap.Y * overlap.Z else 0,
		byAxis = { overlap.X, overlap.Y, overlap.Z },
		gap = if intersecting then 0
			else math.max(-overlap.X, -overlap.Y, -overlap.Z),
	}
end

return TransformCommands
