--!strict
-- A player-equivalent actor that an agent can drive.
--
-- Studio's Play Solo cannot be started without real keyboard focus, which would
-- take the screen from whoever is using the machine. Run mode can: it is both
-- server and client, so a rig built here has real physics, real collisions and
-- real ProximityPrompt input. Everything below therefore happens in the engine,
-- not in a simulation of it.
--
-- The honest limit: Run mode has no `Player` object, so game logic gated on
-- `Players.PlayerAdded` does not run for this actor. `actor.state` reports that
-- explicitly rather than letting a caller assume otherwise.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Parent.Errors)
local Navigation = require(script.Parent.Parent.Navigation)
local Refs = require(script.Parent.Parent.Refs)
local Resolve = require(script.Parent.Parent.Resolve)
local Serialize = require(script.Parent.Parent.Serialize)

local ActorCommands = {}

local ACTOR_FOLDER = "RQEActors"
local SETTLE_SECONDS = 1.5

local actors: { [string]: Model } = {}

local function actorFolder(): Folder
	local existing = workspace:FindFirstChild(ACTOR_FOLDER)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = ACTOR_FOLDER
	folder.Parent = workspace
	return folder
end

local function requireRunning()
	if not RunService:IsRunning() then
		Errors.raise(
			Errors.UNSUPPORTED_CONTEXT,
			"actors need a running place; call run.start first",
			{ context = "edit" }
		)
	end
end

local function getActor(id: string?): (string, Model, Humanoid, BasePart)
	if id == nil or id == "" then
		-- Single-actor scenarios are the common case; do not make callers track
		-- an id they never needed.
		local onlyId, onlyModel
		local count = 0
		for actorId, model in pairs(actors) do
			count += 1
			onlyId, onlyModel = actorId, model
		end
		if count == 1 and onlyModel ~= nil then
			id = onlyId
		elseif count == 0 then
			Errors.raise(Errors.NOT_FOUND, "no actor has been spawned; call actor.spawn first")
		else
			Errors.raise(Errors.BAD_PARAMS, string.format("%d actors exist; pass 'actor' to choose one", count))
		end
	end

	local model = actors[id :: string]
	if model == nil or model.Parent == nil then
		actors[id :: string] = nil
		Errors.raise(Errors.NOT_FOUND, "actor no longer exists", { actor = id })
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") then
		Errors.raise(Errors.EXEC, "actor is missing its Humanoid or HumanoidRootPart", { actor = id })
	end
	return id :: string, model, humanoid :: Humanoid, root :: BasePart
end

--- The Player this model belongs to, when it is a real character.
local function ownerOf(model: Model): Player?
	return Players:GetPlayerFromCharacter(model)
end

local function describe(id: string, model: Model, humanoid: Humanoid, root: BasePart): { [string]: any }
	local owner = ownerOf(model)
	-- No owner stays nil. A real player's Vector3 or Color3 attributes are not
	-- JSON, so each value is encoded the same way dm.tree's attributesOf does.
	local playerAttributes: { [string]: any }? = nil
	if owner ~= nil then
		local encoded: { [string]: any } = {}
		local ok, raw = pcall(function()
			return owner:GetAttributes()
		end)
		if ok then
			for key, value in pairs(raw) do
				encoded[key] = Serialize.value(value)
			end
		end
		playerAttributes = encoded
	end
	return {
		actor = id,
		name = model.Name,
		player = if owner then owner.Name else nil,
		userId = if owner then owner.UserId else nil,
		playerAttributes = playerAttributes,
		ref = Refs.of(model),
		position = Serialize.roundVector(root.Position, 3),
		velocity = Serialize.roundVector(root.AssemblyLinearVelocity, 3),
		health = Serialize.round(humanoid.Health, 2),
		maxHealth = humanoid.MaxHealth,
		walkSpeed = humanoid.WalkSpeed,
		grounded = humanoid.FloorMaterial ~= Enum.Material.Air,
		floorMaterial = tostring(humanoid.FloorMaterial),
		state = tostring(humanoid:GetState()),
		-- Run mode has no Player, so a spawned rig is not one the game assigned a
		-- plot to. Stated in every state read so a caller can never assume.
		isRealPlayer = owner ~= nil,
		playersInGame = #Players:GetPlayers(),
	}
end

