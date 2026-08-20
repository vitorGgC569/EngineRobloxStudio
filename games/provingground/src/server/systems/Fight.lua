--!strict
--[[
	Fight — what combat means in this game.

	Forge supplies the arc query, the damage pipeline, the state machine and the
	animator. Every rule below is a decision: that armour is subtractive-ish,
	that a third combo hit does more, that blocking costs stamina, that a brute
	telegraphs for half a second before it swings. None of that came from the
	engine, and none of it should have.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Data = Forge.Data
local Net = Forge.Net
local Rig = Forge.Rig
local Anim = Forge.Anim
local Actor = Forge.Actor
local Combat = Forge.Combat
local Save = Forge.Save
local Debug = Forge.Debug
local Rng = Forge.Core.Rng
local Netcode = Forge.Netcode

local Arena = require(script.Parent.Arena)

local Fight = {}

-- Live tunables: changeable in a running session through the bridge, which is
-- the shortest balance loop the platform allows.
local comboWindow = Debug.tunable("fight.comboWindow", 1.1)
local finisherMult = Debug.tunable("fight.finisherMult", 1.65)
local dodgeIFrames = Debug.tunable("fight.dodgeIFrames", 0.42)
local dodgeCost = Debug.tunable("fight.dodgeStamina", 24)
local blockReduction = Debug.tunable("fight.blockReduction", 0.7)
local maxEnemies = Debug.tunable("fight.maxEnemies", 14)

-- Running. The interesting number is not the speed, it is the drain: at 18/s
-- against a 22/s regen a player can sprint in bursts forever but never cross
-- the arena at speed, which is the pressure the whole stamina bar exists for.
local walkSpeed = Debug.tunable("move.walkSpeed", 16)
local sprintSpeed = Debug.tunable("move.sprintSpeed", 26)
local sprintDrain = Debug.tunable("move.sprintDrain", 18)
local staminaRegen = Debug.tunable("move.staminaRegen", 22)
-- Hysteresis: recovering to exactly 1 stamina and being allowed to sprint
-- again produces a stutter of one frame of running per second.
local recoverAt = Debug.tunable("move.recoverAt", 32)
local exhaustedSpeed = Debug.tunable("move.exhaustedSpeed", 11)

local playerState: { [Player]: any } = {}

local function stateFor(player: Player)
	local state = playerState[player]
	if not state then
		state = { combo = 0, lastAttack = 0, blocking = false, stamina = 100, sprinting = false, exhausted = false, sentStamina = -1 }
		playerState[player] = state
	end
	return state
end

-- ============================== damage rules ================================
local function installModifiers()
	-- 100 armour halves incoming damage. Diminishing, so stacking armour never
	-- reaches immunity.
	Combat.addModifier("armor", 100, function(ctx)
		local armor = ctx.target:GetAttribute("Armor") or 0
		if armor > 0 then
			ctx.amount *= 100 / (100 + armor)
		end
	end)

	-- Blocking is checked before crit so a blocked crit is still a blocked hit.
	Combat.addModifier("block", 150, function(ctx)
		local player = Players:GetPlayerFromCharacter(ctx.target)
		if not player then
			return
		end
		local state = stateFor(player)
		if not state.blocking then
			return
		end
		-- only from the front: turning your back mid-block should cost you
		local root = ctx.target:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and ctx.from then
			local toAttacker = (ctx.from - root.Position)
			local flat = Vector3.new(toAttacker.X, 0, toAttacker.Z)
			if flat.Magnitude > 0.1 and root.CFrame.LookVector:Dot(flat.Unit) < 0.2 then
				return
			end
		end
		ctx.amount *= 1 - blockReduction()
		ctx.blocked = true
		state.stamina = math.max(0, state.stamina - 18)
	end)

	Combat.addModifier("crit", 200, function(ctx)
		local chance = ctx.critChance or 0
		if chance > 0 and Rng.stream("combat"):bool(chance) then
			ctx.amount *= 1.9
			ctx.crit = true
		end
	end)

	Combat.addModifier("round", 900, function(ctx)
		ctx.amount = math.max(1, math.floor(ctx.amount + 0.5))
	end)
end

-- Everything that hits anything routes through here, so the feedback for a
-- hit is defined once instead of at every call site.
local function announceHit(ctx: any)
	local position = ctx.target:GetPivot().Position + Vector3.new(0, 3, 0)
	Net.fireNear(position, 160, "Hit", {
		pos = position,
		amount = ctx.dealt,
		crit = ctx.crit or false,
		blocked = ctx.blocked or false,
		dir = ctx.direction,
		kind = ctx.kind or "melee",
	})
	Debug.count("hits")
	Debug.count("damage", math.floor(ctx.dealt))
end

-- ============================== the player ==================================
--[[
	The swing, judged against the world the player was looking at.

	This used to be a plain `Net.on("Attack")`: the client asked, the server
	swung at *current* positions, and a player with 150ms of latency had to lead
	every target by a body width. Routed through Netcode with `rewind = true`,
	the arc query runs against where things were when they clicked.
]]
local function onAttack(player: Player, payload: any)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (character and root and Combat.isAlive(character)) then
		return
	end

	local state = stateFor(player)
	local weapon = Data.expect("weapon", "training_blade")
	local now = os.clock()
	if now - state.lastAttack < weapon.cooldown then
		return -- server owns the cooldown; the client only asks
	end

	if now - state.lastAttack > comboWindow() then
		state.combo = 0
	end
	state.combo = (state.combo % 3) + 1
	state.lastAttack = now
	state.blocking = false

	local direction = payload.dir
	local finisher = state.combo == 3

	--[[
		Damage lands on the clip's `hit` marker, not on the keypress: that delay is
		what makes the swing feel connected to the wound.

		But a `task.delay` here would run *after* Netcode restored every rewound
		position, so the hit would be judged against the present after all — the
		rewind would be decorative. The query runs now, against the rewound world;
		only the damage and the effect wait for the marker.
	]]
	local function resolve(hits)
		for _, target in hits do
			local ctx = Combat.damage(target, {
				amount = weapon.damage * (finisher and finisherMult() or 1),
				source = player,
				critChance = weapon.crit,
				direction = direction,
				from = root.Position,
				kind = "melee",
			})
			if ctx then
				announceHit(ctx)
				Forge.Feel.knockback(target, direction, weapon.knockback * (finisher and 1.8 or 1))
			end
		end

		if #hits == 0 then
			Debug.count("misses")
		end
	end

	local hits = Combat.arc(root.Position, direction, {
		range = weapon.range,
		angle = finisher and 360 or weapon.arc,
		ignore = { character },
		limit = 6,
		filter = function(model)
			return model ~= character and Players:GetPlayerFromCharacter(model) == nil
		end,
	})

	task.delay(finisher and 0.34 or 0.26, function()
		if character.Parent and Combat.isAlive(character) then
			resolve(hits)
		end
	end)
end

local function onDodge(player: Player, payload: any)
	local character = player.Character
	if not (character and Combat.isAlive(character)) then
		return
	end
	local state = stateFor(player)
	if state.stamina < dodgeCost() then
		return
	end
	state.stamina -= dodgeCost()
	state.blocking = false
	Combat.grantIFrames(character, dodgeIFrames())
	Debug.count("dodges")
end

local function onBlock(player: Player, payload: any)
	local state = stateFor(player)
	state.blocking = payload.on == true
end

--[[
	Sprint is a *request*, not a speed change.

	The client says "I am holding the key"; the server decides whether that
	means anything and owns the WalkSpeed. A client that sets its own speed is
	a client that can set it to 200.
]]
local function onSprint(player: Player, payload: any)
	local state = stateFor(player)
	state.sprinting = payload.on == true
end

-- The one place a player's speed is decided.
local function applySpeed(player: Player, state: any)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local speed
	if state.exhausted then
		speed = exhaustedSpeed()
	elseif state.blocking then
		speed = walkSpeed() * 0.45
	elseif state.sprinting and state.stamina > 0 then
		speed = sprintSpeed()
	else
		speed = walkSpeed()
	end

	if math.abs(humanoid.WalkSpeed - speed) > 0.05 then
		humanoid.WalkSpeed = speed
	end
end

-- ============================== the enemies =================================
local function buildEnemy(id: string, position: Vector3)
	local def = Data.expect("enemy", id)
	--[[
		The rig table goes through whole.

		It used to be copied field by field, which meant every field added to
		Content had to be added here too or it silently did nothing — `weapon`
		and `spikes` were set on the enemies and never reached the builder, so
		husks swung daggers they were not holding. A named list of fields is a
		list you will forget to update.
	]]
	local spec = table.clone(def.rig)
	spec.name = def.name
	local model = Rig.build(spec)

	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.MaxHealth = def.health
	humanoid.Health = def.health
	humanoid.WalkSpeed = def.speed
	model:SetAttribute("Armor", def.armor)
	model:SetAttribute("EnemyId", id)

	model:PivotTo(CFrame.new(position))
	model.Parent = Workspace:FindFirstChild("Actors")

	local animator = Anim.new(model)
	animator:setProfile(Anim.profiles[def.profile])
	Anim.bind(animator, "heartbeat")

	-- The swing lands when the animation says it does. Move the pose, the hit
	-- window moves with it — no timing constant anywhere in this file.
	animator:onMarker(function(_clip, marker)
		if marker ~= "hit" then
			return
		end
		local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not (root and Combat.isAlive(model)) then
			return
		end
		local hits = Combat.arc(root.Position, root.CFrame.LookVector, {
			range = def.reach + 2,
			angle = 120,
			ignore = { model },
			filter = function(target)
				return Players:GetPlayerFromCharacter(target) ~= nil
			end,
		})
		for _, target in hits do
			local ctx = Combat.damage(target, {
				amount = def.damage,
				source = model,
				direction = root.CFrame.LookVector,
				from = root.Position,
				kind = "enemy",
			})
			if ctx then
				announceHit(ctx)
			end
		end
	end)

	-- Without this the rewind has no history and silently does nothing.
	Netcode.track(model)

	local actor = Actor.spawn(model, "husk", {
		home = position,
		leash = 220,
		tag = "enemy",
		animator = animator,
		data = { def = def, id = id },
	})
	return actor
end

local function defineBrain()
	Actor.defineBrain("husk", {
		initial = "idle",
		states = {
			idle = {
				enter = function(self)
					self:setSpeed(self.data.def.speed * 0.5)
				end,
				update = function(self)
					self:wander(24)
				end,
				transitions = {
					{
						to = "chase",
						when = function(self)
							self.target = self:nearestPlayer(self.data.def.aggro, true)
							return self.target ~= nil
						end,
					},
				},
			},

			chase = {
				enter = function(self)
					self:setSpeed(self.data.def.speed)
				end,
				update = function(self)
					if self.target then
						self:pursue(self.target)
						self:face(self.target)
					end
				end,
				transitions = {
					{
						to = "strike",
						when = function(self)
							return self.target ~= nil
								and self:flatDistanceTo(self.target) <= self.data.def.reach
								and self:ready("swing", self.data.def.attackEvery)
						end,
					},
					{
						to = "idle",
						when = function(self)
							return self.target == nil
								or not self.target.Parent
								or self:flatDistanceTo(self.target) > self.data.def.aggro * 1.6
								or self:leashed()
						end,
					},
				},
			},

			strike = {
				enter = function(self)
					self:stop()
					if self.target then
						self:face(self.target, true)
					end
					-- a brute winds up; a stalker snaps
					self:play(self.data.def.profile == "heavy" and "slam" or "attack_1")
				end,
				transitions = {
					{
						to = "chase",
						when = function(self)
							return self:stateTime() > (self.data.def.profile == "heavy" and 1.2 or 0.6)
						end,
					},
				},
			},
		},
	})
end

-- ================================= scoring ==================================
local function onKilled(target: Model, source: any)
	local id = target:GetAttribute("EnemyId")
	if not id then
		return
	end
	Debug.count("kills")

	local actor = Actor.get(target)
	if actor then
		actor:play("die")
	end

	if typeof(source) == "Instance" and source:IsA("Player") then
		local profile = Save.get(source)
		if profile then
			local def = Data.get("enemy", id)
			profile.score += (def and def.score or 10)
			profile.kills += 1
			Net.fire(source, "StateSync", profile)
			Net.fire(source, "Notify", { text = string.format("%s down  (+%d)", target.Name, def and def.score or 10) })
		end
	end

	-- let the death animation play before the body goes
	task.delay(2.5, function()
		if target.Parent then
			target:Destroy()
		end
	end)
end

-- ================================== start ===================================
function Fight.start()
	installModifiers()
	defineBrain()

	Anim.registerAll(require(ReplicatedStorage.Forge.Anim.Presets))

	-- `authorize` is the server's cooldown; `apply` runs inside a rewind so the
	-- hit is judged fairly. A refusal travels back as a rejection the client
	-- rolls its prediction back from.
	-- Proving Ground is the network laboratory, so it opts into the test
	-- channel that lets a sweep inject latency from outside.
	Netcode.config.allowSimulationRequests = true

	Netcode.define("attack", {
		rewind = true,
		authorize = function(player, data)
			local character = player.Character
			if not (character and Combat.isAlive(character)) then
				return false, "dead"
			end
			local state = stateFor(player)
			local weapon = Data.expect("weapon", "training_blade")
			if os.clock() - state.lastAttack < weapon.cooldown then
				return false, "cooldown"
			end
			return true
		end,
		apply = function(player, data)
			onAttack(player, data)
		end,
	})

	Net.on("Dodge", onDodge)
	Net.on("SetBlock", onBlock)
	Net.on("SetSprint", onSprint)

	Combat.killed:Connect(onKilled)

	Players.PlayerRemoving:Connect(function(player)
		playerState[player] = nil
	end)

	--[[
		Stamina, speed and exhaustion, on one loop.

		Exhaustion is a state with an exit condition, not a momentary event:
		hitting zero puts the player in it and they stay there until stamina
		climbs back past `recoverAt`. That is what makes running out *cost*
		something instead of being a one-frame interruption.
	]]
	task.spawn(function()
		while true do
			local dt = task.wait(0.2)
			for player, state in playerState do
				local wasExhausted = state.exhausted
				local moving = false

				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root then
					local velocity = (root :: BasePart).AssemblyLinearVelocity
					moving = Vector3.new(velocity.X, 0, velocity.Z).Magnitude > 3
				end

				if state.sprinting and moving and not state.exhausted then
					state.stamina = math.max(0, state.stamina - sprintDrain() * dt)
					if state.stamina <= 0 then
						state.exhausted = true
					end
				elseif not state.blocking then
					state.stamina = math.min(100, state.stamina + staminaRegen() * dt)
				end

				if state.exhausted and state.stamina >= recoverAt() then
					state.exhausted = false
				end

				applySpeed(player, state)

				-- Tell everyone nearby, not just the runner: someone else being
				-- out of breath is information you want in a fight.
				if state.exhausted ~= wasExhausted and character then
					Net.fireNear(character:GetPivot().Position, 140, "Breath", {
						character = character,
						on = state.exhausted,
					})
					if state.exhausted then
						Debug.count("player.exhausted")
					end
				end

				-- The bar has to move continuously or it is decoration. Sent on
				-- change rather than every tick: a value that has not moved is
				-- a packet nobody needed.
				local shown = math.floor(state.stamina)
				if shown ~= state.sentStamina or state.exhausted ~= wasExhausted then
					state.sentStamina = shown
					Net.fire(player, "Stamina", { value = shown, exhausted = state.exhausted })
				end

				local profile = Save.get(player)
				if profile then
					profile.stamina = shown
					profile.exhausted = state.exhausted
				end
			end
		end
	end)

	-- Population: the engine maintains the count, this decides what spawns.
	local weights = {
		{ id = "husk", weight = 60 },
		{ id = "stalker", weight = 28 },
		{ id = "husk_brute", weight = 12 },
	}

	Actor.population({
		id = "arena",
		max = maxEnemies(),
		interval = 2.5,
		perTick = 4,
		anchor = Vector3.new(0, 0, 0),
		radius = { 55, 150 },
		despawnBeyond = 400,
		create = function()
			local point = Arena.pointInRing(55, 150)
			if not point then
				return nil
			end
			local pick = Rng.stream("arena.mix"):weighted(weights)
			return buildEnemy(pick.id, point)
		end,
	})

	Debug.probe("fight", function()
		local blocking = 0
		for _, state in playerState do
			if state.blocking then
				blocking += 1
			end
		end
		return {
			enemiesAlive = Actor.count("enemy"),
			blockingPlayers = blocking,
			hits = Debug.counter("hits"),
			misses = Debug.counter("misses"),
			kills = Debug.counter("kills"),
			damage = Debug.counter("damage"),
		}
	end)

	Debug.info("fight system ready")
end

return Fight
