--!strict
-- Server-controlled bots so a solo player can experience a full round. Bots are real
-- animated R15 avatars (Shared.Rig) with a Humanoid, so the existing combat raycasts hit
-- them. They fill the lobby to a target headcount, get assigned roles alongside the human,
-- and are cleaned up at round end.
--
-- AI: each bot navigates with PathfindingService (paths around walls, recovers when
-- wedged) and runs a real state machine (Shared.BotBrain) over a perception snapshot
-- (Shared.BotVision): a vision cone rather than 360-degree awareness, memory of where a
-- target was last seen, hearing for nearby gunfire, and a stagger reaction when shot.
-- Survivor bots fire real raycasts through the same spread model players use, so their
-- misses are visible. Infected chase, and the Patient Zero stalks the most isolated
-- survivor. The hidden PZ is never surfaced to bot senses, so their reactions can't leak
-- the mind-game.
--
-- Bot characters are tagged with attributes the combat + AI code reads:
--   IsBot   = true
--   BotRole = "SURVIVOR" | "PATIENT_ZERO" | "ZOMBIE"

local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local Ballistics = require(Shared.Ballistics)
local BotBrain = require(Shared.BotBrain)
local BotVision = require(Shared.BotVision)
local Emotes = require(Shared.Emotes)

local Rig = require(script.Parent.Parent.Bots.Rig)

local BotService = {}
BotService.__index = BotService

export type Deps = {
	remotes: any,
	getSurvivorSpawn: () -> CFrame?,
	getZombieSpawn: (survivorRoots: { BasePart }) -> CFrame?,
	-- The human survivors currently alive (for bots to hunt / flee).
	getHumanSurvivors: () -> { Player },
	-- Roots of VISIBLY infected players (ZOMBIE role; excludes the hidden PZ) so survivor
	-- bots flee / shoot human zombies too, not just zombie bots.
	getInfectedPlayerRoots: () -> { BasePart },
	-- An infected bot reached a human survivor -> convert them through RoleService.
	convertHuman: (victim: Player) -> (),
	-- A human killed / converted a bot -> route rewards.
	onBotKilledByHuman: (killer: Player) -> (),
	onBotConvertedByHuman: (killer: Player) -> (),
	-- Any survivor bot became a zombie -> extend the round timer like a real conversion.
	onConversionOccurred: () -> (),
	-- Counts changed -> re-aggregate survivor total for the round machine.
	onCountsChanged: () -> (),
	-- A bot shot a human zombie. Without this bot bullets could only ever hurt other bots,
	-- which made bots cosmetic in any fight involving a real player.
	damageInfectedPlayer: ((character: Model, amount: number) -> ())?,
	-- A patrol point from the active map, so bots explore instead of ping-ponging between
	-- spawn markers.
	getPatrolPoint: (() -> Vector3?)?,
}

type Difficulty = { name: string, weight: number, speedMult: number, reactionMult: number }

type Bot = {
	id: number,
	name: string,
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	role: string,
	wanderTarget: Vector3?,
	lastAction: number,
	-- behaviour flavour
	personality: string,
	difficulty: Difficulty,
	baseSpeed: number,
	-- pathfinding nav state
	path: Path?,
	waypoints: { PathWaypoint },
	waypointIndex: number,
	navGoal: Vector3?,
	lastRepath: number,
	computing: boolean,
	lastPos: Vector3,
	lastMoveCheck: number,
	stuckSince: number?,
	-- survivor gunfire
	nextShotAt: number,
	aimingSince: number?,
	-- brain + perception
	brain: any,
	brainConfig: any,
	lastKnown: Vector3?,
	lastContact: number,
	justDamaged: boolean,
	thinkPhase: number,
	nextThink: number,
	searchTarget: Vector3?,
	windupUntil: number?,
	cleanupAnim: (() -> ())?,
	emoteUntil: number?,
	nextEmoteAt: number,
}

-- Roblox-looking display names. The old list was 20 entries all suffixed " [bot]", which
-- announced itself instantly; these read like the usernames around them.
local NAME_STEMS = {
	"Ava",
	"Cole",
	"Dax",
	"Enzo",
	"Faye",
	"Gio",
	"Hana",
	"Ivo",
	"Juno",
	"Kai",
	"Lux",
	"Mira",
	"Nix",
	"Oz",
	"Pax",
	"Quill",
	"Remi",
	"Sol",
	"Tess",
	"Vera",
	"Zane",
	"Bex",
	"Nova",
	"Rook",
	"Vale",
	"Wren",
	"Jax",
	"Kira",
	"Onyx",
	"Sable",
}

local NAME_STYLES = {
	function(stem, _n)
		return stem
	end,
	function(stem, n)
		return stem .. tostring(n)
	end,
	function(stem, _n)
		return "x" .. stem
	end,
	function(stem, n)
		return stem .. "_" .. tostring(n)
	end,
	function(stem, _n)
		return "the" .. stem
	end,
}

local rng = Random.new()

-- Weighted pick of a difficulty tier from config.
local function rollDifficulty(): Difficulty
	local tiers = GameConfig.Bots.Difficulties
	local total = 0
	for _, t in tiers do
		total += t.weight
	end
	local pick = rng:NextNumber(0, total)
	for _, t in tiers do
		pick -= t.weight
		if pick <= 0 then
			return t
		end
	end
	return tiers[1]
end

function BotService.new(deps: Deps)
	local self = setmetatable({}, BotService)
	self._deps = deps
	self._bots = {} :: { [number]: Bot }
	self._nextId = 1
	self._active = false
	return self
end

