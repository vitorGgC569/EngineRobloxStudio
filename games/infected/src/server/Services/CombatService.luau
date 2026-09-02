--!strict
-- All combat lives here, fully server-authoritative:
--   Guns  : client claims origin+direction; server verifies the claim against the
--           character, enforces per-weapon cooldown and ammo, then raycasts itself.
--   Knives: Patient Zero's throwing knife is a real projectile simulated on the
--           server in Heartbeat segments (client renders a cosmetic copy).
--   Melee : range + cooldown validated server-side.
-- Damage rules (spec):
--   Guns damage zombies and the *hidden* Patient Zero (the MM2 mind-game), never
--   plain survivors. PZ knife = one-hit conversion. Zombie claws = 2 hits.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local Ballistics = require(Shared.Ballistics)

local CombatService = {}
CombatService.__index = CombatService

export type Deps = {
	remotes: any, -- Remotes.ServerApi
	roleService: any,
	isRoundActive: () -> boolean,
	onZombieKilled: (killer: Player, victim: Player) -> (), -- rewards
	isLastStand: ((player: Player) -> boolean)?, -- damage resist + Minigun access
	getPrimary: ((player: Player) -> string)?, -- selected loadout (nil -> allow all)
	botService: any?, -- optional; routes bot hits/conversions
}

-- Claimed fire origin may be at most this far from the character's actual head
-- (covers latency); beyond it the shot is rejected and flagged.
local ORIGIN_TOLERANCE = 12

type WeaponState = { mag: number, lastShot: number, reloadingUntil: number, shotsInBurst: number }

function CombatService.new(deps: Deps)
	local self = setmetatable({}, CombatService)
	self._deps = deps
	self._weaponState = {} :: { [Player]: { [string]: WeaponState } }
	self._lastThrow = {} :: { [Player]: number }
	self._lastMelee = {} :: { [Player]: number }
	self._flags = {} :: { [Player]: number }
	Players.PlayerRemoving:Connect(function(player)
		self._weaponState[player] = nil
		self._lastThrow[player] = nil
		self._lastMelee[player] = nil
		self._flags[player] = nil
	end)
	return self
end

function CombatService:getFlags(player: Player): number
	return self._flags[player] or 0
end

function CombatService:_flag(player: Player)
	self._flags[player] = (self._flags[player] or 0) + 1
end

function CombatService:resetRound()
	table.clear(self._weaponState)
	table.clear(self._lastThrow)
	table.clear(self._lastMelee)
end

-- Helpers ----------------------------------------------------------------------

