--!strict
--[[
	Navigator — waypoint following with stuck detection and recovery.

	PathfindingService returns waypoints; this module walks them and
	handles the part that actually breaks in production: getting stuck.
	Progress is measured against expected speed; after `stuckSeconds`
	without progress the navigator re-requests a path through an injected
	callback, optionally with a jittered goal to escape local minima.
]]

local Navigator = {}

export type Vec3 = { x: number, y: number, z: number }

type Self = {
	waypoints: { Vec3 },
	index: number,
	arriveDistance: number,
	expectedSpeed: number,
	stuckSeconds: number,
	progressMemory: number,
	lastProgressAt: number,
	repathRequests: number,
	requestPath: ((from: Vec3, to: Vec3) -> { Vec3 })?,
	clock: () -> number,
}

Navigator.__index = Navigator

function Navigator.new(config: {
	waypoints: { Vec3 },
	arriveDistance: number?,
	expectedSpeed: number?,
	stuckSeconds: number?,
	requestPath: ((Vec3, Vec3) -> { Vec3 })?,
	clock: (() -> number)?,
}): Self
	return setmetatable({
		waypoints = table.clone(config.waypoints),
		index = 1,
		arriveDistance = config.arriveDistance or 3,
		expectedSpeed = config.expectedSpeed or 16,
		stuckSeconds = config.stuckSeconds or 2.5,
		progressMemory = 0,
		lastProgressAt = 0,
		repathRequests = 0,
		requestPath = config.requestPath,
		clock = config.clock or os.clock,
	}, Navigator)
end

function Navigator.currentGoal(self: Self): Vec3?
	return self.waypoints[self.index]
end

-- Feed current position each tick; returns movement direction toward the
-- active waypoint (unit XZ), plus whether a repath just happened.
function Navigator.update(self: Self, pos: Vec3, dt: number): ({ x: number, z: number }, boolean)
	local now = self.clock()
	local goal = self.waypoints[self.index]

	if goal then
		local dx, dz = goal.x - pos.x, goal.z - pos.z
		local dist = math.sqrt(dx * dx + dz * dz)
		if dist <= self.arriveDistance then
			self.progressMemory = 0
			self.lastProgressAt = now
			self.index += 1
			goal = self.waypoints[self.index]
		else
			local moved = math.min(dt * self.expectedSpeed, dist)
			self.progressMemory += moved
			if self.progressMemory > self.arriveDistance then
				self.progressMemory = 0
				self.lastProgressAt = now
			end
		end
	end

	local stuckFor = now - self.lastProgressAt
	local repathed = false
	if goal and stuckFor >= self.stuckSeconds and self.requestPath then
		local jitterX = (math.random() - 0.5) * 4
		local jitterZ = (math.random() - 0.5) * 4
		local newPath = self.requestPath(pos, {
			x = goal.x + jitterX,
			y = goal.y,
			z = goal.z + jitterZ,
		})
		if #newPath > 0 then
			self.waypoints = newPath
			self.index = 1
			self.repathRequests += 1
			self.progressMemory = 0
			self.lastProgressAt = now
			repathed = true
		end
	end

	local nextGoal = self.waypoints[self.index]
	if not nextGoal then
		return { x = 0, z = 0 }, repathed
	end
	local dx, dz = nextGoal.x - pos.x, nextGoal.z - pos.z
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 1e-6 then
		return { x = 0, z = 0 }, repathed
	end
	return { x = dx / len, z = dz / len }, repathed
end

function Navigator.finished(self: Self): boolean
	return self.index > #self.waypoints
end

return Navigator