-- How many bots to field given the human count (fill up to a target headcount).
function BotService:plannedCount(humanCount: number): number
	-- Honour the config switch. Nothing outside a smoke-test assertion used to read this, so
	-- turning it off left bots running anyway — a config flag that lies is worse than no flag.
	if not GameConfig.Bots.Enabled then
		return 0
	end
	if humanCount <= 0 then
		return 0
	end
	local target = GameConfig.Bots.TargetPlayers
	return math.clamp(target - humanCount, 0, GameConfig.Bots.MaxBots)
end

function BotService:survivorCount(): number
	local n = 0
	for _, bot in self._bots do
		if bot.role == "SURVIVOR" then
			n += 1
		end
	end
	return n
end

function BotService:patientZeroName(): string?
	for _, bot in self._bots do
		if bot.role == "PATIENT_ZERO" then
			return bot.name
		end
	end
	return nil
end

function BotService:survivorNames(): { string }
	local out = {}
	for _, bot in self._bots do
		if bot.role == "SURVIVOR" then
			table.insert(out, bot.name)
		end
	end
	return out
end

-- Rig ---------------------------------------------------------------------------

function BotService:_buildRig(name: string, spawnCFrame: CFrame): (Model, Humanoid, BasePart, (() -> ())?)
	-- Real animated avatar, with the old block rig as an automatic fallback.
	local model, humanoid, root = Rig.build(name, rng)

	humanoid.MaxHealth = GameConfig.Combat.SurvivorMaxHealth
	humanoid.Health = GameConfig.Combat.SurvivorMaxHealth
	humanoid.WalkSpeed = GameConfig.Movement.BaseWalkSpeed
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		local nameTag = Instance.new("BillboardGui")
		nameTag.Name = "BotNametag"
		nameTag.Size = UDim2.new(0, 100, 0, 24)
		nameTag.StudsOffset = Vector3.new(0, 2.4, 0)
		nameTag.AlwaysOnTop = false
		nameTag.MaxDistance = 80
		nameTag.Parent = head
		local label = Instance.new("TextLabel")
		label.Name = "BotName"
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamMedium
		label.TextSize = 13
		label.TextColor3 = Color3.fromRGB(230, 230, 235)
		label.TextStrokeTransparency = 0.5
		label.Text = name
		label.Parent = nameTag
	end

	model.PrimaryPart = root
	model.Parent = workspace
	root.CFrame = spawnCFrame + Vector3.new(0, 3, 0)

	-- Animations must be started after the rig is parented so the Animator replicates.
	local cleanupAnim: (() -> ())? = nil
	local ok, cleanup = pcall(Rig.animate, humanoid, rng)
	if ok then
		cleanupAnim = cleanup
	end

	return model, humanoid, root, cleanupAnim
end

-- Role appearance ----------------------------------------------------------------

function BotService:_applyRole(bot: Bot, role: string)
	bot.role = role
	bot.model:SetAttribute("BotRole", role)
	if role == "ZOMBIE" or role == "PATIENT_ZERO" then
		bot.humanoid.WalkSpeed = GameConfig.Movement.BaseWalkSpeed
			* (if role == "PATIENT_ZERO" then GameConfig.Combat.PatientZero.SprintMult else 1)
		if role == "ZOMBIE" then
			bot.humanoid.MaxHealth = GameConfig.Combat.ZombieBaseHealth
			bot.humanoid.Health = GameConfig.Combat.ZombieBaseHealth
			for _, part in bot.model:GetDescendants() do
				if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
					part.Color = Color3.fromRGB(126, 226, 96)
					part.Material = Enum.Material.Neon
				end
			end
			BotService._markInfected(bot.model)
		end
	end
end

-- Same readability treatment player zombies get, so a bot zombie and a player zombie look
-- identical to a survivor scanning a room.
--
-- PATIENT ZERO GUARD: only reached for role == "ZOMBIE". A bot Patient Zero must keep the
-- plain survivor look exactly like a human PZ does.
function BotService._markInfected(model: Model)
	if model:FindFirstChild("InfectionOutline") then
		return
	end
	local highlight = Instance.new("Highlight")
	highlight.Name = "InfectionOutline"
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = Color3.fromRGB(80, 220, 60)
	highlight.FillTransparency = 0.75
	highlight.OutlineColor = Color3.fromRGB(180, 255, 140)
	highlight.Parent = model

	-- The tag was built once at spawn and never updated, so converted bots kept a white
	-- survivor name for the rest of the round.
	local head = model:FindFirstChild("Head")
	local tag = head and head:FindFirstChild("BotNametag")
	local label = tag and tag:FindFirstChild("BotName")
	if tag and tag:IsA("BillboardGui") then
		tag.MaxDistance = 130
	end
	if label and label:IsA("TextLabel") then
		label.TextColor3 = Color3.fromRGB(126, 226, 96)
	end
end

-- Lifecycle ----------------------------------------------------------------------

