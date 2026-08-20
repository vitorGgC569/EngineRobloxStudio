--!strict
--[[
	Actor — state machines, perception and population, for things that think.

	Roblox teaches a bad habit: one script per NPC, each with its own
	`while true do task.wait() end`. Two hundred enemies become two hundred
	scheduler entries and a server that dies at forty.

	Here every actor is a table, every brain is a data-declared state machine,
	and all of them tick in one sliced group. Two hundred actors cost one
	connection and a quarter of them think per frame.

		Actor.defineBrain("wolf", {
			initial = "idle",
			states = {
				idle = {
					update = function(a, dt) a:wander(20) end,
					transitions = {
						{ to = "chase", when = function(a) return a:nearestPlayer(46) ~= nil end },
					},
				},
				chase = {
					enter = function(a) a:play("run") end,
					update = function(a) a:pursue(a.target) end,
					transitions = {
						{ to = "attack", when = function(a) return a:distanceTo(a.target) < 7 end },
						{ to = "idle",   when = function(a) return a:leashed() end },
					},
				},
				attack = { ... },
			},
		})

		local wolf = Actor.spawn(model, "wolf", { home = position, leash = 130 })

	The engine runs the machine. What the states mean is entirely yours.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Signal = require(script.Parent.Core.Signal)
local Sched = require(script.Parent.Core.Sched)
local Combat = require(script.Parent.Combat)

local Actor = {}

Actor.spawned = Signal.new() -- (actor)
Actor.despawned = Signal.new() -- (actor, reason)
Actor.stateChanged = Signal.new() -- (actor, from, to)

local brains: { [string]: any } = {}
local actors: { [Model]: any } = {}
local group = nil

Actor.config = {
	tickRate = 8, -- state machine ticks per second
	slices = 4, -- spread across this many frames
	logTransitions = false,
}

-- ================================= brains ===================================
function Actor.defineBrain(name: string, brain: any)
	assert(type(brain.states) == "table", "[Actor] brain needs a states table")
	assert(brain.states[brain.initial or "idle"], string.format("[Actor] brain '%s' has no initial state", name))
	brain.initial = brain.initial or "idle"
	brains[name] = brain
	return brain
end

function Actor.brainNames(): { string }
	local out = {}
	for name in brains do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- ================================ instance ==================================
local Instance_ = {}
Instance_.__index = Instance_

function Instance_:isAlive(): boolean
	return self.model.Parent ~= nil and Combat.isAlive(self.model)
end

function Instance_:position(): Vector3
	return self.model:GetPivot().Position
end

function Instance_:distanceTo(other: any): number
	if not other then
		return math.huge
	end
	local otherPos = typeof(other) == "Vector3" and other or (other :: Model):GetPivot().Position
	return (otherPos - self:position()).Magnitude
end

-- flat distance: for chase logic, height difference is almost always noise
function Instance_:flatDistanceTo(other: any): number
	if not other then
		return math.huge
	end
	local a = self:position()
	local b = typeof(other) == "Vector3" and other or (other :: Model):GetPivot().Position
	return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
end

-- ============================== perception ==================================
function Instance_:nearestPlayer(range: number, requireSight: boolean?): Model?
	local origin = self:position()
	local best, bestDist = nil, range
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		if char and Combat.isAlive(char) then
			local d = (char:GetPivot().Position - origin).Magnitude
			if d < bestDist then
				if not requireSight or Combat.canSee(origin + Vector3.new(0, 2, 0), char, { self.model }) then
					best, bestDist = char, d
				end
			end
		end
	end
	return best
end

function Instance_:nearestOf(tag: string, range: number): Model?
	local origin = self:position()
	local best, bestDist = nil, range
	for _, other in actors do
		if other ~= self and other.tag == tag and other:isAlive() then
			local d = (other:position() - origin).Magnitude
			if d < bestDist then
				best, bestDist = other.model, d
			end
		end
	end
	return best
end

function Instance_:canSee(target: Model?): boolean
	if not target then
		return false
	end
	return Combat.canSee(self:position() + Vector3.new(0, 2, 0), target, { self.model })
end

-- Has this actor been pulled too far from where it belongs? The single most
-- important guard against an enemy following a player across the whole map.
function Instance_:leashed(): boolean
	if not self.home or not self.leash then
		return false
	end
	return (self:position() - self.home).Magnitude > self.leash
end

-- ================================ steering ==================================
function Instance_:moveTo(position: Vector3)
	if self.humanoid then
		self.humanoid:MoveTo(position)
		self.destination = position
	end
end

function Instance_:stop()
	if self.humanoid then
		self.humanoid:MoveTo(self:position())
		self.destination = nil
	end
end

function Instance_:pursue(target: Model?, standoff: number?)
	if not target or not target.Parent then
		return
	end
	local targetPos = target:GetPivot().Position
	local gap = standoff or 0
	if gap > 0 then
		local away = (self:position() - targetPos)
		local flat = Vector3.new(away.X, 0, away.Z)
		if flat.Magnitude > 0.01 then
			targetPos += flat.Unit * gap
		end
	end
	self:moveTo(targetPos)
end

function Instance_:retreatFrom(target: Model?, distance: number)
	if not target then
		return
	end
	local away = self:position() - target:GetPivot().Position
	local flat = Vector3.new(away.X, 0, away.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(1, 0, 0)
	end
	self:moveTo(self:position() + flat.Unit * distance)
end

-- Wander that stays near home and does not re-roll every tick.
function Instance_:wander(radius: number, pauseSeconds: number?)
	local now = os.clock()
	if self.destination and now < (self._wanderUntil or 0) then
		return
	end
	self._wanderUntil = now + (pauseSeconds or 3.5)
	local centre = self.home or self:position()
	local angle = math.random() * math.pi * 2
	local dist = math.random() * radius
	self:moveTo(centre + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist))
end

function Instance_:face(target: any, instant: boolean?)
	local root = self.model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local targetPos = typeof(target) == "Vector3" and target or (target :: Model):GetPivot().Position
	local flat = Vector3.new(targetPos.X, root.Position.Y, targetPos.Z)
	if (flat - root.Position).Magnitude < 0.01 then
		return
	end
	if instant then
		root.CFrame = CFrame.lookAt(root.Position, flat)
	else
		self._faceGoal = flat
	end
end

function Instance_:setSpeed(speed: number)
	if self.humanoid then
		self.humanoid.WalkSpeed = speed
	end
end

-- ============================ animation bridge ==============================
function Instance_:play(clipName: string, options: any?)
	if self.animator then
		return self.animator:play(clipName, options)
	end
	return nil
end

-- ============================== cooldowns ===================================
-- Every AI needs these and every AI reimplements them slightly wrong.
function Instance_:ready(key: string, seconds: number): boolean
	local now = os.clock()
	local last = self._cooldowns[key]
	if last and now - last < seconds then
		return false
	end
	self._cooldowns[key] = now
	return true
end

function Instance_:cooling(key: string, seconds: number): boolean
	local last = self._cooldowns[key]
	return last ~= nil and (os.clock() - last) < seconds
end

-- ================================ state =====================================
function Instance_:setState(name: string)
	if self.state == name then
		return
	end
	local brain = brains[self.brain]
	local next_ = brain.states[name]
	if not next_ then
		warn(string.format("[Actor] brain '%s' has no state '%s'", self.brain, name))
		return
	end

	local previous = self.state
	local current = previous and brain.states[previous]
	if current and current.exit then
		current.exit(self)
	end

	self.state = name
	self.stateSince = os.clock()
	if next_.enter then
		next_.enter(self)
	end

	if Actor.config.logTransitions then
		print(string.format("[Actor] %s: %s -> %s", self.model.Name, tostring(previous), name))
	end
	Actor.stateChanged:Fire(self, previous, name)
end

function Instance_:stateTime(): number
	return os.clock() - (self.stateSince or os.clock())
end

function Instance_:despawn(reason: string?)
	if self._despawned then
		return
	end
	self._despawned = true
	local brain = brains[self.brain]
	local current = self.state and brain and brain.states[self.state]
	if current and current.exit then
		pcall(current.exit, self)
	end
	if self.animator then
		self.animator:destroy()
	end
	actors[self.model] = nil
	Actor.despawned:Fire(self, reason or "despawn")
	if self.model.Parent then
		self.model:Destroy()
	end
end

-- ================================ spawning ==================================
--[[
	config:
	  home      Vector3 the actor belongs to (defaults to spawn position)
	  leash     how far it may be pulled before :leashed() is true
	  tag       free-form group label, for :nearestOf
	  animator  an Anim animator to drive with :play
	  data      anything your game wants to hang off it
]]
function Actor.spawn(model: Model, brainName: string, config: any?): any
	local brain = brains[brainName]
	assert(brain, string.format("[Actor] no brain named '%s'", tostring(brainName)))
	local cfg = config or {}

	local self = setmetatable({
		model = model,
		brain = brainName,
		humanoid = model:FindFirstChildOfClass("Humanoid"),
		home = cfg.home or model:GetPivot().Position,
		leash = cfg.leash,
		tag = cfg.tag,
		animator = cfg.animator,
		data = cfg.data or {},
		blackboard = {},
		target = nil,
		state = nil,
		stateSince = os.clock(),
		_cooldowns = {},
		_despawned = false,
	}, Instance_)

	actors[model] = self
	self:setState(brain.initial)
	Actor.start()
	Actor.spawned:Fire(self)
	return self
end

function Actor.get(model: Model): any?
	return actors[model]
end

function Actor.all(): { any }
	local out = {}
	for _, a in actors do
		table.insert(out, a)
	end
	return out
end

function Actor.count(tag: string?): number
	local n = 0
	for _, a in actors do
		if not tag or a.tag == tag then
			n += 1
		end
	end
	return n
end

function Actor.despawnAll(reason: string?)
	for _, a in table.clone(actors) do
		a:despawn(reason)
	end
end

-- ================================= the loop =================================
function Actor.start()
	if group then
		return
	end
	group = Sched.group(Actor.config.tickRate)
	--[[
		Deliberately unsliced.

		Slicing spreads *members* over frames. Everything below is a single
		member that loops every actor itself, so slicing it never spread any
		work — when the slice came up, that one member still processed all
		fourteen actors in one frame. The only thing four slices bought was
		running the brains on one tick in four: 2Hz instead of the configured
		8Hz, with an identical peak frame cost.

		At 2Hz the enemies visibly walked, arrived, stopped and waited half a
		second for their next order. Same cost, four times the responsiveness.
	]]
	group:setSlices(1)
	group:add("actors", function(dt)
		for model, self in table.clone(actors) do
			if self._despawned then
				continue
			end
			if not self:isAlive() then
				self:despawn("died")
				continue
			end

			local brain = brains[self.brain]
			local state = brain.states[self.state]
			if not state then
				continue
			end

			-- transitions are checked before update, so a state never acts on
			-- a frame where its own exit condition already holds
			if state.transitions then
				for _, transition in state.transitions do
					local ok, should = pcall(transition.when, self)
					if ok and should then
						self:setState(transition.to)
						state = brain.states[self.state]
						break
					elseif not ok then
						warn(string.format("[Actor] transition error in %s.%s: %s", self.brain, tostring(self.state), tostring(should)))
					end
				end
			end

			if state and state.update then
				local ok, err = pcall(state.update, self, dt)
				if not ok then
					warn(string.format("[Actor] update error in %s.%s: %s", self.brain, tostring(self.state), tostring(err)))
				end
			end
		end
	end)

	--[[
		Steering, on its own faster tick.

		Two jobs that both look wrong at brain speed:

		Facing, because snapping to look at a target reads as robotic.

		And re-commanding the walk. `Humanoid:MoveTo` walks to a point and
		*stops there* — so an actor chasing a moving player arrives at where
		the player used to be and stands still until the brain thinks again.
		Re-issuing the same destination every frame is the standard fix: it
		keeps the walk alive and refreshes MoveTo's own eight-second timeout,
		which would otherwise strand anything on a long journey.
	]]
	local turnGroup = Sched.group(30)
	turnGroup:add("steering", function(dt)
		for _, self in actors do
			if self._faceGoal then
				local root = self.model:FindFirstChild("HumanoidRootPart") :: BasePart?
				if root then
					local goal = CFrame.lookAt(root.Position, self._faceGoal)
					root.CFrame = root.CFrame:Lerp(goal, math.clamp(dt * 8, 0, 1))
				end
			end

			-- Only while there is somewhere to be, and only until we are
			-- there: re-commanding on arrival makes the actor jitter in place.
			local destination = self.destination
			if destination and self.humanoid then
				if (self:position() - destination).Magnitude > 1.5 then
					self.humanoid:MoveTo(destination)
				end
			end
		end
	end)
end

-- ============================== population ==================================
--[[
	A budgeted spawner. It does not know what an enemy is: you give it a
	`create` function and rules about how many and where, and it maintains the
	population, despawning anything nobody is near.

		Actor.population({
			id = "meadow",
			max = 24,
			radius = { 60, 300 },        -- spawn this far from the nearest player
			despawnBeyond = 480,
			interval = 2,
			create = function(position) return spawnWolf(position) end,
		})
]]
local populations: { [string]: any } = {}

function Actor.population(rules: any)
	assert(rules.id and rules.create, "[Actor] population needs an id and a create function")
	rules.max = rules.max or 20
	rules.interval = rules.interval or 2
	rules.radius = rules.radius or { 80, 260 }
	rules.despawnBeyond = rules.despawnBeyond or 500
	rules.living = rules.living or {}
	populations[rules.id] = rules

	task.spawn(function()
		while populations[rules.id] do
			task.wait(rules.interval)

			-- reap
			-- With nobody in the world, "distance to the nearest player" is
			-- infinite and every actor looks abandoned. Reaping on that basis
			-- empties the world the moment the last player leaves — and makes
			-- a headless measurement run, which has no players by design,
			-- report a population of zero. Only reap when there is someone to
			-- be far from.
			local anyPlayers = false
			for _, plr in Players:GetPlayers() do
				if plr.Character then
					anyPlayers = true
					break
				end
			end

			for i = #rules.living, 1, -1 do
				local actor = rules.living[i]
				if not actor or actor._despawned or not actor:isAlive() then
					table.remove(rules.living, i)
					continue
				end
				if not anyPlayers then
					continue
				end
				local nearest = math.huge
				for _, plr in Players:GetPlayers() do
					local char = plr.Character
					if char then
						nearest = math.min(nearest, (char:GetPivot().Position - actor:position()).Magnitude)
					end
				end
				if nearest > rules.despawnBeyond then
					actor:despawn("far")
					table.remove(rules.living, i)
				end
			end

			-- sow
			-- One per interval means a 14-actor world takes 35 seconds to fill,
			-- which reads as "the spawner is broken" long before it is full.
			for _ = 1, (rules.perTick or 3) do
				if #rules.living >= rules.max then
					break
				end
				local anchor = rules.anchor
				if not anchor then
					local candidates = {}
					for _, plr in Players:GetPlayers() do
						local char = plr.Character
						if char then
							table.insert(candidates, char:GetPivot().Position)
						end
					end
					if #candidates == 0 then
						continue
					end
					anchor = candidates[math.random(1, #candidates)]
				end

				local angle = math.random() * math.pi * 2
				local dist = rules.radius[1] + math.random() * (rules.radius[2] - rules.radius[1])
				local at = anchor + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)

				local ok, actor = pcall(rules.create, at)
				if ok and actor then
					table.insert(rules.living, actor)
				elseif not ok then
					warn(string.format("[Actor] population '%s' create failed: %s", rules.id, tostring(actor)))
				end
			end
		end
	end)

	return rules
end

function Actor.stopPopulation(id: string)
	populations[id] = nil
end

-- What a validator reads: are there actors, are they in sane states, is any
-- one of them stuck?
function Actor.describe(): { [string]: any }
	local byState: { [string]: number } = {}
	local byBrain: { [string]: number } = {}
	local stuck = 0
	for _, a in actors do
		byState[a.state or "?"] = (byState[a.state or "?"] or 0) + 1
		byBrain[a.brain] = (byBrain[a.brain] or 0) + 1
		if a:stateTime() > 60 then
			stuck += 1
		end
	end
	local pops = {}
	for id, rules in populations do
		pops[id] = { alive = #rules.living, max = rules.max }
	end
	return {
		total = Actor.count(),
		byState = byState,
		byBrain = byBrain,
		stuckOver60s = stuck,
		populations = pops,
	}
end

return Actor
