--!strict
--[[
	Nav — getting from here to there without walking into things.

	Until now every actor in this engine moved by pointing itself at its target
	and calling `Humanoid:MoveTo`. On a flat arena that is invisible. On any
	world with a rock in it, the enemy walks into the rock and stays there,
	pressing forward forever, which is the single most recognisable "this is an
	amateur Roblox game" behaviour there is.

	This wraps Roblox's own `PathfindingService` — a real navmesh computed from
	the real world, not a grid this engine invented — and adds the parts that
	service leaves to you:

	  * repathing when the target moves, throttled so a chasing enemy does not
	    recompute a path sixty times a second;
	  * waypoint following with a stuck detector, because a computed path is
	    not a guarantee that a Humanoid will actually traverse it;
	  * a straight-line fallback, so a failed path degrades to the old
	    behaviour instead of an actor standing still.

		local agent = Nav.follow(model, {
			target = function() return player.Character end,
			standoff = 6,
		})
		agent:stop()

	--- On costs ------------------------------------------------------------

	`AgentParameters` are the difference between an enemy that squeezes through
	a doorway and one that refuses to. They are exposed per agent rather than
	fixed, because a hulking brute genuinely does need a wider path than a
	stalker, and pretending otherwise is how you get a boss stuck on a fence.
]]

local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Nav = {}

Nav.config = {
	-- How often a moving target is allowed to trigger a fresh path.
	repathSeconds = 0.55,
	-- How far the target must move before that repath is worth doing at all.
	repathDistance = 6,
	-- No progress for this long with a path in hand means something is wrong.
	stuckSeconds = 1.2,
	stuckDistance = 1.5,
	waypointReached = 3.5,
	maxConcurrentComputes = 4,
}

Nav.defaults = {
	AgentRadius = 2.5,
	AgentHeight = 5,
	AgentCanJump = true,
	AgentCanClimb = false,
	WaypointSpacing = 4,
}

local agents: { [Model]: any } = {}
local connection: RBXScriptConnection? = nil
local activeComputes = 0

-- ================================= paths ====================================
--[[
	Compute a path, or say why not.

	Returns the waypoint list and a status string. The status matters: a caller
	that treats "NoPath" the same as "Success with zero waypoints" will happily
	report that an actor has arrived when it never set off.
]]
function Nav.computePath(from: Vector3, to: Vector3, parameters: any?): ({ PathWaypoint }, string)
	local params = table.clone(Nav.defaults)
	for key, value in (parameters or {}) do
		params[key] = value
	end

	local path = PathfindingService:CreatePath(params)
	local ok, err = pcall(function()
		path:ComputeAsync(from, to)
	end)
	if not ok then
		return {}, "Error: " .. tostring(err)
	end
	if path.Status ~= Enum.PathStatus.Success then
		return {}, path.Status.Name
	end
	local waypoints = path:GetWaypoints()
	-- The first waypoint is where the actor already is; walking to it is a
	-- wasted step and, on a slope, a visible stutter.
	if #waypoints > 1 then
		table.remove(waypoints, 1)
	end
	return waypoints, "Success"
end

--[[
	Is there a walkable route at all?

	Cheap enough to ask before committing to a fight: an enemy that cannot
	reach the player should give up and go home rather than press against a
	wall until the session ends.
]]
function Nav.reachable(from: Vector3, to: Vector3, parameters: any?): boolean
	local waypoints, status = Nav.computePath(from, to, parameters)
	return status == "Success" and #waypoints > 0
end

-- ================================= agents ===================================
local Agent = {}
Agent.__index = Agent

local function humanoidOf(model: Model): Humanoid?
	return model:FindFirstChildOfClass("Humanoid")
end

local function positionOf(model: Model): Vector3
	return model:GetPivot().Position
end

function Agent:_resolveTarget(): Vector3?
	local target = self.target
	if typeof(target) == "function" then
		target = target()
	end
	if typeof(target) == "Vector3" then
		return target
	end
	if typeof(target) == "Instance" and target:IsA("Model") then
		return positionOf(target)
	end
	return nil
