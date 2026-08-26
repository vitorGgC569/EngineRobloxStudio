--!strict
-- Owns who is what during a round: SURVIVOR / PATIENT_ZERO / ZOMBIE.
-- Handles conversion on death, zombie respawns, mid-round joiners (join the horde),
-- and Patient Zero disconnects. All role state is server-only; clients get told
-- their own role privately and see zombie appearance changes through replication.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local PatientZero = require(Shared.PatientZero)

export type Role = "SURVIVOR" | "PATIENT_ZERO" | "ZOMBIE" | "NONE"

local RoleService = {}
RoleService.__index = RoleService

export type Deps = {
	remotes: any, -- Remotes.ServerApi
	onConversion: (victim: Player, killer: Player?) -> (), -- extend timer, rewards, alerts
	onSurvivorCountChanged: (count: number) -> (),
	onPatientZeroGone: () -> (), -- PZ left with no zombies yet -> round should end
	getSurvivorSpawn: (() -> CFrame?)?, -- map spawn points (nil -> default spawn)
	getZombieSpawn: ((survivorRoots: { BasePart }) -> CFrame?)?,
	getEquippedGunSkin: ((player: Player) -> string?)?, -- cosmetic gun tint
	-- Optional: tell anti-cheat a CFrame write was intentional so it does not kick.
	noteTrustedTeleport: ((player: Player) -> ())?,
}

local rng = Random.new()

function RoleService.new(deps: Deps)
	local self = setmetatable({}, RoleService)
	self._deps = deps
	self._roles = {} :: { [Player]: Role }
	self._roundActive = false
	self._patientZero = nil :: Player?
	self._firstBloodDone = false
	-- userId -> rounds since they were PZ (incremented each round start)
	self._pzHistory = {} :: { [number]: number }
	-- Kept for the end-of-round reveal even if PZ dies/leaves mid-round
	self._originalPZ = nil :: { userId: number, name: string }?
	self._charConns = {} :: { [Player]: { RBXScriptConnection } }
	self._abilityLastUse = {} :: { [Player]: number } -- os.clock of last ability activation
	return self
end

-- Appearance ------------------------------------------------------------------

