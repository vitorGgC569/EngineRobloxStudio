--!strict
-- Shared navigation geometry.
--
-- The rule this module exists to enforce: an objective is a solid object, and
-- its geometric centre is inside that solid where no character can ever stand.
-- Pathfinding to a centre always returns NoPath, which reads as "unreachable"
-- and libels a perfectly reachable shop counter. Targets are therefore
-- *approached* -- candidate standing points around the object, dropped onto
-- real ground, tried in turn.

local PathfindingService = game:GetService("PathfindingService")

local Resolve = require(script.Parent.Resolve)

local Navigation = {}

export type Approach = { name: string, point: Vector3 }

local function ignoreList(): { Instance }
	local ignored = {}
	local actorFolder = workspace:FindFirstChild("RQEActors")
	if actorFolder then
		table.insert(ignored, actorFolder)
	end
	return ignored
end

--- Drop onto the surface below a point, where a character would stand.
function Navigation.standablePoint(position: Vector3): Vector3?
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = ignoreList()
	local hit = workspace:Raycast(position + Vector3.new(0, 20, 0), Vector3.new(0, -220, 0), raycastParams)
	if hit == nil then
		return nil
	end
	return hit.Position + Vector3.new(0, 3, 0)
end

--- Standing points around an instance, ordered nearest first.
---
--- Distance is measured from the bounding box *edge*, not its centre, and
--- several pads are tried per side. Landing as close as the geometry allows
--- matters: a ProximityPrompt only accepts input inside its
--- MaxActivationDistance, so an approach point chosen for convenience rather
--- than proximity arrives somewhere a player could never use.
function Navigation.approachPoints(instance: Instance, clearance: number?): { Approach }
	local cframe, size = Resolve.boundingBox(instance)
	local centre = cframe.Position
	local halfX, halfZ = size.X / 2, size.Z / 2

	local pads = if clearance ~= nil then { clearance } else { 2.5, 5, 9 }
	local directions = {
		{ name = "+Z", axis = Vector3.new(0, 0, 1), half = halfZ },
		{ name = "-Z", axis = Vector3.new(0, 0, -1), half = halfZ },
		{ name = "+X", axis = Vector3.new(1, 0, 0), half = halfX },
		{ name = "-X", axis = Vector3.new(-1, 0, 0), half = halfX },
	}

	local points: { Approach } = {}

	-- The centre is valid for open regions (a plot, a plaza) and fails fast for
	-- solids, so it costs one cheap attempt and is worth trying first.
	local centreGround = Navigation.standablePoint(centre)
	if centreGround then
		table.insert(points, { name = "centre", point = centreGround })
	end

	for _, pad in ipairs(pads) do
		for _, direction in ipairs(directions) do
			local offset = cframe:VectorToWorldSpace(direction.axis * (direction.half + pad))
			local grounded = Navigation.standablePoint(centre + offset)
			if grounded then
				table.insert(points, { name = string.format("%s+%.1f", direction.name, pad), point = grounded })
			end
		end
	end

	return points
end

--- Resolve a command's target parameters into approach points.
function Navigation.targetsFrom(params: { [string]: any }, positionKey: string, pathKey: string): { Approach }
	if params[positionKey] ~= nil then
		local value = params[positionKey]
		return { { name = "explicit", point = Vector3.new(tonumber(value[1]) or 0, tonumber(value[2]) or 0, tonumber(value[3]) or 0) } }
	end
	if params[pathKey] ~= nil then
		local original = Resolve.instance(tostring(params[pathKey]))
		local instance = Resolve.spatial(tostring(params[pathKey]))
		local candidates = Navigation.approachPoints(instance, tonumber(params.approachClearance))
		if original:IsA("ProximityPrompt") then
			local center = Resolve.boundingBox(instance).Position
			local usable = {}
			for _, candidate in candidates do
				if (candidate.point - center).Magnitude <= original.MaxActivationDistance then
					table.insert(usable, candidate)
				end
			end
			return usable
		end
		return candidates
	end
	return {}
end

export type PathAttempt = { approach: string, status: string }

--- Try each approach in turn; the first that computes wins.
function Navigation.firstReachable(from: Vector3, targets: { Approach }, agent: { [string]: any })
	local attempts: { PathAttempt } = {}
	for _, candidate in ipairs(targets) do
		local path = PathfindingService:CreatePath(agent)
		local ok = pcall(function()
			path:ComputeAsync(from, candidate.point)
		end)
		local status = if ok then tostring(path.Status) else "ComputeError"
		table.insert(attempts, { approach = candidate.name, status = status })
		if ok and path.Status == Enum.PathStatus.Success then
			return true, candidate, path, attempts
		end
	end
	return false, targets[1], nil, attempts
end

--- Does the navmesh work here at all? A NoPath verdict only means something
--- about the level if a trivially-connected hop succeeds.
function Navigation.navmeshUsable(from: Vector3, agent: { [string]: any }): (boolean, string)
	local path = PathfindingService:CreatePath(agent)
	local ok = pcall(function()
		path:ComputeAsync(from, from + Vector3.new(0, 0, -2))
	end)
	local status = if ok then tostring(path.Status) else "ComputeError"
	return ok and path.Status == Enum.PathStatus.Success, status
end

function Navigation.agentFrom(params: { [string]: any }): { [string]: any }
	return {
		AgentRadius = tonumber(params.agentRadius) or 2,
		AgentHeight = tonumber(params.agentHeight) or 5,
		AgentCanJump = params.agentCanJump ~= false,
	}
end

return Navigation