end

function Agent:_repath(goal: Vector3)
	if self.stopped or self.computing or activeComputes >= Nav.config.maxConcurrentComputes then
		return
	end
	if os.clock() - self.lastRepath < Nav.config.repathSeconds then
		return
	end
	-- Reserve before ComputeAsync yields. Heartbeat must never start a second
	-- request for this agent, or wait on one enemy before stepping the others.
	self.computing = true
	activeComputes += 1
	self.lastGoal = goal
	self.lastRepath = os.clock()
	self.repaths += 1
	self.arrived = false
	local generation = self.generation
	local from = positionOf(self.model)
	--[[
		Stop short, on the path rather than at the end of it.

		Walking all the way to a target's centre means ending up inside it,
		which for a melee enemy reads as clipping and for a follower reads as
		shoving. Trimming the goal along the approach keeps the standoff
		without needing a second path.
	]]
	if self.standoff > 0 then
		local away = from - goal
		local flat = Vector3.new(away.X, 0, away.Z)
		if flat.Magnitude > self.standoff then
			goal = goal + flat.Unit * self.standoff
		end
	end

	self.approachGoal = goal
	task.spawn(function()
		local ok, waypoints, status = pcall(Nav.computePath, from, goal, self.parameters)
		activeComputes -= 1
		self.computing = false
		if self.stopped or self.generation ~= generation then
			return
		end
		self.status = if ok then status else "Error: " .. tostring(waypoints)
		self.waypoints = if ok then waypoints else {}
		self.index = 1
		if self.status ~= "Success" then
			self.failures += 1
		end
	end)
end

function Agent:_step()
	if self.stopped then
		return
	end
	local humanoid = humanoidOf(self.model)
	if not humanoid or not self.model.Parent then
		self:stop()
		return
	end

	local goal = self:_resolveTarget()
	if not goal then
		return
	end

	local now = os.clock()
	local here = positionOf(self.model)
	local distance = Vector3.new(here.X - goal.X, 0, here.Z - goal.Z).Magnitude
	local withinGoal = distance <= self.standoff + Nav.config.waypointReached
		and math.abs(here.Y - goal.Y) <= (self.parameters and self.parameters.AgentHeight or Nav.defaults.AgentHeight)
	if withinGoal then
		if not self.arrived then
			self.arrived = true
			self.generation += 1
			self.waypoints = {}
			humanoid:MoveTo(here)
			if self.onArrive then
				task.spawn(self.onArrive, self.model)
			end
		end
		self.lastProgress = now
		return
	end
	if self.arrived then
		self.arrived = false
		self.lastGoal = nil
	end
	local moved = not self.lastGoal or (goal - self.lastGoal).Magnitude > Nav.config.repathDistance
	if moved and now - self.lastRepath >= Nav.config.repathSeconds then
		self:_repath(goal)
	elseif #self.waypoints == 0 and now - self.lastRepath >= Nav.config.repathSeconds then
		self:_repath(goal)
	end

	--[[
		Stuck detection.

		A computed path is a claim about geometry, not about physics. Humanoids
		catch on corners, get shoved by other actors and fail to climb ledges
		the navmesh believed were fine. Noticing that nothing has moved and
		asking for a new path is what turns a permanent wedge into a stumble.
	]]
	if (here - self.lastPosition).Magnitude > Nav.config.stuckDistance then
		self.lastPosition = here
		self.lastProgress = now
	elseif now - self.lastProgress > Nav.config.stuckSeconds then
		self.stucks += 1
		self.lastProgress = now
		if self.onStuck then
			task.spawn(self.onStuck, self.model)
		end
		self:_repath(goal)
	end

	-- No route: fall back to walking at it. Worse, but not frozen.
	if self.status ~= "Success" or #self.waypoints == 0 then
		if not self.computing then
			humanoid:MoveTo(self.approachGoal or goal)
		end
		return
	end

	local waypoint = self.waypoints[self.index]
	if not waypoint then
		self:_repath(goal)
		return
	end

	if (Vector3.new(here.X, 0, here.Z) - Vector3.new(waypoint.Position.X, 0, waypoint.Position.Z)).Magnitude
		< Nav.config.waypointReached then
		self.index += 1
		waypoint = self.waypoints[self.index]
		if not waypoint then
			-- The last waypoint being nearby is not proof the goal was reached.
			self:_repath(goal)
			return
		end
	end

	if waypoint.Action == Enum.PathWaypointAction.Jump then
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end
	humanoid:MoveTo(waypoint.Position)