local function characterOf(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if character == nil then
		return nil, nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
		return nil, nil, nil
	end
	return character, humanoid, root
end

local function playerFromHit(instance: Instance): Player?
	local model = instance:FindFirstAncestorOfClass("Model")
	if model then
		return Players:GetPlayerFromCharacter(model)
	end
	return nil
end

local function tagKiller(victim: Player, killer: Player)
	local character = victim.Character
	if character == nil then
		return
	end
	local tag = character:FindFirstChild("KilledBy")
	if tag == nil then
		tag = Instance.new("ObjectValue")
		tag.Name = "KilledBy"
		tag.Parent = character
	end
	local tagValue = tag :: ObjectValue
	tagValue.Value = killer
end

local function isProtected(character: Model): boolean
	return character:FindFirstChildOfClass("ForceField") ~= nil
end

-- The claimed fire origin must be near the character AND reachable from it: a
-- clear ray from the head to the claimed origin. Otherwise a 12-stud tolerance
-- lets exploiters project their muzzle through walls (finding #6).
local function originReachable(character: Model, root: BasePart, origin: Vector3): boolean
	if (origin - root.Position).Magnitude > ORIGIN_TOLERANCE then
		return false
	end
	local head = character:FindFirstChild("Head")
	local from = (head and head:IsA("BasePart") and head.Position) or root.Position
	local offset = origin - from
	if offset.Magnitude < 0.5 then
		return true
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	return workspace:Raycast(from, offset) == nil
end

-- Guns ---------------------------------------------------------------------------

function CombatService:_weaponStateFor(player: Player, weaponId: string): WeaponState
	local perPlayer = self._weaponState[player]
	if perPlayer == nil then
		perPlayer = {}
		self._weaponState[player] = perPlayer
	end
	local state = perPlayer[weaponId]
	if state == nil then
		local spec = (GameConfig.Combat.Guns :: any)[weaponId]
		state = { mag = spec.Mag, lastShot = 0, reloadingUntil = 0, shotsInBurst = 0 }
		perPlayer[weaponId] = state
	end
	return state
end

function CombatService:handleFireWeapon(
	player: Player,
	payload: { origin: Vector3, direction: Vector3, weaponId: string }
)
	if not self._deps.isRoundActive() then
		return
	end
	local role = self._deps.roleService:getRole(player)
	-- Only non-zombies shoot. Hidden PZ may also shoot (they must blend in!).
	if role ~= "SURVIVOR" and role ~= "PATIENT_ZERO" then
		self:_flag(player)
		return
	end

	-- Weapon must be in the player's loadout: selected primary, the Pistol sidearm,
	-- or the Minigun during Last Stand.
	if self._deps.getPrimary then
		local allowed = payload.weaponId == self._deps.getPrimary(player)
			or payload.weaponId == "Pistol"
			or (
				payload.weaponId == "Minigun"
				and self._deps.isLastStand ~= nil
				and self._deps.isLastStand(player)
			)
		if not allowed then
			self:_flag(player)
			return
		end
	end

	local spec = (GameConfig.Combat.Guns :: any)[payload.weaponId]
	local character, _, root = characterOf(player)
	if character == nil or root == nil then
		return
	end

	-- Origin must be near the actual character and not through a wall
	if not originReachable(character :: Model, root :: BasePart, payload.origin) then
		self:_flag(player)
		return
	end

	local state = self:_weaponStateFor(player, payload.weaponId)
	local now = os.clock()
	if now < state.reloadingUntil then
		return -- still reloading; not hostile, just ignore
	end
	if now - state.lastShot < (1 / spec.FireRate) * 0.9 then -- 10% slack for jitter
		self:_flag(player)
		return
	end
	if state.mag <= 0 then
		return
	end
	local lastShotAt = state.lastShot
	state.lastShot = now
	state.mag -= 1

	-- Bloom: decay what the previous burst accumulated, then charge this shot. The server
	-- owns the cone, so a client that fakes a perfectly-centred direction still gets spread.
	state.shotsInBurst = Ballistics.decayShots(state.shotsInBurst, payload.weaponId, now - lastShotAt)
	local spreadDeg = Ballistics.spread(payload.weaponId, {
		shotsInBurst = state.shotsInBurst,
		sprinting = player:GetAttribute("Sprinting") == true,
	})
	state.shotsInBurst = math.min(state.shotsInBurst + 1, Ballistics.maxShots(payload.weaponId))

	local pellets = spec.Pellets or 1
	local rng = Random.new()
	local up = if Ballistics.safeUpAxis(payload.direction.Y) == "Z" then Vector3.zAxis else Vector3.yAxis
	local aimFrame = CFrame.lookAt(Vector3.zero, payload.direction, up)
	for _ = 1, pellets do
		local offset = Ballistics.coneOffset(spreadDeg, rng:NextNumber(), rng:NextNumber())
		local direction = (aimFrame * CFrame.Angles(math.rad(offset.pitchDeg), math.rad(offset.yawDeg), 0)).LookVector
		self:_hitscan(player, character :: Model, payload.origin, direction, spec)
	end

	-- Bots hear the shot and investigate. Deliberately position-only: passing the shooter
	-- would let bots react to the hidden Patient Zero and leak the mind-game.
	if self._deps.botService and self._deps.botService.noteGunshot then
		self._deps.botService:noteGunshot(payload.origin)
	end

	-- Broadcast for tracer/sound rendering on other clients
	self._deps.remotes.fireAllClients("ShotFired", {
		shooterUserId = player.UserId,
		origin = payload.origin,
		direction = payload.direction,
		weaponId = payload.weaponId,
	})
end

function CombatService:_hitscan(
	shooter: Player,
	shooterChar: Model,
	origin: Vector3,
	direction: Vector3,
	spec: any
)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { shooterChar }
	local result = workspace:Raycast(origin, direction * spec.Range, params)
	if result == nil then
		return
	end
	local victim = playerFromHit(result.Instance)
	if victim == nil then
		-- Could be a bot: only zombie bots take gun damage (mirrors the player rule).
		-- Rewards are routed inside BotService:damageBot via onBotKilledByHuman.
		local model = result.Instance:FindFirstAncestorOfClass("Model")
		if self._deps.botService and model and self._deps.botService:isZombieBot(model) then
			local killed = self._deps.botService:damageBot(model, spec.Damage, shooter)
			self._deps.remotes.fireClient(
				"HitConfirm",
				shooter,
				{ killed = killed, position = result.Position, damage = spec.Damage }
			)
		end
		return
	end
	local victimRole = self._deps.roleService:getRole(victim)
	local victimChar, victimHumanoid = characterOf(victim)
	if victimChar == nil or victimHumanoid == nil or isProtected(victimChar :: Model) then
		return
	end

	if victimRole == "ZOMBIE" then
		tagKiller(victim, shooter)
		local vh = victimHumanoid :: Humanoid
		vh:TakeDamage(spec.Damage)
		if (victimHumanoid :: Humanoid).Health <= 0 then
			self._deps.onZombieKilled(shooter, victim)
		end
		self._deps.remotes.fireClient("HitConfirm", shooter, {
			killed = (victimHumanoid :: Humanoid).Health <= 0,
			position = result.Position,
			damage = spec.Damage,
		})
	elseif victimRole == "PATIENT_ZERO" then
		-- The mind game: shooting the hidden PZ works
		tagKiller(victim, shooter)
		local vh = victimHumanoid :: Humanoid
		vh:TakeDamage(spec.Damage)
		self._deps.remotes.fireClient("HitConfirm", shooter, {
			killed = (victimHumanoid :: Humanoid).Health <= 0,
			position = result.Position,
			damage = spec.Damage,
		})
	else
		-- Survivor shot survivor: no damage, no feedback (prevents role-scanning by shooting)
		return
	end
end

function CombatService:handleReload(player: Player, payload: { weaponId: string })
	local spec = (GameConfig.Combat.Guns :: any)[payload.weaponId]
	local state = self:_weaponStateFor(player, payload.weaponId)
	local now = os.clock()
	if state.mag >= spec.Mag or now < state.reloadingUntil then
		return
	end
	state.reloadingUntil = now + spec.Reload
	task.delay(spec.Reload, function()
		if player.Parent ~= nil then
			state.mag = spec.Mag
		end
	end)
end

-- Knives -------------------------------------------------------------------------

function CombatService:handleThrowKnife(player: Player, payload: { origin: Vector3, direction: Vector3 })
	if not self._deps.isRoundActive() then
		return
	end
	if self._deps.roleService:getRole(player) ~= "PATIENT_ZERO" then
		self:_flag(player) -- only PZ throws
		return
	end
	local character, _, root = characterOf(player)
	if character == nil or root == nil then
		return
	end
	if not originReachable(character :: Model, root :: BasePart, payload.origin) then
		self:_flag(player)
		return
	end
	local now = os.clock()
	local last = self._lastThrow[player] or 0
	if now - last < GameConfig.Combat.PatientZero.ThrowCooldown * 0.9 then
		self:_flag(player)
		return
	end
	self._lastThrow[player] = now

	self._deps.remotes.fireAllClients("KnifeThrown", {
		throwerUserId = player.UserId,
		origin = payload.origin,
		direction = payload.direction,
	})
	self:_simulateKnife(player, character :: Model, payload.origin, payload.direction)
end

function CombatService:_simulateKnife(
	thrower: Player,
	throwerChar: Model,
	origin: Vector3,
	direction: Vector3
)
	local pzConfig = GameConfig.Combat.PatientZero
	task.spawn(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { throwerChar }

		local position = origin
		local velocity = direction * pzConfig.ThrowSpeed
		local traveled = 0
		while traveled < pzConfig.MaxThrowRange do
			local dt = task.wait() -- Heartbeat step
			local step = velocity * dt
			local result = workspace:Raycast(position, step, params)
			if result ~= nil then
				local victim = playerFromHit(result.Instance)
				if victim == nil then
					-- Knife converts a survivor bot on contact.
					local model = result.Instance:FindFirstAncestorOfClass("Model")
					if self._deps.botService and model then
						self._deps.botService:convertBot(model, thrower)
					end
					return
				end
				if victim ~= nil and victim ~= thrower then
					local victimChar, victimHumanoid = characterOf(victim)
					local role = self._deps.roleService:getRole(victim)
					if
						victimChar ~= nil
						and victimHumanoid ~= nil
						and role == "SURVIVOR"
						and not isProtected(victimChar :: Model)
					then
						tagKiller(victim, thrower)
						local vh = victimHumanoid :: Humanoid
						local damage = vh.MaxHealth
						if self._deps.isLastStand and self._deps.isLastStand(victim) then
							damage *= GameConfig.Combat.LastStand.DamageResistMult
						end
						vh:TakeDamage(damage)
					end
				end
				return -- knife stops on any hit
			end
			position += step
			traveled += step.Magnitude
			velocity -= Vector3.new(0, pzConfig.ThrowGravity * dt, 0)
		end
	end)
end

-- Melee --------------------------------------------------------------------------

function CombatService:handleMelee(player: Player, payload: { targetUserId: number })
	if not self._deps.isRoundActive() then
		return
	end
	local role = self._deps.roleService:getRole(player)
	if role ~= "PATIENT_ZERO" and role ~= "ZOMBIE" then
		self:_flag(player)
		return
	end
	local cooldown = if role == "PATIENT_ZERO"
		then GameConfig.Combat.PatientZero.MeleeCooldown
		else GameConfig.Combat.Zombie.MeleeCooldown

	local now = os.clock()
	local last = self._lastMelee[player] or 0
	if now - last < cooldown * 0.9 then
		self:_flag(player)
		return
	end

	local target = Players:GetPlayerByUserId(payload.targetUserId)
	if target == nil or target == player then
		return
	end
	if self._deps.roleService:getRole(target) ~= "SURVIVOR" then
		return -- infected can't hurt infected
	end
	local _, _, myRoot = characterOf(player)
	local targetChar, targetHumanoid, targetRoot = characterOf(target)
	if myRoot == nil or targetChar == nil or targetHumanoid == nil or targetRoot == nil then
		return
	end
	if isProtected(targetChar :: Model) then
		return
	end
	local range = GameConfig.Combat.Zombie.MeleeRange
	if ((myRoot :: BasePart).Position - (targetRoot :: BasePart).Position).Magnitude > range + 3 then -- +3 latency slack
		self:_flag(player)
		return
	end
	self._lastMelee[player] = now

	tagKiller(target, player)
	local th = targetHumanoid :: Humanoid
	local damage = if role == "PATIENT_ZERO" then th.MaxHealth else GameConfig.Combat.Zombie.MeleeDamage
	if self._deps.isLastStand and self._deps.isLastStand(target) then
		damage *= GameConfig.Combat.LastStand.DamageResistMult
	end
	th:TakeDamage(damage)
end

-- Swing melee: a target-less claw/stab that converts the nearest survivor (player or
-- bot) in range. This is what lets a human infected fight bots without a client-known
-- target userId.
function CombatService:handleMeleeSwing(player: Player, _payload: { origin: Vector3, direction: Vector3 })
	if not self._deps.isRoundActive() then
		return
	end
	local role = self._deps.roleService:getRole(player)
	if role ~= "PATIENT_ZERO" and role ~= "ZOMBIE" then
		self:_flag(player)
		return
	end
	local now = os.clock()
	local last = self._lastMelee[player] or 0
	local cooldown = if role == "PATIENT_ZERO"
		then GameConfig.Combat.PatientZero.MeleeCooldown
		else GameConfig.Combat.Zombie.MeleeCooldown
	if now - last < cooldown * 0.9 then
		return
	end
	local _, _, myRoot = characterOf(player)
	if myRoot == nil then
		return
	end
	local myPos = (myRoot :: BasePart).Position
	local range = GameConfig.Combat.Zombie.MeleeRange + 2

	-- Nearest human survivor
	local bestPlayer: Player? = nil
	local bestDist = range
	for _, other in Players:GetPlayers() do
		if other ~= player and self._deps.roleService:getRole(other) == "SURVIVOR" then
			local _, oh, oRoot = characterOf(other)
			if oh and oRoot then
				local d = ((oRoot :: BasePart).Position - myPos).Magnitude
				if d < bestDist then
					bestPlayer, bestDist = other, d
				end
			end
		end
	end
	if bestPlayer then
		self._lastMelee[player] = now
		tagKiller(bestPlayer, player)
		local _, th = characterOf(bestPlayer)
		if th then
			(th :: Humanoid):TakeDamage((th :: Humanoid).MaxHealth)
		end
		return
	end

	-- Otherwise nearest survivor bot
	if self._deps.botService then
		local bestBot: Model? = nil
		bestDist = range
		for _, model in workspace:GetChildren() do
			if model:IsA("Model") and self._deps.botService:isSurvivorBot(model) then
				local r = model:FindFirstChild("HumanoidRootPart")
				if r and r:IsA("BasePart") then
					local d = (r.Position - myPos).Magnitude
					if d < bestDist then
						bestBot, bestDist = model, d
					end
				end
			end
		end
		if bestBot then
			self._lastMelee[player] = now
			self._deps.botService:convertBot(bestBot, player)
		end
	end
end

-- Sprint -------------------------------------------------------------------------

function CombatService:handleSprint(player: Player, payload: { sprinting: string })
	-- Zombies don't sprint: their class sets their speed, and letting them toggle
	-- sprint would overwrite Runner/Tank multipliers (finding #7).
	local role = self._deps.roleService:getRole(player)
	if role ~= "SURVIVOR" and role ~= "PATIENT_ZERO" then
		return
	end
	local _, humanoid = characterOf(player)
	if humanoid == nil then
		return
	end
	local sprinting = payload.sprinting == "on"
	local speed = if sprinting then GameConfig.Movement.SprintWalkSpeed else GameConfig.Movement.BaseWalkSpeed
	if role == "PATIENT_ZERO" and sprinting then
		speed *= GameConfig.Combat.PatientZero.SprintMult
	end
	local h = humanoid :: Humanoid
	h.WalkSpeed = speed
	-- Read back by the server's own spread roll: firing from a sprint is inaccurate.
	player:SetAttribute("Sprinting", sprinting)
end

-- Wiring -------------------------------------------------------------------------

function CombatService:start()
	local remotes = self._deps.remotes
	remotes.onValidated("FireWeapon", function(player, payload)
		self:handleFireWeapon(player, payload)
	end)
	remotes.onValidated("ThrowKnife", function(player, payload)
		self:handleThrowKnife(player, payload)
	end)
	remotes.onValidated("MeleeAttack", function(player, payload)
		self:handleMelee(player, payload)
	end)
	remotes.onValidated("MeleeSwing", function(player, payload)
		self:handleMeleeSwing(player, payload)
	end)
	remotes.onValidated("Reload", function(player, payload)
		self:handleReload(player, payload)
	end)
	remotes.onValidated("SprintState", function(player, payload)
		self:handleSprint(player, payload)
	end)
end

return CombatService
