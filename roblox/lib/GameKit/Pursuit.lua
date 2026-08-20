--!strict
--- Movement with intent: chase, flee, patrol.
---
--- The creature in the horror game walked a lane on a timer. It never looked at
--- the player, never changed course, and could be outrun by standing still.
--- That is a moving prop, not a threat, and it was the largest single gap
--- between what the factory built and what a player would call a game.
---
--- What makes this hard is not the pathfinding call -- it is everything around
--- it. A path computed once is wrong the moment the target moves. A path
--- recomputed every frame costs more than the game has. And a humanoid that
--- walks into a doorframe will stand there pressing forever unless something
--- notices.
---
--- So this module is a small state machine per pursuer, ticked on a shared
--- heartbeat:
---
---   * repath on an interval, or early when the target has moved far enough
---     that the current path is stale
---   * walk the waypoints one at a time, jumping when the path says to
---   * detect being stuck -- no progress across two ticks -- and repath rather
---     than press into the wall
---   * give up when the path cannot be computed at all, and say so, rather
---     than silently standing still
---
--- **One heartbeat for every pursuer.** Twenty creatures each with their own
--- `RunService` connection and their own `ComputeAsync` is how a scene drops to
--- 15fps. They share a tick, and repaths are spread across it.

local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Pursuit = {}

export type Mode = "chase" | "flee" | "patrol"

export type Spec = {
	mode: Mode,
	speed: number?,
	--- How close counts as arrived, in studs.
	reach: number?,
	--- Flee only: how far away is far enough to stop running.
	safe: number?,
	--- Patrol only: the points to walk, in order, looping.
	points: { Vector3 }?,
	--- Stop pursuing past this distance; nil means never stop.
	giveUp: number?,
	agent: { [string]: any }?,
	--- What crossing each kind of `PathfindingLink` is worth. Lower is more
	--- attractive; a creature that should never take the ladder gets
	--- `math.huge` rather than having the ladder removed.
	costs: { [string]: number }?,
}

export type Driver = {
	kind: string,
	humanoid: Humanoid?,
	root: BasePart,
}

export type Pursuer = {
	model: Model,
	driver: Driver,
	humanoid: Humanoid?,
	root: BasePart,
	spec: Spec,
	target: (() -> Instance?)?,
	--- Set by stop(); the tick drops it on the next pass.
	stopped: boolean,
	waypoints: { PathWaypoint },
	index: number,
	lastPathAt: number,
	lastTargetPosition: Vector3?,
	lastOwnPosition: Vector3?,
	stuckTicks: number,
	failures: number,
	patrolIndex: number,
	--- Half the model's height: how far its pivot rides above the floor the
	--- waypoints describe. Zero for humanoids, which walk themselves.
	hover: number,
	state: string,
}

--- How often a pursuer may recompute, in seconds. Below this the cost shows up
--- in the frame time long before the behaviour looks any better.
local REPATH_INTERVAL = 0.6

--- How far the target must move before the path is recomputed. A target that
--- stands still does not deserve a repath; one that ran round a corner does.
local REPATH_DISTANCE = 6

--- The safety net, in seconds. Long enough that a creature can walk a whole
--- path before it fires -- it exists for a pursuer whose target vanished in a
--- way the other triggers missed, not as the normal cadence.
local REPATH_CEILING = 8.0

--- Progress under this much across a tick counts as no progress. Two in a row
--- and the pursuer is stuck.
local PROGRESS_EPSILON = 0.6

--- Consecutive failed path computations before the pursuer gives up and says so.
--- One failure is a target inside geometry for a frame; four is unreachable.
local MAX_FAILURES = 4

local active: { [Model]: Pursuer } = {}
local heartbeat: RBXScriptConnection? = nil
local accumulator = 0

--- How a model is made to move, chosen once when pursuit starts.
---
--- Not every creature is a humanoid. `WorldKit.Threat` builds a faceless
--- pilgrim as an anchored Model with a PrimaryPart and no Humanoid at all --
--- and the first version of this module refused it outright, which would have
--- made pursuit a feature only R15 characters could have. Floating orbs,
--- drones, rolling boulders and every stylised enemy have the same shape.
---
--- So pathfinding is shared and only the last step differs: a humanoid gets
--- `MoveTo` and walks under its own physics; anything else has its pivot
--- advanced towards the waypoint at the given speed. Both follow the same
--- waypoints round the same geometry.
local function driverFor(model: Model): (Driver?, string?)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if humanoid ~= nil and root ~= nil and root:IsA("BasePart") then
		return { kind = "humanoid", humanoid = humanoid, root = root }, nil
	end
	local primary = model.PrimaryPart
	if primary == nil then
		for _, item in ipairs(model:GetChildren()) do
			if item:IsA("BasePart") then
				primary = item
				break
			end
		end
	end
	if primary == nil then
		return nil, model.Name .. " has neither a Humanoid nor any BasePart, so nothing can move it"
	end
	return { kind = "pivot", humanoid = nil, root = primary }, nil