end

function Agent:stop()
	self.stopped = true
	self.generation += 1
	agents[self.model] = nil
	local humanoid = humanoidOf(self.model)
	if humanoid and self.model.Parent then
		humanoid:MoveTo(positionOf(self.model))
	end
end

function Agent:describe(): { [string]: any }
	return {
		status = self.status,
		waypoints = #self.waypoints,
		index = self.index,
		repaths = self.repaths,
		failures = self.failures,
		stucks = self.stucks,
		arrived = self.arrived,
		computing = self.computing,
	}
end

--[[
	Put an actor on a path and keep it there.

	`target` may be a Vector3, a Model, or a function returning either — the
	function form is what makes chasing work, because the goal is re-read every
	step rather than captured once.
]]
function Nav.follow(model: Model, options: any?): any
	local opts = options or {}
	local existing = agents[model]
	if existing then
		existing:stop()
	end

	local agent = setmetatable({
		model = model,
		target = opts.target,
		standoff = opts.standoff or 0,
		parameters = opts.parameters,
		onArrive = opts.onArrive,
		onStuck = opts.onStuck,
		waypoints = {},
		index = 1,
		status = "Idle",
		lastGoal = nil,
		lastRepath = -math.huge,
		lastPosition = positionOf(model),
		lastProgress = os.clock(),
		repaths = 0,
		failures = 0,
		stucks = 0,
		arrived = false,
		computing = false,
		stopped = false,
		generation = 0,
	}, Agent)

	agents[model] = agent
	Nav.start()
	return agent
end

function Nav.stop(model: Model)
	local agent = agents[model]
	if agent then
		agent:stop()
	end
end

--[[
	One connection for every agent.

	The alternative — a coroutine per enemy — is the pattern this engine exists
	to avoid: two hundred actors become two hundred schedulable threads and the
	frame time stops being anybody's fault in particular.
]]
function Nav.start()
	if connection then
		return
	end
	connection = RunService.Heartbeat:Connect(function()
		local live = 0
		for model, agent in agents do
			if not model.Parent then
				agent:stop()
				continue
			end
			live += 1
			agent:_step()
		end
		if live == 0 and connection then
			connection:Disconnect()
			connection = nil
		end
	end)
end

function Nav.agentCount(): number
	local n = 0
	for _ in agents do
		n += 1
	end
	return n
end

--[[
	Mark something as a cost or a blocker for pathfinding.

	Roblox reads `PathfindingModifier` off parts, which is the only way to say
	"this is water, prefer to go around" or "this door is passable". Wrapped
	here so a game never has to name the class.
]]
function Nav.modifier(part: BasePart, label: string, passthrough: boolean?)
	local existing = part:FindFirstChildOfClass("PathfindingModifier")
	local modifier = existing or Instance.new("PathfindingModifier")
	modifier.Label = label
	modifier.PassThrough = passthrough == true
	modifier.Parent = part
	return modifier
end

function Nav.setCosts(costs: { [string]: number }, parameters: any?)
	local params = parameters or Nav.defaults
	params.Costs = costs
	return params
end

function Nav.describe(): { [string]: any }
	local statuses: { [string]: number } = {}
	for _, agent in agents do
		statuses[agent.status] = (statuses[agent.status] or 0) + 1
	end
	return {
		agents = Nav.agentCount(),
		statuses = statuses,
		running = connection ~= nil,
		activeComputes = activeComputes,
	}
end

return Nav