--- actor.spawn: put a physical, controllable body in the world.
function ActorCommands.spawn(params: { [string]: any }): any
	requireRunning()

	local description = Instance.new("HumanoidDescription")
	local rigType = if params.rig == "R6" then Enum.HumanoidRigType.R6 else Enum.HumanoidRigType.R15
	local model: Model
	local ok, err = pcall(function()
		model = Players:CreateHumanoidModelFromDescription(description, rigType)
	end)
	if not ok then
		Errors.raise(Errors.EXEC, "could not build an actor rig: " .. tostring(err))
	end

	local id = "actor_" .. string.sub(tostring(math.random(1, 1e9)), 1, 6) .. "_" .. tostring(os.clock()):gsub("%.", "")
	model.Name = tostring(params.name or id)

	-- Spawn above the requested point and let physics seat it, so the actor
	-- starts standing on real ground instead of intersecting it.
	local origin: Vector3
	if params.position ~= nil then
		origin = Errors.expectVector(params, "position")
	elseif params.near ~= nil then
		local anchor = Resolve.spatial(tostring(params.near))
		local cframe, size = Resolve.boundingBox(anchor)
		origin = cframe.Position + Vector3.new(0, size.Y / 2 + 5, 0)
	else
		local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
		origin = if spawn then spawn.Position + Vector3.new(0, 5, 0) else Vector3.new(0, 12, 0)
	end

	model:PivotTo(CFrame.new(origin))
	model.Parent = actorFolder()
	actors[id] = model

	local settle = math.clamp(tonumber(params.settleSeconds) or SETTLE_SECONDS, 0, 10)
	task.wait(settle)

	local _, _, humanoid, root = getActor(id)
	local state = describe(id, model, humanoid, root)
	state.spawnedAt = Serialize.roundVector(origin, 3)
	state.settleSeconds = settle
	return state
end

--- actor.attach: drive a real Player's character as an actor.
---
--- The important one. A spawned rig has real physics but no Player, so the
--- engine has nobody to attribute a ProximityPrompt activation to and the whole
--- prompt-driven half of a tycoon stays untestable. Attaching to a Play Solo
--- player's character makes every actor command operate on the same body the
--- game assigned a plot and a currency balance to.
function ActorCommands.attach(params: { [string]: any }): any
	local player: Player? = nil
	if params.player ~= nil then
		player = Players:FindFirstChild(tostring(params.player)) :: Player?
		if player == nil then
			Errors.raise(Errors.NOT_FOUND, "no such player", { player = params.player })
		end
	else
		player = Players:GetPlayers()[1]
		if player == nil then
			Errors.raise(
				Errors.UNSUPPORTED_CONTEXT,
				"no Player is in the game; start Play Solo first",
				{ hint = "run.start gives physics but no Player; use rqe studio play_solo" }
			)
		end
	end

	local character = (player :: Player).Character
	if character == nil then
		-- A character can lag a moment behind the player joining.
		local deadline = os.clock() + (tonumber(params.timeout) or 10)
		while os.clock() < deadline and character == nil do
			task.wait(0.2)
			character = (player :: Player).Character
		end
	end
	if character == nil then
		Errors.raise(Errors.NOT_FOUND, "the player has no Character yet", { player = (player :: Player).Name })
	end

	local id = "player_" .. tostring((player :: Player).UserId)
	actors[id] = character :: Model

	local _, model, humanoid, root = getActor(id)
	return describe(id, model, humanoid, root)
end

--- actor.despawn: remove one actor, or all of them.
function ActorCommands.despawn(params: { [string]: any }): any
	-- Never destroy a real player's character: releasing the handle is the
	-- correct teardown, killing the player is not.
	local function release(id: string, model: Model): string
		if ownerOf(model) ~= nil then
			actors[id] = nil
			return "detached"
		end
		if model.Parent ~= nil then
			model:Destroy()
		end
		actors[id] = nil
		return "destroyed"
	end

	if params.all == true then
		local removed, detached = 0, 0
		for id, model in pairs(actors) do
			if release(id, model) == "detached" then
				detached += 1
			else
				removed += 1
			end
		end
		return { despawned = removed, detached = detached }
	end
	local id, model = getActor(params.actor)
	local outcome = release(id, model)
	return { despawned = if outcome == "destroyed" then 1 else 0, detached = if outcome == "detached" then 1 else 0, actor = id }
end