end

--- The nearest player character, which is what "the player" means when a rule
--- does not name one. Returns nil rather than guessing when nobody is alive --
--- a creature chasing a corpse is a bug that reads as a physics glitch.
function Pursuit.nearestPlayer(from: Vector3, within: number?): Model?
	local best: Model? = nil
	local bestDistance = within or math.huge
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character ~= nil then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = character:FindFirstChild("HumanoidRootPart")
			if humanoid ~= nil and humanoid.Health > 0 and root ~= nil and root:IsA("BasePart") then
				local distance = (root.Position - from).Magnitude
				if distance < bestDistance then
					best, bestDistance = character, distance
				end
			end
		end
	end
	return best
end

local function positionOf(thing: Instance?): Vector3?
	if thing == nil then
		return nil
	end
	if thing:IsA("BasePart") then
		return thing.Position
	end
	if thing:IsA("Model") then
		local primary = thing.PrimaryPart or thing:FindFirstChild("HumanoidRootPart")
		if primary ~= nil and primary:IsA("BasePart") then
			return primary.Position
		end
		local ok, cframe = pcall(function()
			return thing:GetPivot()
		end)
		if ok then
			return cframe.Position
		end
	end
	return nil
end

--- Where a pursuer actually wants to stand right now.
---
--- Chase walks at the target. Flee walks directly away from it -- computed as a
--- point on the far side, because pathfinding needs a destination and "not
--- here" is not one. Patrol ignores the target entirely and walks its ring.
local function destinationFor(pursuer: Pursuer, targetPosition: Vector3?): Vector3?
	local mode = pursuer.spec.mode
	local here = pursuer.root.Position

	if mode == "patrol" then
		local points = pursuer.spec.points
		if points == nil or #points == 0 then
			return nil
		end
		local point = points[((pursuer.patrolIndex - 1) % #points) + 1]
		if (point - here).Magnitude <= (pursuer.spec.reach or 4) then
			pursuer.patrolIndex += 1
			point = points[((pursuer.patrolIndex - 1) % #points) + 1]
		end
		return point
	end

	if targetPosition == nil then
		return nil
	end

	if mode == "flee" then
		local away = here - targetPosition
		if away.Magnitude < 0.1 then
			away = Vector3.new(1, 0, 0)
		end
		local safe = pursuer.spec.safe or 60
		return here + away.Unit * safe
	end

	return targetPosition
end

local function repath(pursuer: Pursuer, destination: Vector3): boolean
	local agent = pursuer.spec.agent or {
		AgentRadius = 2.5,
		AgentHeight = 5,
		AgentCanJump = true,
		-- Named links let a path cross what the navmesh cannot: a ladder, a
		-- rope bridge, a gap that has to be jumped deliberately. Without a
		-- `Costs` table the pathfinder ignores every `PathfindingLink` in the
		-- place, so a creature simply refuses to leave its island and reports
		-- `unreachable` -- which reads as a bug in the pathfinding rather than
		-- as a missing declaration.
		Costs = pursuer.spec.costs or {
			Jump = 4,
			Climb = 2,
			Field = 1,
		},
	}
	local path = PathfindingService:CreatePath(agent)
	local ok = pcall(function()
		path:ComputeAsync(pursuer.root.Position, destination)
	end)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		pursuer.failures += 1
		if pursuer.failures >= MAX_FAILURES then
			pursuer.state = "unreachable"
		end
		return false
	end
	pursuer.failures = 0
	pursuer.waypoints = path:GetWaypoints()
	pursuer.index = 1
	pursuer.lastPathAt = os.clock()
	pursuer.state = pursuer.spec.mode
	return true
end

--- Stop moving, whichever way this pursuer moves.
local function halt(pursuer: Pursuer)
	if pursuer.driver.humanoid ~= nil then
		pursuer.driver.humanoid:Move(Vector3.zero)
	end
end

--- Advance one tick towards `waypoint`. Humanoids walk themselves; everything
--- else is carried, turned to face where it is going so a pilgrim gliding
--- backwards does not read as a bug.
---
--- **The carried path is horizontal.** Waypoints sit on the navmesh, which is
--- the floor -- and the first version aimed the model's *pivot* straight at
--- them. A pivot is the centre of the model, so the creature sank half its own
--- height into the ground over a few seconds, at which point pathfinding
--- started failing from inside the terrain and it stopped dead 17 studs from
--- where it began. Measured, not guessed: the trail read
--- `62,60 / 65,59 / ... / 77,62 / 77,62 / 77,62`.
---
--- So travel is computed in the XZ plane at the requested speed, and the height
--- is set from the waypoint plus half the model's own bounding box. A creature
--- rides the floor whatever its size.
local function advance(pursuer: Pursuer, waypoint: PathWaypoint, delta: number)
	if pursuer.driver.humanoid ~= nil then
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			pursuer.driver.humanoid.Jump = true
		end
		pursuer.driver.humanoid:MoveTo(waypoint.Position)
		return
	end

	local here = pursuer.model:GetPivot().Position
	-- A carried creature has no physics to jump with, so a `Jump` waypoint is
	-- honoured by lifting it along the arc instead. Without this it walks into
	-- the gap a humanoid would have crossed and reports `unreachable`.
	local arc = if waypoint.Action == Enum.PathWaypointAction.Jump
		then math.max(waypoint.Position.Y - here.Y, 0) + 2 else 0
	local flatHere = Vector3.new(here.X, 0, here.Z)
	local flatThere = Vector3.new(waypoint.Position.X, 0, waypoint.Position.Z)
	local toward = flatThere - flatHere
	if toward.Magnitude < 0.05 then
		return
	end

	local speed = pursuer.spec.speed or 10
	local travel = math.min(speed * delta, toward.Magnitude)
	local step = flatHere + toward.Unit * travel
	local ride = waypoint.Position.Y + pursuer.hover + arc
	local next = Vector3.new(step.X, ride, step.Z)

	pursuer.model:PivotTo(CFrame.lookAt(next, next + toward.Unit))
end

local function step(pursuer: Pursuer, delta: number)
	if pursuer.stopped then
		return
	end
	if pursuer.driver.humanoid ~= nil and pursuer.driver.humanoid.Health <= 0 then
		return
	end

	local target = if pursuer.target ~= nil then pursuer.target() else nil
	local targetPosition = positionOf(target)
	local here = pursuer.root.Position

	-- Out of range is a real state, not a failure: a creature that keeps
	-- pathing to a player three regions away burns CPU for nothing.
	if pursuer.spec.giveUp ~= nil and targetPosition ~= nil
		and (targetPosition - here).Magnitude > pursuer.spec.giveUp then
		halt(pursuer)
		pursuer.state = "idle"
		return
	end

	-- Flee stops once it is far enough. Without this the creature runs to the
	-- edge of the map and presses into the boundary forever.
	if pursuer.spec.mode == "flee" and targetPosition ~= nil then
		if (targetPosition - here).Magnitude >= (pursuer.spec.safe or 60) then
			halt(pursuer)
			pursuer.state = "safe"
			return
		end
	end

	local moved = if pursuer.lastTargetPosition ~= nil and targetPosition ~= nil
		then (targetPosition - pursuer.lastTargetPosition).Magnitude
		else math.huge

	-- **Not "the path is old".** Every repath resets the waypoint index to 1,
	-- so recomputing merely because time passed means a creature restarts its
	-- journey every REPATH_INTERVAL and can never finish a long one. It looked
	-- fine on a short chase round a wall, where each new path pointed the same
	-- way; over a 100-stud crossing it oscillated within five studs of where it
	-- started, forever.
	--
	-- So age alone is not a reason. The path is recomputed when the target has
	-- actually moved, when the waypoints run out, when progress stops -- and, as
	-- a safety net far above the journey time, when it is genuinely ancient.
	local stale = os.clock() - pursuer.lastPathAt > REPATH_CEILING
	local drifted = moved > REPATH_DISTANCE
	local exhausted = pursuer.index > #pursuer.waypoints

	-- No progress twice running means the humanoid is pressed against
	-- something the path thought was open. Repathing from where it actually is
	-- gets it round; pressing harder does not.
	if pursuer.lastOwnPosition ~= nil
		and (here - pursuer.lastOwnPosition).Magnitude < PROGRESS_EPSILON then
		pursuer.stuckTicks += 1
	else
		pursuer.stuckTicks = 0
	end
	pursuer.lastOwnPosition = here

	if stale or drifted or exhausted or pursuer.stuckTicks >= 2 then
		local destination = destinationFor(pursuer, targetPosition)
		if destination ~= nil then
			repath(pursuer, destination)
			pursuer.stuckTicks = 0
		elseif targetPosition == nil then
			halt(pursuer)
			pursuer.state = "idle"
			return
		end
		pursuer.lastTargetPosition = targetPosition
	end

	local waypoint = pursuer.waypoints[pursuer.index]
	if waypoint == nil then
		return
	end

	-- Consume every waypoint already within reach, not one per tick. `reach` is
	-- often larger than the navmesh's waypoint spacing, and advancing a single
	-- index per tick made the creature aim at points it had already passed.
	local reach = pursuer.spec.reach or 3
	while waypoint ~= nil
		and (Vector3.new(here.X, waypoint.Position.Y, here.Z) - waypoint.Position).Magnitude <= reach do
		pursuer.index += 1
		waypoint = pursuer.waypoints[pursuer.index]
	end
	if waypoint == nil then
		return
	end

	advance(pursuer, waypoint, delta)
end

local function ensureHeartbeat()
	if heartbeat ~= nil then
		return
	end
	-- One connection for every pursuer in the game. Ticked at 10Hz because
	-- pathfinding is not a per-frame problem and MoveTo interpolates between.
	heartbeat = RunService.Heartbeat:Connect(function(delta)
		accumulator += delta
		if accumulator < 0.1 then
			return
		end
		accumulator = 0
		for model, pursuer in pairs(active) do
			local dead = pursuer.driver.humanoid ~= nil
				and pursuer.driver.humanoid.Health <= 0
			if pursuer.stopped or model.Parent == nil or dead then
				active[model] = nil
			else
				-- One creature failing must not stop the rest of them moving.
				local ok, err = pcall(step, pursuer, 0.1)
				if not ok then
					warn("[Pursuit] " .. model.Name .. ": " .. tostring(err))
					active[model] = nil
				end
			end
		end
		if next(active) == nil and heartbeat ~= nil then
			heartbeat:Disconnect()
			heartbeat = nil
		end
	end)
end

--- Give a model intent. Returns nil and a reason when it cannot move.
function Pursuit.start(model: Model, spec: Spec, target: (() -> Instance?)?): (Pursuer?, string?)
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return nil, "pursuit needs a Model"
	end
	local driver, why = driverFor(model)
	if driver == nil then
		return nil, why
	end
	if spec.mode ~= "chase" and spec.mode ~= "flee" and spec.mode ~= "patrol" then
		return nil, "mode must be chase, flee or patrol"
	end
	if spec.mode == "patrol" and (spec.points == nil or #spec.points < 2) then
		return nil, "patrol needs at least two points"
	end

	Pursuit.stop(model)

	if driver.humanoid ~= nil and spec.speed ~= nil then
		driver.humanoid.WalkSpeed = spec.speed
	end
	-- An anchored part ignores MoveTo *and* PivotTo-driven physics settling;
	-- unanchoring it would drop a pilgrim through the floor it was placed on.
	-- Carrying an anchored model is exactly what the pivot driver does, so the
	-- anchor stays and the movement is kinematic.
	local hover = 0
	if driver.humanoid == nil then
		local ok, _, size = pcall(function()
			return model:GetBoundingBox()
		end)
		local extents = if ok and typeof(size) == "Vector3" then size else driver.root.Size
		hover = extents.Y / 2
	end

	local pursuer: Pursuer = {
		model = model,
		driver = driver,
		humanoid = driver.humanoid,
		root = driver.root,
		spec = spec,
		target = target,
		stopped = false,
		waypoints = {},
		index = 1,
		lastPathAt = 0,
		lastTargetPosition = nil,
		lastOwnPosition = nil,
		stuckTicks = 0,
		failures = 0,
		patrolIndex = 1,
		hover = hover,
		state = "starting",
	}
	active[model] = pursuer
	model:SetAttribute("PursuitMode", spec.mode)
	ensureHeartbeat()
	return pursuer, nil
end

function Pursuit.stop(model: Model)
	local pursuer = active[model]
	if pursuer ~= nil then
		pursuer.stopped = true
		pcall(halt, pursuer)
		active[model] = nil
	end
	if typeof(model) == "Instance" then
		model:SetAttribute("PursuitMode", nil)
	end
end

function Pursuit.stopAll()
	for model in pairs(active) do
		Pursuit.stop(model)
	end
end

--- What is moving and why. The probe that makes pursuit checkable from outside
--- without watching it -- a test can assert `chasing == 3`, and evidence can
--- record a state rather than a screenshot of a blur.
function Pursuit.report(): { [string]: any }
	local states: { [string]: number } = {}
	local names: { string } = {}
	local count = 0
	for model, pursuer in pairs(active) do
		count += 1
		states[pursuer.state] = (states[pursuer.state] or 0) + 1
		if #names < 12 then
			table.insert(names, model.Name .. ":" .. pursuer.state)
		end
	end
	table.sort(names)
	return { pursuers = count, states = states, sample = names }
end

return Pursuit