function BotService:spawnForRound(count: number, opts: { botIsPZ: boolean })
	self:clear()
	self._active = true
	local pzIndex = if opts.botIsPZ then rng:NextInteger(1, math.max(1, count)) else -1
	for i = 1, count do
		local spawnCFrame = self._deps.getSurvivorSpawn() or CFrame.new(0, 5, 0)
		local id = self._nextId
		self._nextId += 1
		local stem = NAME_STEMS[((id - 1) % #NAME_STEMS) + 1]
		local style = NAME_STYLES[rng:NextInteger(1, #NAME_STYLES)]
		local name = style(stem, rng:NextInteger(2, 99))
		local model, humanoid, root, cleanupAnim = self:_buildRig(name, spawnCFrame)
		model:SetAttribute("IsBot", true)
		model:SetAttribute("BotId", id)
		local personalities = GameConfig.Bots.Personalities
		local bot: Bot = {
			id = id,
			name = name,
			model = model,
			humanoid = humanoid,
			root = root,
			role = "SURVIVOR",
			wanderTarget = nil,
			lastAction = 0,
			personality = personalities[rng:NextInteger(1, #personalities)],
			difficulty = rollDifficulty(),
			baseSpeed = GameConfig.Movement.BaseWalkSpeed,
			path = nil,
			waypoints = {},
			waypointIndex = 1,
			navGoal = nil,
			lastRepath = 0,
			computing = false,
			lastPos = root.Position,
			lastMoveCheck = 0,
			stuckSince = nil,
			nextShotAt = 0,
			aimingSince = nil,
			brain = BotBrain.newMemory("PATROL", os.clock()),
			brainConfig = nil,
			lastKnown = nil,
			lastContact = 0,
			justDamaged = false,
			-- Stagger think ticks across the interval: every bot used to decide on the same
			-- frame, which both spiked the frame time and made them move in lockstep.
			thinkPhase = ((id % 5) / 5) * GameConfig.Bots.ThinkInterval,
			nextThink = os.clock() + ((id % 5) / 5) * GameConfig.Bots.ThinkInterval,
			searchTarget = nil,
			windupUntil = nil,
			cleanupAnim = cleanupAnim,
			emoteUntil = nil,
			-- Stagger the first opportunity so a fresh lobby doesn't all wave at once.
			nextEmoteAt = os.clock() + rng:NextNumber(3, GameConfig.Bots.EmoteCooldown),
		}
		bot.brainConfig = BotBrain.configFor(bot.personality, {
			engageRange = GameConfig.Bots.ShootRange * bot.difficulty.sightMult,
		})
		self._bots[id] = bot
		self:_applyRole(bot, if i == pzIndex then "PATIENT_ZERO" else "SURVIVOR")
		humanoid.Died:Connect(function()
			self:_onBotDied(bot)
		end)
	end
	self._deps.onCountsChanged()
end

function BotService:clear()
	self._active = false
	for id, bot in self._bots do
		if bot.cleanupAnim then
			bot.cleanupAnim()
		end
		bot.model:Destroy()
		self._bots[id] = nil
	end
end

function BotService:_botFromCharacter(character: Instance): Bot?
	if not character:IsA("Model") then
		return nil
	end
	local id = character:GetAttribute("BotId")
	if type(id) == "number" then
		return self._bots[id]
	end
	return nil
end

-- Combat hooks (called by CombatService when a bot is hit) -----------------------

-- Human gun shot a bot. Returns true if the bot died.
function BotService:damageBot(character: Model, amount: number, attacker: Player?): boolean
	local bot = self:_botFromCharacter(character)
	if bot == nil or bot.role ~= "ZOMBIE" then
		return false
	end
	self:_reactToDamage(
		bot,
		if attacker and attacker.Character
			then (attacker.Character:FindFirstChild("HumanoidRootPart") :: BasePart?) and (
				attacker.Character.HumanoidRootPart :: BasePart
			).Position
			else nil
	)
	bot.humanoid:TakeDamage(amount)
	if bot.humanoid.Health <= 0 then
		if attacker then
			self._deps.onBotKilledByHuman(attacker)
		end
		return true
	end
	return false
end

-- Human PZ knife/melee converted a survivor bot.
function BotService:convertBot(character: Model, attacker: Player?): boolean
	local bot = self:_botFromCharacter(character)
	if bot == nil or bot.role ~= "SURVIVOR" then
		return false
	end
	self:_applyRole(bot, "ZOMBIE")
	if attacker then
		self._deps.onBotConvertedByHuman(attacker)
	end
	self._deps.onConversionOccurred()
	local root = character:FindFirstChild("HumanoidRootPart")
	self._deps.remotes.fireAllClients("ConversionAlert", {
		victimName = bot.name,
		killerName = attacker and attacker.DisplayName or nil,
		position = (root and root:IsA("BasePart")) and root.Position or nil,
	})
	self._deps.onCountsChanged()
	return true
end

function BotService:isSurvivorBot(character: Model): boolean
	local bot = self:_botFromCharacter(character)
	return bot ~= nil and bot.role == "SURVIVOR"
end

function BotService:isZombieBot(character: Model): boolean
	local bot = self:_botFromCharacter(character)
	return bot ~= nil and bot.role == "ZOMBIE"
end

-- A short-lived physics ragdoll "corpse" flung on death. It is a SEPARATE throwaway model
-- (cloned mesh parts joined by BallSocketConstraints, Debris-cleaned after a few seconds),
-- completely decoupled from the bot's own rig + lifecycle — so it can never affect game
-- state or the respawn. Being server-made, it replicates to every client.
local function socketJoint(partA: BasePart, posA: Vector3, partB: BasePart, posB: Vector3)
	local a0 = Instance.new("Attachment")
	a0.Position = posA
	a0.Parent = partA
	local a1 = Instance.new("Attachment")
	a1.Position = posB
	a1.Parent = partB
	local bs = Instance.new("BallSocketConstraint")
	bs.Attachment0 = a0
	bs.Attachment1 = a1
	bs.LimitsEnabled = true
	bs.UpperAngle = 60
	bs.Parent = partA
end

function BotService:_spawnCorpse(bot: Bot)
	local src = bot.model

	-- Rig-agnostic ragdoll: clone every visible part and rebuild the skeleton from the
	-- rig's own Motor6D topology. The previous version hardcoded the four R6 part names,
	-- so it silently produced nothing at all on an R15 avatar.
	local corpse = Instance.new("Model")
	corpse.Name = "Corpse"

	local clones: { [BasePart]: BasePart } = {}
	local motors: { Motor6D } = {}
	for _, descendant in src:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			local clone = descendant:Clone()
			-- Strip welds / nametags / attachments so the clone is a free physics body.
			for _, child in clone:GetChildren() do
				child:Destroy()
			end
			clone.Anchored = false
			clone.CanCollide = true
			clone.Massless = false
			clone.Parent = corpse
			clones[descendant] = clone
		elseif descendant:IsA("Motor6D") then
			table.insert(motors, descendant)
		end
	end

	local root: BasePart? = nil
	for original, clone in clones do
		if root == nil or original.Size.Magnitude > root.Size.Magnitude then
			root = clone
		end
	end
	if root == nil then
		return
	end

	corpse.PrimaryPart = root
	corpse.Parent = workspace

	-- Recreate each joint as a ball socket at the same anchor points the Motor6D used.
	local jointCount = 0
	for _, motor in motors do
		local p0, p1 = motor.Part0, motor.Part1
		if p0 and p1 then
			local a, b = clones[p0], clones[p1]
			if a and b then
				socketJoint(a, motor.C0.Position, b, motor.C1.Position)
				jointCount += 1
			end
		end
	end
	if jointCount == 0 then
		-- No usable skeleton (fallback block rig welds, or a rig we don't understand):
		-- the loose parts still read as a body coming apart, which is fine.
		jointCount = 0
	end

	-- Flop it: a little pop + spin.
	local body = root :: BasePart
	body.AssemblyLinearVelocity = Vector3.new(rng:NextNumber(-12, 12), 18, rng:NextNumber(-12, 12))
	body.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-8, 8), rng:NextNumber(-8, 8), 0)

	-- Green death puff.
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(Color3.fromRGB(90, 200, 60))
	emitter.Lifetime = NumberRange.new(0.3, 0.6)
	emitter.Speed = NumberRange.new(6, 12)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0
	emitter.Enabled = false
	emitter.Parent = body
	emitter:Emit(24)
	Debris:AddItem(corpse, 5)
end

function BotService:_onBotDied(bot: Bot)
	-- Zombie bots respawn near the action; keeps the horde pressure up.
	if not self._active or bot.role ~= "ZOMBIE" then
		return
	end
	-- Fling a ragdoll corpse and hide the real rig until it respawns.
	self:_spawnCorpse(bot)
	for _, part in bot.model:GetDescendants() do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			part.Transparency = 1
		end
	end

	task.delay(GameConfig.Round.ZombieRespawnSeconds, function()
		if not self._active or self._bots[bot.id] == nil then
			return
		end
		local roots = {}
		for _, survivor in self._deps.getHumanSurvivors() do
			local char = survivor.Character
			local r = char and char:FindFirstChild("HumanoidRootPart")
			if r and r:IsA("BasePart") then
				table.insert(roots, r)
			end
		end
		local spawnCFrame = self._deps.getZombieSpawn(roots) or CFrame.new(0, 5, 0)

		-- A dead Humanoid cannot be revived — Roblox treats the Dead state as terminal, so
		-- restoring Health just left a frozen, mute body standing at the spawn point and the
		-- horde quietly stopped existing. Rebuild the rig instead.
		if bot.cleanupAnim then
			bot.cleanupAnim()
			bot.cleanupAnim = nil
		end
		bot.model:Destroy()

		local model, humanoid, root, cleanupAnim = self:_buildRig(bot.name, spawnCFrame)
		model:SetAttribute("IsBot", true)
		model:SetAttribute("BotId", bot.id)
		bot.model = model
		bot.humanoid = humanoid
		bot.root = root
		bot.cleanupAnim = cleanupAnim

		-- Reset navigation and perception; the old path led to wherever it died.
		bot.path = nil
		bot.waypoints = {}
		bot.waypointIndex = 1
		bot.navGoal = nil
		bot.wanderTarget = nil
		bot.searchTarget = nil
		bot.lastKnown = nil
		bot.windupUntil = nil
		bot.justDamaged = false
		bot.lastPos = root.Position
		bot.brain = BotBrain.newMemory("STALK", os.clock())

		self:_applyRole(bot, "ZOMBIE")
		humanoid.Died:Connect(function()
			self:_onBotDied(bot)
		end)
	end)
end

-- AI ----------------------------------------------------------------------------

-- All alive survivor targets (human + bot) as {position, player?, model}.
type Target = { pos: Vector3, player: Player?, model: Model, root: BasePart }

function BotService:_survivorTargets(): { Target }
	local out: { Target } = {}
	for _, survivor in self._deps.getHumanSurvivors() do
		local char = survivor.Character
		local r = char and char:FindFirstChild("HumanoidRootPart")
		if char and r and r:IsA("BasePart") then
			table.insert(out, { pos = r.Position, player = survivor, model = char, root = r })
		end
	end
	for _, bot in self._bots do
		if bot.role == "SURVIVOR" and bot.humanoid.Health > 0 then
			table.insert(out, { pos = bot.root.Position, player = nil, model = bot.model, root = bot.root })
		end
	end
	return out
end

-- Visible infected the survivor bots are allowed to react to: ZOMBIE players and
-- zombie bots. The hidden Patient Zero is deliberately excluded — reacting to it would
-- leak the mind-game.
function BotService:_visibleThreats(): { BasePart }
	local out: { BasePart } = {}
	for _, bot in self._bots do
		if bot.role == "ZOMBIE" and bot.humanoid.Health > 0 then
			table.insert(out, bot.root)
		end
	end
	for _, root in self._deps.getInfectedPlayerRoots() do
		table.insert(out, root)
	end
	return out
end

-- Clear line of sight from a bot's eye to a world point (ignores the bot's own body).
function BotService:_lineOfSight(bot: Bot, targetPos: Vector3): boolean
	local eye = bot.root.Position + Vector3.new(0, 1.5, 0)
	local delta = targetPos - eye
	local dist = delta.Magnitude
	if dist > GameConfig.Bots.SightRange then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { bot.model }
	local result = workspace:Raycast(eye, delta, params)
	if result == nil then
		return true
	end
	-- Something was hit; treat as visible only if it's basically at the target.
	return (result.Position - targetPos).Magnitude < 5
end

-- Compass heading of a direction, in degrees. Used for the vision cone.
local function yawOf(direction: Vector3): number
	return math.deg(math.atan2(direction.X, direction.Z))
end

-- Can this bot actually perceive a point? Range + vision cone + line of sight.
--
-- The cone is the important addition: bots previously had 360-degree awareness, so they
-- could never be flanked and never be surprised.
function BotService:_canSee(bot: Bot, targetPos: Vector3): boolean
	local delta = targetPos - bot.root.Position
	local dist = delta.Magnitude
	if dist < 1e-3 then
		return true
	end
	local facing = yawOf(bot.root.CFrame.LookVector)
	local toTarget = yawOf(delta.Unit)
	return BotVision.canSee(
		dist,
		facing,
		toTarget,
		self:_lineOfSight(bot, targetPos),
		GameConfig.Bots.SightRange * bot.difficulty.sightMult,
		GameConfig.Bots.VisionConeDeg,
		GameConfig.Bots.PeripheralRange
	)
end

-- Nearest perceivable threat, plus whether it is currently visible. Falls back to the
-- remembered last-known position so a bot that loses sight goes looking instead of
-- instantly forgetting the fight it was in.
function BotService:_perceiveThreat(
	bot: Bot,
	now: number,
	threats: { BasePart }
): (Vector3?, number?, boolean)
	local bestPos: Vector3? = nil
	local bestDist = math.huge
	for _, threatRoot in threats do
		local d = (threatRoot.Position - bot.root.Position).Magnitude
		if d < bestDist and self:_canSee(bot, threatRoot.Position) then
			bestPos, bestDist = threatRoot.Position, d
		end
	end
	if bestPos then
		bot.lastKnown = bestPos
		bot.lastContact = now
		return bestPos, bestDist, true
	end
	if
		bot.lastKnown and not BotVision.memoryExpired(now - bot.lastContact, GameConfig.Bots.MemorySeconds)
	then
		return bot.lastKnown, (bot.lastKnown - bot.root.Position).Magnitude, false
	end
	bot.lastKnown = nil
	return nil, nil, false
end

-- Gunfire draws bots to the SOUND. Deliberately position-only: attributing a shot to a
-- shooter would let bots react to the hidden Patient Zero and leak the mind-game.
function BotService:noteGunshot(origin: Vector3)
	if not self._active then
		return
	end
	local now = os.clock()
	for _, bot in self._bots do
		if bot.humanoid.Health > 0 then
			local d = (origin - bot.root.Position).Magnitude
			if BotVision.hearing(d, GameConfig.Bots.HearingRange) > 0 then
				-- Only follow a noise we don't already have something better than.
				if bot.lastKnown == nil or (now - bot.lastContact) > 1.5 then
					bot.lastKnown = origin
					bot.lastContact = now
				end
			end
		end
	end
end

-- Compute a fresh path toward `goal` off the hot loop (ComputeAsync yields).
function BotService:_computePath(bot: Bot, goal: Vector3)
	if bot.computing then
		return
	end
	bot.computing = true
	bot.navGoal = goal
	bot.lastRepath = os.clock()
	task.spawn(function()
		local path = PathfindingService:CreatePath({
			AgentRadius = GameConfig.Bots.AgentRadius,
			AgentHeight = GameConfig.Bots.AgentHeight,
			AgentCanJump = true,
			-- Opt into ladders. Without this the navmesh ignores TrussParts entirely, so
			-- every ladder-only route on a map is invisible to a bot.
			AgentCanClimb = true,
		})
		local ok = pcall(function()
			path:ComputeAsync(bot.root.Position, goal)
		end)
		bot.computing = false
		if not self._active or self._bots[bot.id] == nil then
			return
		end
		if ok and path.Status == Enum.PathStatus.Success then
			bot.path = path
			bot.waypoints = path:GetWaypoints()
			bot.waypointIndex = 2 -- skip [1] (the bot's current position)
		else
			-- No path: clear so the caller falls back to a direct move.
			bot.path = nil
			bot.waypoints = {}
			bot.waypointIndex = 1
		end
	end)
end

-- Follow the current waypoint list; returns false if there is nothing to follow.
function BotService:_followPath(bot: Bot): boolean
	local waypoints = bot.waypoints
	if #waypoints == 0 or bot.waypointIndex > #waypoints then
		return false
	end
	local wp = waypoints[bot.waypointIndex]
	local flat = Vector3.new(wp.Position.X - bot.root.Position.X, 0, wp.Position.Z - bot.root.Position.Z)
	if flat.Magnitude < GameConfig.Bots.WaypointReached then
		bot.waypointIndex += 1
		if bot.waypointIndex > #waypoints then
			return false
		end
		wp = waypoints[bot.waypointIndex]
	end
	if wp.Action == Enum.PathWaypointAction.Jump then
		bot.humanoid.Jump = true
	end
	bot.humanoid:MoveTo(wp.Position)
	return true
end

-- Drive the bot toward `goal`, recomputing the path only when worthwhile, and recovering
-- from getting wedged on geometry.
function BotService:_navigateTo(bot: Bot, goal: Vector3, now: number, speed: number)
	bot.humanoid.WalkSpeed = speed

	-- Stuck detection: barely moved since the last check while we still have distance to go.
	if now - bot.lastMoveCheck > 0.4 then
		local moved = (bot.root.Position - bot.lastPos).Magnitude
		local movedSpeed = moved / math.max(0.001, now - bot.lastMoveCheck)
		bot.lastPos = bot.root.Position
		bot.lastMoveCheck = now
		if movedSpeed < GameConfig.Bots.StuckSpeed and (goal - bot.root.Position).Magnitude > 6 then
			bot.stuckSince = bot.stuckSince or now
			if now - (bot.stuckSince :: number) > GameConfig.Bots.StuckRepathAfter then
				bot.humanoid.Jump = true
				bot.stuckSince = nil
				bot.navGoal = nil -- force a repath below
			end
		else
			bot.stuckSince = nil
		end
	end

	local needRepath = bot.navGoal == nil
		or (goal - (bot.navGoal :: Vector3)).Magnitude > GameConfig.Bots.RepathDistance
		or (now - bot.lastRepath > GameConfig.Bots.RepathInterval and bot.waypointIndex > #bot.waypoints)
	if needRepath then
		self:_computePath(bot, goal)
	end

	if not self:_followPath(bot) then
		-- Fallback while a path is still computing or unavailable: head straight there.
		bot.humanoid:MoveTo(goal)
	end
end

-- Survivor bots shoot VISIBLE zombie bots (and only those — see _visibleThreats). Purely
-- to make the battlefield feel alive; damage is applied without crediting any player.
function BotService:_survivorGunfire(bot: Bot, now: number, threats: { BasePart })
	if now < bot.nextShotAt then
		return
	end
	local target: BasePart? = nil
	local bestDist = GameConfig.Bots.ShootRange * bot.difficulty.sightMult
	for _, threatRoot in threats do
		local d = (threatRoot.Position - bot.root.Position).Magnitude
		if d < bestDist and self:_canSee(bot, threatRoot.Position) then
			target, bestDist = threatRoot, d
		end
	end
	if target == nil then
		bot.aimingSince = nil
		return
	end
	-- Human-like: take a beat to "aim" before the first shot.
	if bot.aimingSince == nil then
		bot.aimingSince = now
			+ rng:NextNumber(GameConfig.Bots.ShootReactionMin, GameConfig.Bots.ShootReactionMax)
				* bot.difficulty.reactionMult
		return
	end
	if now < (bot.aimingSince :: number) then
		return
	end

	-- Jittered cadence. A fixed 0.9s interval read as a metronome.
	local jitter = GameConfig.Bots.ShootIntervalJitter
	bot.nextShotAt = now
		+ (GameConfig.Bots.ShootInterval + rng:NextNumber(-jitter, jitter)) * bot.difficulty.fireRateMult

	local weaponId = GameConfig.Bots.BotWeapon
	local spec = (GameConfig.Combat.Guns :: any)[weaponId]
	local origin = bot.root.Position + Vector3.new(0, 1.5, 0)
	local aim = (target.Position - origin).Unit

	-- Roll a real cone and raycast for real. The old code aimed perfectly every time and
	-- decided hits with a coin flip on DAMAGE, so the tracer always pointed dead centre and
	-- a miss was invisible — firefights looked broken.
	local spreadDeg = GameConfig.Bots.ShootSpreadDeg * bot.difficulty.spreadMult
	local offset = Ballistics.coneOffset(spreadDeg, rng:NextNumber(), rng:NextNumber())
	local up = if Ballistics.safeUpAxis(aim.Y) == "Z" then Vector3.zAxis else Vector3.yAxis
	local direction = (CFrame.lookAt(Vector3.zero, aim, up) * CFrame.Angles(
		math.rad(offset.pitchDeg),
		math.rad(offset.yawDeg),
		0
	)).LookVector

	-- Broadcast the ACTUAL direction so a miss is visibly a miss.
	self._deps.remotes.fireAllClients("ShotFired", {
		shooterUserId = -bot.id, -- negative id marks a bot shooter (no real player)
		origin = origin,
		direction = direction,
		weaponId = weaponId,
	})

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { bot.model }
	local result = workspace:Raycast(origin, direction * spec.Range, params)
	if result == nil then
		return
	end
	local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
	if hitModel == nil then
		return
	end

	-- Bot bullets hurt zombie bots AND human zombies. Previously they could only damage
	-- zombie bots, so bots were cosmetic in any fight involving a real player.
	local victim = self:_botFromCharacter(hitModel)
	if victim then
		if victim.role == "ZOMBIE" then
			self:_reactToDamage(victim)
			victim.humanoid:TakeDamage(spec.Damage)
		end
		return
	end
	if self._deps.damageInfectedPlayer then
		self._deps.damageInfectedPlayer(hitModel, spec.Damage)
	end
end

-- A bot that gets shot flinches and turns toward the source. Nothing in the old file
-- reacted to taking damage at all.
function BotService:_reactToDamage(bot: Bot, source: Vector3?)
	bot.justDamaged = true
	if source then
		bot.lastKnown = source
		bot.lastContact = os.clock()
	end
end

-- Pick a target for the Patient Zero: the most isolated survivor (fewest neighbours),
-- so the hidden infected stalks stragglers instead of charging the pack.
function BotService:_isolatedTarget(targets: { Target }): Target?
	local best: Target? = nil
	local bestScore = math.huge
	for _, t in targets do
		local neighbours = 0
		for _, other in targets do
			if other ~= t and (other.pos - t.pos).Magnitude < GameConfig.Bots.GroupRadius then
				neighbours += 1
			end
		end
		if neighbours < bestScore then
			best, bestScore = t, neighbours
		end
	end
	return best
end

-- Idle emote. Bots stop and wave/dance now and then while patrolling, which is most of what
-- separates "a person standing around" from "an NPC waiting for a path".
--
-- PATIENT ZERO GUARD: uses exactly the same rule players do (Emotes.canPlay), so a bot
-- Patient Zero emotes just like a survivor bot. If only true survivors emoted, the one bot
-- that never waved would be the infected one — the absence would be the tell.
function BotService:_maybeEmote(bot: Bot, now: number): boolean
	if bot.emoteUntil and now < bot.emoteUntil then
		-- Mid-emote: hold still so the animation reads.
		bot.humanoid:Move(Vector3.zero)
		return true
	end
	bot.emoteUntil = nil

	if not Emotes.canPlay(bot.role) then
		return false
	end
	if now < bot.nextEmoteAt or rng:NextNumber() > GameConfig.Bots.EmoteChance then
		return false
	end

	local animator = bot.humanoid:FindFirstChildOfClass("Animator")
	if animator == nil then
		return false
	end
	local emote = Emotes.Catalog[rng:NextInteger(1, #Emotes.Catalog)]
	local animation = Instance.new("Animation")
	animation.AnimationId = "rbxassetid://" .. emote.animationId
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(animation)
	end)
	if not ok or track == nil then
		return false
	end
	local loaded = track :: AnimationTrack
	loaded.Priority = Enum.AnimationPriority.Action
	loaded.Looped = false
	loaded:Play(0.15)

	-- Hold still only briefly, even for a long dance: a bot frozen for four seconds is a
	-- free kill, and the flavour lands in the first beat anyway. The track is cut short
	-- rather than the emote list being restricted to short ones.
	local hold = math.min(emote.duration, GameConfig.Bots.EmoteMaxHold)
	bot.emoteUntil = now + hold
	bot.nextEmoteAt = now + GameConfig.Bots.EmoteCooldown + rng:NextNumber(0, 10)
	bot.humanoid:Move(Vector3.zero)
	task.delay(hold, function()
		pcall(function()
			loaded:Stop(0.2)
			loaded:Destroy()
		end)
	end)
	return true
end

-- `targets` (alive survivors) and `threats` (visible infected) are computed ONCE per tick
-- in start() and shared across all bots, instead of each bot rebuilding them several times.
function BotService:_stepBot(bot: Bot, now: number, targets: { Target }, threats: { BasePart })
	if bot.humanoid.Health <= 0 then
		return
	end
	local pos = bot.root.Position
	local infected = bot.role ~= "SURVIVOR"

	-- Perception snapshot -> state machine. The old code was a straight-line if/else with
	-- no memory and no hysteresis, so bots flipped state every tick at the flee boundary
	-- and forgot a target the instant line of sight broke.
	local threatPos, threatDist, threatVisible
	if infected then
		local target: Target? = if bot.role == "PATIENT_ZERO" then self:_isolatedTarget(targets) else nil
		if target == nil then
			local bestDist = math.huge
			for _, t in targets do
				local d = (t.pos - pos).Magnitude
				-- Infected now need to actually perceive a survivor to chase them. The chase
				-- branch never checked line of sight before, giving zombie bots wallhacks.
				if d < bestDist and self:_canSee(bot, t.pos) then
					target, bestDist = t, d
				end
			end
		end
		if target then
			threatPos = (target :: Target).pos
			threatDist = (threatPos - pos).Magnitude
			threatVisible = self:_canSee(bot, threatPos)
			if threatVisible then
				bot.lastKnown = threatPos
				bot.lastContact = now
			end
		end
		-- Nothing in sight: fall back to the short-range flesh sense before giving up, so
		-- the horde keeps closing instead of milling about. Marked not-visible, so the brain
		-- treats it as a lead to follow rather than a target it can attack from range.
		if threatPos == nil then
			local nearest, nearestDist = nil, GameConfig.Bots.InfectedSenseRadius
			for _, t in targets do
				local d = (t.pos - pos).Magnitude
				if d < nearestDist then
					nearest, nearestDist = t, d
				end
			end
			if nearest then
				bot.lastKnown = (nearest :: Target).pos
				bot.lastContact = now
			end
		end

		if threatPos == nil and bot.lastKnown then
			if not BotVision.memoryExpired(now - bot.lastContact, GameConfig.Bots.MemorySeconds) then
				threatPos = bot.lastKnown
				threatDist = (bot.lastKnown - pos).Magnitude
				threatVisible = false
			else
				bot.lastKnown = nil
			end
		end
	else
		threatPos, threatDist, threatVisible = self:_perceiveThreat(bot, now, threats)
	end

	local allyCount = 0
	for _, t in targets do
		if t.root ~= bot.root and (t.pos - pos).Magnitude < GameConfig.Bots.GroupRadius then
			allyCount += 1
		end
	end

	local state = BotBrain.next(bot.brain, bot.role, {
		threatDist = threatDist,
		threatVisible = threatVisible,
		hasLastKnown = bot.lastKnown ~= nil,
		timeSinceContact = now - bot.lastContact,
		health01 = bot.humanoid.Health / math.max(1, bot.humanoid.MaxHealth),
		allyCount = allyCount,
		justDamaged = bot.justDamaged,
	}, bot.brainConfig, now)
	bot.justDamaged = false

	local sprint = GameConfig.Movement.SprintWalkSpeed
	local walk = GameConfig.Movement.BaseWalkSpeed

	if state ~= "PATROL" and bot.emoteUntil then
		bot.emoteUntil = nil
	end

	if state == "STAGGER" then
		-- Flinch: stop moving and face where it came from. A bot that ignores being shot
		-- is the clearest tell that it isn't a player.
		bot.humanoid:Move(Vector3.zero)
		if bot.lastKnown then
			local look = bot.lastKnown - pos
			if math.abs(look.X) + math.abs(look.Z) > 0.1 then
				bot.root.CFrame = CFrame.lookAt(pos, Vector3.new(bot.lastKnown.X, pos.Y, bot.lastKnown.Z))
			end
		end
		return
	end

	if state == "ENGAGE" then
		self:_survivorGunfire(bot, now, threats)
		-- Hold position and shoot rather than walking into the muzzle.
		if threatPos then
			bot.humanoid:Move(Vector3.zero)
			bot.root.CFrame = CFrame.lookAt(pos, Vector3.new(threatPos.X, pos.Y, threatPos.Z))
		end
		return
	end

	if state == "FLEE" then
		local from = threatPos or pos + Vector3.new(1, 0, 0)
		local away = pos - from
		away = Vector3.new(away.X, 0, away.Z)
		local flee = pos + (away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)) * 30
		self:_navigateTo(bot, flee, now, sprint)
		-- Fire while backing off if there's still something to shoot at.
		self:_survivorGunfire(bot, now, threats)
		return
	end

	if state == "SEARCH" then
		-- Sweep around where the target was last seen, fanning out as the trail cools.
		if bot.searchTarget == nil or (bot.searchTarget - pos).Magnitude < 6 then
			local anchor = bot.lastKnown or pos
			local radius = BotVision.searchRadius(
				now - bot.lastContact,
				GameConfig.Bots.SearchRadiusBase,
				GameConfig.Bots.SearchRadiusGrowth
			)
			bot.searchTarget = anchor
				+ Vector3.new(rng:NextNumber(-radius, radius), 0, rng:NextNumber(-radius, radius))
		end
		self:_navigateTo(bot, bot.searchTarget or pos, now, walk * 1.1)
		if not infected then
			self:_survivorGunfire(bot, now, threats)
		end
		return
	end
	bot.searchTarget = nil

	if state == "REGROUP" then
		local sum, count = Vector3.zero, 0
		for _, t in targets do
			if t.root ~= bot.root then
				sum += t.pos
				count += 1
			end
		end
		local goal = if count > 0 then sum / count else pos
		self:_navigateTo(bot, goal, now, walk)
		self:_survivorGunfire(bot, now, threats)
		return
	end

	if state == "HUNT" or state == "STALK" then
		-- A committed zombie has to outrun a sprinting survivor. At plain walk speed the
		-- horde simply trails the pack forever and nobody is ever caught.
		local chaseSpeed = walk
			* (if bot.role == "PATIENT_ZERO" then GameConfig.Combat.PatientZero.SprintMult else 1)
			* bot.difficulty.speedMult
		if state == "HUNT" then
			chaseSpeed = math.max(chaseSpeed, sprint * GameConfig.Bots.HuntSpeedMult / 1.5)
		elseif threatVisible then
			-- Stalking hangs back slightly, but never below a survivor's walking pace.
			chaseSpeed *= 0.9
		end
		local goal = threatPos or bot.lastKnown
		if goal == nil then
			-- Nothing perceived: patrol so the horde keeps pressure on rather than idling.
			if bot.wanderTarget == nil or (bot.wanderTarget - pos).Magnitude < 8 then
				local spawn = self._deps.getSurvivorSpawn()
				bot.wanderTarget = spawn and spawn.Position
					or (pos + Vector3.new(rng:NextNumber(-30, 30), 0, rng:NextNumber(-30, 30)))
			end
			self:_navigateTo(bot, bot.wanderTarget or pos, now, chaseSpeed)
			return
		end
		self:_navigateTo(bot, goal, now, chaseSpeed)

		local range = GameConfig.Combat.Zombie.MeleeRange
		if threatDist and threatDist <= range then
			-- Telegraphed attack: wind up, then convert. Previously a single touch converted
			-- instantly with no animation and no chance to react.
			if bot.windupUntil == nil then
				if now - bot.lastAction > 1 * bot.difficulty.reactionMult then
					bot.windupUntil = now + GameConfig.Bots.MeleeWindup
				end
			elseif now >= (bot.windupUntil :: number) then
				bot.windupUntil = nil
				bot.lastAction = now
				-- Re-check range at the end of the wind-up so the swing can be dodged, but
				-- against LIVE positions and with lunge reach. Checking the tick-start
				-- snapshot at exact melee range meant a survivor who kept walking was always
				-- already gone, so the swing could never land.
				local reach = range * GameConfig.Bots.MeleeLungeReach
				local victim: Target? = nil
				for _, t in targets do
					local livePos = if t.root and t.root.Parent then t.root.Position else t.pos
					if (livePos - bot.root.Position).Magnitude <= reach then
						victim = t
						break
					end
				end
				if victim then
					local v = victim :: Target
					if v.player then
						self._deps.convertHuman(v.player)
					else
						self:convertBot(v.model, nil)
					end
				end
			end
			return
		end
		bot.windupUntil = nil
		return
	end

	-- PATROL: wander toward map patrol points, spread by personality.
	if self:_maybeEmote(bot, now) then
		return
	end
	local reached = bot.wanderTarget == nil or (bot.wanderTarget - pos).Magnitude < 8
	if reached then
		local point = self._deps.getPatrolPoint and self._deps.getPatrolPoint()
		local spread = bot.personality == "cautious" and 16 or 34
		bot.wanderTarget = point
			or (pos + Vector3.new(rng:NextNumber(-spread, spread), 0, rng:NextNumber(-spread, spread)))
	end
	self:_navigateTo(bot, bot.wanderTarget or pos, now, walk)
	if not infected then
		self:_survivorGunfire(bot, now, threats)
	end
end

function BotService:start()
	RunService.Heartbeat:Connect(function()
		if not self._active then
			return
		end
		local now = os.clock()
		-- Snapshot the shared world state once per tick (not once per bot per check).
		local targets: { Target }? = nil
		local threats: { BasePart }? = nil
		for _, bot in self._bots do
			-- Each bot thinks on its own offset within the interval. Previously every bot
			-- decided on the same frame, which spiked frame time and made a squad of bots
			-- turn in perfect unison.
			if now >= bot.nextThink then
				bot.nextThink = now + GameConfig.Bots.ThinkInterval
				if targets == nil then
					targets = self:_survivorTargets()
					threats = self:_visibleThreats()
				end
				self:_stepBot(bot, now, targets :: { Target }, threats :: { BasePart })
			end
		end
	end)
end

return BotService