function ActorCommands.list(_params: { [string]: any }): any
	local result = {}
	for id, model in pairs(actors) do
		if model.Parent ~= nil then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")
			if humanoid and root and root:IsA("BasePart") then
				table.insert(result, describe(id, model, humanoid, root))
			end
		else
			actors[id] = nil
		end
	end
	return { actors = result, count = #result }
end

function ActorCommands.state(params: { [string]: any }): any
	local id, model, humanoid, root = getActor(params.actor)
	return describe(id, model, humanoid, root)
end

--- actor.walk_to: walk there on real legs, and report what actually happened.
---
--- Never teleports. If the actor cannot reach the target the result is a
--- failure with the distance it stalled at, because "could a player get here"
--- is exactly the question a walk test exists to answer.
function ActorCommands.walkTo(params: { [string]: any }): any
	local id, model, humanoid, root = getActor(params.actor)

	local target: Vector3
	if params.position ~= nil then
		target = Errors.expectVector(params, "position")
	elseif params.target ~= nil then
		local instance = Resolve.spatial(tostring(params.target))
		local cframe = Resolve.boundingBox(instance)
		target = cframe.Position
	else
		Errors.raise(Errors.BAD_PARAMS, "actor.walk_to needs 'position' or 'target'")
	end

	local tolerance = tonumber(params.tolerance) or 4
	local timeout = math.clamp(tonumber(params.timeout) or 15, 1, 60)
	local start = root.Position
	local deadline = os.clock() + timeout

	local samples = {}
	local reached = false
	local stuckFor = 0
	local lastPosition = start

	humanoid:MoveTo(target)
	while os.clock() < deadline do
		task.wait(0.15)
		local position = root.Position
		local flat = Vector3.new(position.X - target.X, 0, position.Z - target.Z).Magnitude
		table.insert(samples, { t = Serialize.round(timeout - (deadline - os.clock()), 2), pos = Serialize.roundVector(position, 2), distance = Serialize.round(flat, 2) })

		if flat <= tolerance then
			reached = true
			break
		end
		if (position - lastPosition).Magnitude < 0.05 then
			stuckFor += 0.15
		else
			stuckFor = 0
		end
		lastPosition = position
		-- Re-issue: MoveTo expires and a single call will not cross a long path.
		humanoid:MoveTo(target)
	end

	local final = root.Position
	local flatDistance = Vector3.new(final.X - target.X, 0, final.Z - target.Z).Magnitude
	return {
		success = reached,
		actor = id,
		target = Serialize.roundVector(target, 3),
		from = Serialize.roundVector(start, 3),
		to = Serialize.roundVector(final, 3),
		remainingDistance = Serialize.round(flatDistance, 3),
		travelled = Serialize.round((final - start).Magnitude, 3),
		tolerance = tolerance,
		timedOut = not reached,
		stalled = stuckFor > 1.0,
		reason = if reached then nil elseif stuckFor > 1.0 then "actor stopped moving before reaching the target" else "did not arrive within the timeout",
		samples = samples,
		state = describe(id, model, humanoid, root),
	}
end

--- actor.navigate_to: walk the route the engine's navmesh actually offers.
---
--- `walk_to` walks a straight line, which answers "is the direct route clear".
--- This answers the different and more important question: "can a player get
--- there at all". Keeping them separate matters -- a straight-line failure with
--- a navigation success is level geometry doing its job, while both failing is
--- an unreachable objective.
function ActorCommands.navigateTo(params: { [string]: any }): any
	local id, model, humanoid, root = getActor(params.actor)

	local targets = Navigation.targetsFrom(params, "position", "target")
	if #targets == 0 then
		Errors.raise(Errors.BAD_PARAMS, "actor.navigate_to needs 'position' or 'target'")
	end

	local start = root.Position
	local agent = Navigation.agentFrom(params)
	local found, chosen, path, attempts = Navigation.firstReachable(start, targets, agent)

	if not found or path == nil then
		local usable, controlStatus = Navigation.navmeshUsable(start, agent)
		return {
			success = false,
			actor = id,
			reason = "no_path",
			pathStatus = attempts[#attempts] and attempts[#attempts].status or "NoPath",
			attempts = attempts,
			navmeshUsable = usable,
			controlStatus = controlStatus,
			from = Serialize.roundVector(start, 3),
			target = Serialize.roundVector(chosen.point, 3),
			state = describe(id, model, humanoid, root),
		}
	end

	local target = chosen.point
	local waypoints = path:GetWaypoints()
	local tolerance = tonumber(params.tolerance) or 4
	local timeout = math.clamp(tonumber(params.timeout) or 40, 1, 120)
	local deadline = os.clock() + timeout
	local reachedIndex = 0

	for index, waypoint in ipairs(waypoints) do
		if os.clock() >= deadline then
			break
		end
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end
		humanoid:MoveTo(waypoint.Position)

		local waypointDeadline = math.min(deadline, os.clock() + 8)
		while os.clock() < waypointDeadline do
			task.wait(0.1)
			local flat = Vector3.new(root.Position.X - waypoint.Position.X, 0, root.Position.Z - waypoint.Position.Z).Magnitude
			if flat <= math.max(tolerance, 3) then
				break
			end
			humanoid:MoveTo(waypoint.Position)
		end
		reachedIndex = index
	end

	local final = root.Position
	local remaining = Vector3.new(final.X - target.X, 0, final.Z - target.Z).Magnitude
	local arrived = remaining <= tolerance

	return {
		success = arrived,
		actor = id,
		from = Serialize.roundVector(start, 3),
		to = Serialize.roundVector(final, 3),
		target = Serialize.roundVector(target, 3),
		remainingDistance = Serialize.round(remaining, 3),
		travelled = Serialize.round((final - start).Magnitude, 3),
		waypointCount = #waypoints,
		waypointsReached = reachedIndex,
		pathStatus = tostring(path.Status),
		approach = chosen.name,
		attempts = attempts,
		timedOut = os.clock() >= deadline and not arrived,
		reason = if arrived then nil else "did not arrive within the timeout",
		state = describe(id, model, humanoid, root),
	}
end

function ActorCommands.jump(params: { [string]: any }): any
	local id, model, humanoid, root = getActor(params.actor)
	local before = root.Position
	humanoid.Jump = true
	task.wait(0.35)
	local peak = root.Position
	task.wait(0.9)
	return {
		success = peak.Y > before.Y + 0.5,
		actor = id,
		riseY = Serialize.round(peak.Y - before.Y, 3),
		landed = humanoid.FloorMaterial ~= Enum.Material.Air,
		state = describe(id, model, humanoid, root),
	}
end

--- actor.interact: activate a ProximityPrompt the way a player does.
---
--- Refuses when the actor is out of the prompt's activation range: that is the
--- engine's own rule, and honouring it is what makes a pass mean "a player
--- standing here could do this".
function ActorCommands.interact(params: { [string]: any }): any
	local id, model, humanoid, root = getActor(params.actor)
	local promptPath = Errors.expect(params, "prompt", "string")
	local instance = Resolve.instance(promptPath)
	if not instance:IsA("ProximityPrompt") then
		Errors.raise(Errors.BAD_PARAMS, string.format("%s is a %s, not a ProximityPrompt", instance:GetFullName(), instance.ClassName))
	end
	local prompt = instance :: ProximityPrompt

	local anchor = prompt.Parent
	local anchorPosition = if anchor and anchor:IsA("BasePart") then anchor.Position else root.Position
	local distance = (anchorPosition - root.Position).Magnitude

	if not prompt.Enabled then
		return { success = false, actor = id, prompt = prompt:GetFullName(), reason = "prompt_disabled", distance = Serialize.round(distance, 2) }
	end
	if distance > prompt.MaxActivationDistance then
		return {
			success = false,
			actor = id,
			prompt = prompt:GetFullName(),
			reason = "out_of_range",
			distance = Serialize.round(distance, 2),
			maxActivationDistance = prompt.MaxActivationDistance,
		}
	end

	-- Listen before acting: a prompt that never fires is the failure we are
	-- looking for, and only the signal can prove it fired.
	local fired = false
	local firedFor: string? = nil
	local connection = prompt.Triggered:Connect(function(player)
		fired = true
		firedFor = if player then player.Name else nil
	end)

	local hold = math.max(prompt.HoldDuration, tonumber(params.holdSeconds) or 0) + 0.2

	-- Driven from the client, because that is the only place it works.
	--
	-- `InputHoldBegin` is a client method. Called from here -- the plugin lives
	-- in the server DataModel -- it is accepted and `Triggered` never fires, so
	-- this used to return `prompt_did_not_fire`: an honest sentence about the
	-- game, describing a fault in the wire. Measured on one prompt in one
	-- session: this path said the prompt did not fire while the client relay
	-- said `triggered: true` and the game's own counter moved.
	--
	-- Falls back to the local call rather than refusing outright, so a session
	-- with no client half still gets whatever the plugin can manage -- and says
	-- below that it could not observe the result.
	local relayed = false
	local ok, err = pcall(function()
		local ClientCommands = require(script.Parent.Client)
		ClientCommands.invoke("prompt_trigger", {
			path = prompt:GetFullName(),
			holdSeconds = hold,
			player = params.player,
		})
		relayed = true
	end)
	if not ok then
		ok, err = pcall(function()
			prompt:InputHoldBegin()
			task.wait(hold)
			prompt:InputHoldEnd()
		end)
	end
	task.wait(0.4)
	connection:Disconnect()

	-- Diagnose a silent failure precisely. The engine attributes a prompt
	-- activation to a Player, and Run mode has none -- so InputHoldBegin is
	-- accepted and Triggered simply never fires. Reporting that as a bare
	-- "false" would send an agent hunting a bug in the game that is not there.
	local reason: string? = nil
	local requiresRealPlayer = false
	local notValidated = false
	if not ok then
		reason = "input_rejected"
	elseif not fired then
		if #Players:GetPlayers() == 0 and Players.LocalPlayer == nil then
			reason = "no_player_to_attribute_the_trigger_to"
			requiresRealPlayer = true
		elseif not relayed then
			-- The distinction that matters. Without the client relay this
			-- command physically cannot make a prompt fire, so "it did not
			-- fire" is a statement about this function and not about the game.
			-- Reporting it as a product failure is how an agent loses an hour
			-- in a handler that works.
			reason = "instrument_cannot_trigger_from_this_datamodel"
			notValidated = true
		else
			reason = "prompt_did_not_fire"
		end
	end

	return {
		success = ok and fired,
		-- `NOT_VALIDATED` rather than a verdict. The caller must be able to tell
		-- "the game refused" from "nothing here could ask it".
		notValidated = notValidated,
		relayedToClient = relayed,
		triggered = fired,
		actor = id,
		prompt = prompt:GetFullName(),
		actionText = prompt.ActionText,
		distance = Serialize.round(distance, 2),
		maxActivationDistance = prompt.MaxActivationDistance,
		holdSeconds = Serialize.round(hold, 2),
		triggered = fired,
		triggeredFor = firedFor,
		inputError = if ok then nil else tostring(err),
		reason = reason,
		-- True means: this is a limit of Run mode, not a defect in the game.
		requiresRealPlayer = requiresRealPlayer,
		hint = if requiresRealPlayer
			then "ProximityPrompt activation needs a real Player; start Play Solo (rqe studio play_solo) to exercise prompt-driven gameplay"
			else nil,
		state = describe(id, model, humanoid, root),
	}
end

--- actor.touch: walk into something and report whether Touched fired.
function ActorCommands.touch(params: { [string]: any }): any
	local id, model, humanoid, root = getActor(params.actor)
	local instance = Resolve.instance(Errors.expect(params, "target", "string"))
	if not instance:IsA("BasePart") then
		Errors.raise(Errors.BAD_PARAMS, string.format("%s is a %s, not a BasePart", instance:GetFullName(), instance.ClassName))
	end
	local part = instance :: BasePart

	local touched = false
	local connection = part.Touched:Connect(function(hit)
		if hit:IsDescendantOf(model) then
			touched = true
		end
	end)

	local timeout = math.clamp(tonumber(params.timeout) or 12, 1, 45)
	local deadline = os.clock() + timeout
	while os.clock() < deadline and not touched do
		humanoid:MoveTo(part.Position)
		task.wait(0.15)
	end
	connection:Disconnect()

	return {
		success = touched,
		actor = id,
		target = part:GetFullName(),
		distance = Serialize.round((part.Position - root.Position).Magnitude, 2),
		reason = if touched then nil else "never_touched_within_timeout",
		state = describe(id, model, humanoid, root),
	}
end

--- actor.prompts: what could a player interact with from where they stand?
function ActorCommands.prompts(params: { [string]: any }): any
	local id, _model, _humanoid, root = getActor(params.actor)
	local radius = tonumber(params.radius) or 60

	local nearby = {}
	for _, item in ipairs(workspace:GetDescendants()) do
		if item:IsA("ProximityPrompt") then
			local anchor = item.Parent
			if anchor and anchor:IsA("BasePart") then
				local distance = (anchor.Position - root.Position).Magnitude
				if distance <= radius then
					table.insert(nearby, {
						path = item:GetFullName(),
						ref = Refs.of(item),
						actionText = item.ActionText,
						objectText = item.ObjectText,
						distance = Serialize.round(distance, 2),
						maxActivationDistance = item.MaxActivationDistance,
						inRange = distance <= item.MaxActivationDistance,
						enabled = item.Enabled,
					})
				end
			end
		end
	end

	table.sort(nearby, function(a, b)
		return a.distance < b.distance
	end)

	return { actor = id, radius = radius, count = #nearby, prompts = nearby }
end

return ActorCommands