local function applyZombieAppearance(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.MaxHealth = GameConfig.Combat.ZombieBaseHealth
		humanoid.Health = GameConfig.Combat.ZombieBaseHealth
		humanoid.WalkSpeed = GameConfig.Movement.BaseWalkSpeed
	end
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			-- Brighter and slightly emissive. The old dark Slate green sat within a few
			-- shades of the concrete floors, which is most of why zombies were unreadable.
			part.Color = Color3.fromRGB(126, 226, 96)
			part.Material = Enum.Material.Neon
		elseif part:IsA("Shirt") or part:IsA("Pants") or part:IsA("ShirtGraphic") then
			part:Destroy()
		end
	end

	-- Outline so a zombie reads instantly against any wall at any light level.
	--
	-- PATIENT ZERO GUARD: this function is only ever called for a confirmed ZOMBIE. It must
	-- never be reached for PATIENT_ZERO — the hidden PZ looks exactly like a survivor, and
	-- that mind-game is the whole game. DepthMode is Occluded, not AlwaysOnTop, so this is a
	-- readability aid and not a sanctioned wallhack.
	local highlight = Instance.new("Highlight")
	highlight.Name = "InfectionOutline"
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = Color3.fromRGB(80, 220, 60)
	highlight.FillTransparency = 0.75
	highlight.OutlineColor = Color3.fromRGB(180, 255, 140)
	highlight.OutlineTransparency = 0
	highlight.Parent = character

	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local particles = Instance.new("ParticleEmitter")
		particles.Name = "InfectionAura"
		particles.Color = ColorSequence.new(Color3.fromRGB(90, 200, 60))
		particles.Lifetime = NumberRange.new(0.4, 0.9)
		particles.Rate = 35
		particles.Speed = NumberRange.new(0.5, 1.5)
		particles.Size = NumberSequence.new(0.6)
		particles.Transparency = NumberSequence.new(0.35)
		particles.LightEmission = 0.5
		particles.Parent = root
	end
end

local function applySpawnProtection(character: Model)
	local ff = Instance.new("ForceField")
	ff.Parent = character
	task.delay(GameConfig.Round.SpawnProtectionSeconds, function()
		ff:Destroy()
	end)
end

-- LoadCharacter that tolerates the player leaving mid-call. Returns nil if the
-- character never arrives (player gone) rather than yielding forever.
function RoleService:_safeLoadCharacter(player: Player): Model?
	local ok = pcall(function()
		player:LoadCharacter()
	end)
	if not ok then
		return nil
	end
	local character = player.Character
	local waited = 0
	while character == nil and player.Parent ~= nil and waited < 5 do
		waited += task.wait(0.1)
		character = player.Character
	end
	return character
end

-- Role queries ----------------------------------------------------------------

function RoleService:getRole(player: Player): Role
	return self._roles[player] or "NONE"
end

function RoleService:isInfected(player: Player): boolean
	local role = self:getRole(player)
	return role == "PATIENT_ZERO" or role == "ZOMBIE"
end

function RoleService:getPatientZero(): Player?
	return self._patientZero
end

function RoleService:getOriginalPatientZero(): { userId: number, name: string }?
	return self._originalPZ
end

-- Used when a bot is Patient Zero, so the end-of-round reveal can name it.
function RoleService:setOriginalPZName(name: string)
	self._originalPZ = { userId = -1, name = name }
end

function RoleService:survivorCount(): number
	local n = 0
	for _, role in self._roles do
		if role == "SURVIVOR" then
			n += 1
		end
	end
	return n
end

function RoleService:survivors(): { Player }
	local out = {}
	for player, role in self._roles do
		if role == "SURVIVOR" then
			table.insert(out, player)
		end
	end
	return out
end

-- Roots of players who are VISIBLY infected (role ZOMBIE). Deliberately excludes the
-- hidden Patient Zero, so bots reacting to these roots never leak the mind-game.
function RoleService:zombiePlayerRoots(): { BasePart }
	local out: { BasePart } = {}
	for player, role in self._roles do
		if role == "ZOMBIE" then
			local char = player.Character
			local r = char and char:FindFirstChild("HumanoidRootPart")
			if r and r:IsA("BasePart") then
				table.insert(out, r)
			end
		end
	end
	return out
end

-- Round lifecycle ---------------------------------------------------------------

-- opts.allSurvivors: no human is Patient Zero this round (a bot will be instead).
function RoleService:assignRoles(playersInRound: { Player }, opts: { allSurvivors: boolean }?)
	self._roundActive = true
	self._firstBloodDone = false
	table.clear(self._roles)

	-- age the PZ history one round; prune entries past the window (memory: finding #10)
	for userId, rounds in self._pzHistory do
		if rounds + 1 > GameConfig.Round.PatientZeroRecentRounds then
			self._pzHistory[userId] = nil
		else
			self._pzHistory[userId] = rounds + 1
		end
	end

	local candidates = {}
	for _, player in playersInRound do
		table.insert(candidates, { userId = player.UserId, roundsSincePZ = self._pzHistory[player.UserId] })
	end
	local pzUserId = if opts and opts.allSurvivors
		then -1
		else PatientZero.select(candidates, GameConfig.Round.PatientZeroRecentRounds, function()
			return rng:NextNumber()
		end)

	for _, player in playersInRound do
		if player.UserId == pzUserId then
			self._roles[player] = "PATIENT_ZERO"
			self._patientZero = player
			self._originalPZ = { userId = player.UserId, name = player.DisplayName }
			self._pzHistory[player.UserId] = 0
		else
			self._roles[player] = "SURVIVOR"
		end
	end

	-- Everyone (re)spawns fresh for the round. Players can leave at ANY yield in
	-- this loop (finding #1), so each iteration is leaver-safe and never blocks
	-- unboundedly on a character that will never arrive.
	for _, player in playersInRound do
		if player.Parent == nil then
			self._roles[player] = nil
			continue
		end
		local character = self:_safeLoadCharacter(player)
		if character == nil then
			self._roles[player] = nil
			continue
		end
		if self._deps.getSurvivorSpawn then
			local spawnCFrame = self._deps.getSurvivorSpawn()
			local root = character:WaitForChild("HumanoidRootPart", 5)
			if spawnCFrame and root and root:IsA("BasePart") then
				root.CFrame = spawnCFrame
				if self._deps.noteTrustedTeleport then
					self._deps.noteTrustedTeleport(player)
				end
			end
		end
		applySpawnProtection(character)
		self:_watchCharacter(player, character)
		-- Everyone holds a gun — the hidden PZ must be indistinguishable
		local WeaponVisuals = require(script.Parent.WeaponVisuals)
		local gunSkin = self._deps.getEquippedGunSkin and self._deps.getEquippedGunSkin(player) or nil
		WeaponVisuals.attachGun(character, gunSkin)
		local role = self._roles[player]
		-- Private role card — the ONLY place a client learns its role
		self._deps.remotes.fireClient("RoleAssigned", player, { role = role })
	end

	-- The chosen PZ may have left during the spawn loop
	if self._patientZero ~= nil and self._patientZero.Parent == nil then
		self._roles[self._patientZero] = nil
		self._patientZero = nil
		self._deps.onPatientZeroGone()
	end

	-- Do NOT push survivor count here. assignRoles runs before botService:spawnForRound
	-- in onRoundStart; notifying with humans-only (often 0 when the sole human is PZ)
	-- made the round machine end as INFECTED instantly. Caller must refreshCounts()
	-- after bots are fielded.
end

function RoleService:endRound()
	self._roundActive = false
	self._patientZero = nil
	for player in self._roles do
		self:_unwatchCharacter(player)
	end
	table.clear(self._roles)
	-- Fresh lobby characters (auto-loads are off; nothing else will respawn them)
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:spawnLobby(player)
		end)
	end
end

-- Conversion ------------------------------------------------------------------

function RoleService:convert(victim: Player, killer: Player?)
	if not self._roundActive then
		return
	end
	local role = self._roles[victim]
	if role ~= "SURVIVOR" then
		return -- already infected or not in round
	end
	self._roles[victim] = "ZOMBIE"

	-- Survivor count reaches the round machine BEFORE any reward hooks: onConversion
	-- can yield on web calls, and a stale count during that yield can flip the
	-- winner at timer expiry (finding #3).
	self._deps.onSurvivorCountChanged(self:survivorCount())
	self._deps.remotes.fireClient("RoleAssigned", victim, { role = "ZOMBIE" })
	self._deps.onConversion(victim, killer)

	-- Respawn as zombie after a beat
	task.delay(GameConfig.Round.ZombieRespawnSeconds, function()
		if self._roundActive and self._roles[victim] == "ZOMBIE" and victim.Parent ~= nil then
			self:_spawnAsZombie(victim)
		end
	end)
end

function RoleService:_hordeFraction(): number
	local total, infected = 0, 0
	for _, role in self._roles do
		total += 1
		if role == "ZOMBIE" or role == "PATIENT_ZERO" then
			infected += 1
		end
	end
	if total == 0 then
		return 0
	end
	return infected / total
end

function RoleService:_pickZombieClass(): GameConfig.ZombieClass
	local fraction = self:_hordeFraction()
	local unlocked = {}
	for _, class in GameConfig.ZombieClasses do
		if fraction >= class.hordeThreshold then
			table.insert(unlocked, class)
		end
	end
	return unlocked[rng:NextInteger(1, math.max(1, #unlocked))] or GameConfig.ZombieClasses[1]
end

function RoleService:_applyZombieClass(player: Player, character: Model, class: GameConfig.ZombieClass)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.MaxHealth = class.maxHealth
		humanoid.Health = class.maxHealth
		humanoid.WalkSpeed = GameConfig.Movement.BaseWalkSpeed * class.walkSpeedMult
	end
	character:SetAttribute("ZombieClass", class.name)
	self._deps.remotes.fireClient("HordeUpdate", player, { yourClass = class.name })
	-- Tell the client whether this class has a player-activated ability (for the button).
	local activated = (class.ability == "lunge" or class.ability == "cloak") and class.ability or nil
	self._deps.remotes.fireClient("AbilityState", player, {
		ability = activated,
		cooldown = class.abilityCooldown or 0,
		ready = true,
	})

	if class.ability == "scream" and class.abilityCooldown then
		-- Screamer: pulses survivor positions to the whole horde while alive
		task.spawn(function()
			while
				self._roundActive
				and self._roles[player] == "ZOMBIE"
				and player.Character == character
				and humanoid
				and humanoid.Health > 0
			do
				task.wait(class.abilityCooldown)
				if self._roundActive and player.Character == character and humanoid.Health > 0 then
					local positions = {}
					for _, survivor in self:survivors() do
						local sRoot = survivor.Character
							and survivor.Character:FindFirstChild("HumanoidRootPart")
						if sRoot and sRoot:IsA("BasePart") then
							table.insert(positions, {
								userId = survivor.UserId,
								name = survivor.DisplayName,
								x = sRoot.Position.X,
								y = sRoot.Position.Y,
								z = sRoot.Position.Z,
							})
						end
					end
					if #positions > 0 then
						self._deps.remotes.fireAllClients(
							"SurvivorPing",
							{ survivors = positions, scream = true }
						)
					end
				end
			end
		end)
	end
end

-- Lunge: a brief, anti-cheat-safe absolute speed burst to run down fleeing survivors.
function RoleService:_abilityLunge(player: Player, character: Model, humanoid: Humanoid, class: any)
	local baseSpeed = GameConfig.Movement.BaseWalkSpeed * class.walkSpeedMult
	humanoid.WalkSpeed = GameConfig.Lunge.Speed
	task.delay(GameConfig.Lunge.Duration, function()
		if self._roles[player] == "ZOMBIE" and player.Character == character and humanoid.Health > 0 then
			humanoid.WalkSpeed = baseSpeed
		end
	end)
end

-- Cloak: fade the Stalker's body and hide its infection aura for a short window so it can
-- sneak up. Server-set transparency replicates to everyone; no movement/anti-cheat impact.
function RoleService:_abilityCloak(player: Player, character: Model, humanoid: Humanoid, _class: any)
	local restore: { [BasePart]: number } = {}
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			restore[part] = part.Transparency
			part.Transparency = GameConfig.Cloak.Transparency
		elseif part:IsA("ParticleEmitter") and part.Name == "InfectionAura" then
			part.Enabled = false
		end
	end
	-- The readability outline has to go too, or cloaking hides nothing.
	local outline = character:FindFirstChild("InfectionOutline")
	if outline and outline:IsA("Highlight") then
		outline.Enabled = false
	end
	task.delay(GameConfig.Cloak.Duration, function()
		if player.Character ~= character then
			return
		end
		for part, original in restore do
			if part.Parent ~= nil then
				part.Transparency = original
			end
		end
		local aura = character:FindFirstChild("InfectionAura", true)
		if aura and aura:IsA("ParticleEmitter") and humanoid.Health > 0 then
			aura.Enabled = true
		end
		local cloakedOutline = character:FindFirstChild("InfectionOutline")
		if cloakedOutline and cloakedOutline:IsA("Highlight") and humanoid.Health > 0 then
			cloakedOutline.Enabled = true
		end
	end)
end

-- Player activated their zombie-class ability (lunge / cloak; scream is passive).
function RoleService:useAbility(player: Player)
	if not self._roundActive or self._roles[player] ~= "ZOMBIE" then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if character == nil or humanoid == nil or (humanoid :: Humanoid).Health <= 0 then
		return
	end
	local className = character:GetAttribute("ZombieClass")
	local class
	for _, c in GameConfig.ZombieClasses do
		if c.name == className then
			class = c
			break
		end
	end
	local ability = class and class.ability
	if ability ~= "lunge" and ability ~= "cloak" then
		return -- no player-activated ability for this class
	end
	local cooldown = class.abilityCooldown or 8
	local now = os.clock()
	local last = self._abilityLastUse[player] or -math.huge
	if now - last < cooldown then
		return -- still cooling down
	end
	self._abilityLastUse[player] = now

	local h = humanoid :: Humanoid
	if ability == "lunge" then
		self:_abilityLunge(player, character :: Model, h, class)
	else
		self:_abilityCloak(player, character :: Model, h, class)
	end
	self._deps.remotes.fireClient(
		"AbilityState",
		player,
		{ ability = ability, cooldown = cooldown, ready = false }
	)
	task.delay(cooldown, function()
		if self._roles[player] == "ZOMBIE" and player.Parent ~= nil then
			self._deps.remotes.fireClient(
				"AbilityState",
				player,
				{ ability = ability, cooldown = cooldown, ready = true }
			)
		end
	end)
end

function RoleService:_spawnAsZombie(player: Player)
	local character = self:_safeLoadCharacter(player)
	if character == nil then
		return -- player left mid-respawn
	end
	if self._deps.getZombieSpawn then
		local survivorRoots = {}
		for _, survivor in self:survivors() do
			local sChar = survivor.Character
			local sRoot = sChar and sChar:FindFirstChild("HumanoidRootPart")
			if sRoot and sRoot:IsA("BasePart") then
				table.insert(survivorRoots, sRoot)
			end
		end
		local spawnCFrame = self._deps.getZombieSpawn(survivorRoots)
		local root = character:WaitForChild("HumanoidRootPart", 5)
		if spawnCFrame and root and root:IsA("BasePart") then
			root.CFrame = spawnCFrame
			if self._deps.noteTrustedTeleport then
				self._deps.noteTrustedTeleport(player)
			end
		end
	end
	applyZombieAppearance(character)
	self:_applyZombieClass(player, character, self:_pickZombieClass())
	applySpawnProtection(character)
	self:_watchCharacter(player, character)
end

-- Death & connection plumbing ---------------------------------------------------

function RoleService:_watchCharacter(player: Player, character: Model)
	self:_unwatchCharacter(player)
	local conns = {}
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if humanoid and humanoid:IsA("Humanoid") then
		table.insert(
			conns,
			humanoid.Died:Connect(function()
				self:_onDied(player)
			end)
		)
	end
	self._charConns[player] = conns
end

function RoleService:_unwatchCharacter(player: Player)
	local conns = self._charConns[player]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		self._charConns[player] = nil
	end
end

function RoleService:_onDied(player: Player)
	if not self._roundActive then
		return
	end
	local role = self._roles[player]
	if role == "SURVIVOR" then
		-- ANY death converts (fall damage included, per spec)
		local killerValue = player.Character and player.Character:FindFirstChild("KilledBy")
		local killer = nil
		if killerValue and killerValue:IsA("ObjectValue") and killerValue.Value then
			local killerPlayer = killerValue.Value
			if killerPlayer:IsA("Player") then
				killer = killerPlayer
			end
		end
		self:convert(player, killer)
	elseif role == "ZOMBIE" then
		task.delay(GameConfig.Round.ZombieRespawnSeconds, function()
			if self._roundActive and self._roles[player] == "ZOMBIE" and player.Parent ~= nil then
				self:_spawnAsZombie(player)
			end
		end)
	elseif role == "PATIENT_ZERO" then
		-- Unmasked and killed: PZ becomes a regular (visible) zombie — apex threat ends
		self._roles[player] = "ZOMBIE"
		self._patientZero = nil
		self._deps.remotes.fireAllClients("KillFeed", { text = "Patient Zero has been unmasked!" })
		task.delay(GameConfig.Round.ZombieRespawnSeconds, function()
			if self._roundActive and player.Parent ~= nil then
				self:_spawnAsZombie(player)
			end
		end)
	end
end

-- Lobby characters: CharacterAutoLoads is off (engine auto-respawn races the
-- zombie respawn flow — finding #2), so anyone outside a round is spawned and
-- re-spawned here.
function RoleService:spawnLobby(player: Player)
	if self._roundActive and self._roles[player] ~= nil then
		return
	end
	local character = self:_safeLoadCharacter(player)
	if character == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Died:Once(function()
			task.delay(GameConfig.Round.ZombieRespawnSeconds, function()
				if player.Parent ~= nil and not (self._roundActive and self._roles[player] ~= nil) then
					self:spawnLobby(player)
				end
			end)
		end)
	end
end

function RoleService:_infectedCount(): number
	local n = 0
	for _, role in self._roles do
		if role == "ZOMBIE" or role == "PATIENT_ZERO" then
			n += 1
		end
	end
	return n
end

function RoleService:start()
	Players.CharacterAutoLoads = false

	self._deps.remotes.onValidated("UseAbility", function(player)
		self:useAbility(player)
	end)

	Players.PlayerAdded:Connect(function(player)
		if self._roundActive then
			-- Mid-round joiners join the horde: keeps them playing immediately
			self._roles[player] = "ZOMBIE"
			self._deps.remotes.fireClient("RoleAssigned", player, { role = "ZOMBIE" })
			task.defer(function()
				self:_spawnAsZombie(player)
			end)
		else
			task.defer(function()
				self:spawnLobby(player)
			end)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local role = self._roles[player]
		self._roles[player] = nil
		self._abilityLastUse[player] = nil
		self:_unwatchCharacter(player)
		if not self._roundActive then
			return
		end
		if role == "PATIENT_ZERO" then
			self._patientZero = nil
			-- Hand the infection to a random zombie; if none exist, round can't continue
			local zombies = {}
			for p, r in self._roles do
				if r == "ZOMBIE" then
					table.insert(zombies, p)
				end
			end
			if #zombies > 0 then
				local heir = zombies[rng:NextInteger(1, #zombies)]
				self._roles[heir] = "PATIENT_ZERO"
				self._patientZero = heir
				self._deps.remotes.fireClient("RoleAssigned", heir, { role = "PATIENT_ZERO" })
			else
				self._deps.onPatientZeroGone()
			end
		elseif role == "SURVIVOR" then
			self._deps.onSurvivorCountChanged(self:survivorCount())
		elseif role == "ZOMBIE" and self:_infectedCount() == 0 then
			-- Every infected player left after PZ was unmasked: survivors win now
			-- instead of waiting out an empty timer (finding #4)
			self._deps.onPatientZeroGone()
		end
	end)
end

return RoleService
