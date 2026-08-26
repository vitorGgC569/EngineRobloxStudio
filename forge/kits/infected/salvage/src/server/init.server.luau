--!strict
-- Server bootstrap. Order matters: remotes first (clients WaitForChild on the folder),
-- then services, wired together here so each service stays decoupled.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local Remotes = require(Shared.Remotes)

local RoundService = require(script.Services.RoundService)
local RoleService = require(script.Services.RoleService)
local CombatService = require(script.Services.CombatService)
local AntiCheatService = require(script.Services.AntiCheatService)
local MapService = require(script.Services.MapService)
local DataService = require(script.Services.DataService)
local EconomyService = require(script.Services.EconomyService)
local MonetizationService = require(script.Services.MonetizationService)
local EndgameService = require(script.Services.EndgameService)
local BotService = require(script.Services.BotService)
local RetentionService = require(script.Services.RetentionService)
local EmoteService = require(script.Services.EmoteService)
local LeaderboardService = require(script.Services.LeaderboardService)
local AnalyticsService = require(script.Services.AnalyticsService)
local LiveConfigService = require(script.Services.LiveConfigService)

-- Fast timers in Studio so a full round loop plays out in under a minute of testing.
if game:GetService("RunService"):IsStudio() then
	GameConfig.Round.IntermissionSeconds = 8
	GameConfig.Round.BaseRoundSeconds = 40
	GameConfig.Round.MaxRoundSeconds = 90
	GameConfig.Round.RevealSeconds = 6
	GameConfig.Round.MinPlayersToStart = 2
	-- Solo play-test (run-in-roblox headless verification): let a 1-player round run
	task.delay(5, function()
		if #Players:GetPlayers() <= 1 then
			GameConfig.Round.MinPlayersToStart = 1
		end
	end)
end

local remotes = Remotes.server()

-- Forward declarations: service closures below reference these before assignment
local roundService
local roleService
local endgameService
local botService
local retentionService
local antiCheatService

-- Total survivor count = human survivors + bot survivors. Both RoleService (humans)
-- and BotService (bots) call this whenever their counts change so the round machine
-- ends the round only when every survivor — human or bot — is converted.
local function refreshCounts()
	local total = roleService:survivorCount() + (botService and botService:survivorCount() or 0)
	roundService:setSurvivorCount(total)
	endgameService:onSurvivorCountChanged(total)
end

local rng = Random.new()

local mapService = MapService.new({ remotes = remotes })
local dataService = DataService.new({
	remotes = remotes,
	onProfileLoaded = function(player)
		if retentionService then
			retentionService:onPlayerReady(player)
		end
	end,
})
local economyService = EconomyService.new({ remotes = remotes, dataService = dataService })
local monetizationService =
	MonetizationService.new({ dataService = dataService, economyService = economyService })
retentionService = RetentionService.new({
	remotes = remotes,
	dataService = dataService,
	isPremium = function(player)
		return economyService:ownsGamePass(player, GameConfig.Products.GamePasses.VIP)
	end,
})
local leaderboardService = LeaderboardService.new({ remotes = remotes, dataService = dataService })
local analyticsService = AnalyticsService.new()
local liveConfigService = LiveConfigService.new()

-- Round modifiers: roll one (weighted) at round start, apply via global levers, broadcast
-- for the client banner + lighting, and clear at intermission.
local function pickModifier()
	local mods = GameConfig.RoundModifiers
	local total = 0
	for _, m in mods do
		total += m.weight
	end
	local pick = rng:NextNumber(0, total)
	for _, m in mods do
		pick -= m.weight
		if pick <= 0 then
			return m
		end
	end
	return mods[1]
end

local function applyModifier(mod)
	workspace.Gravity = mod.gravity or GameConfig.DefaultGravity
	economyService:setRoundMultiplier(mod.coinMult or 1)
	remotes.fireAllClients("RoundModifier", {
		active = true,
		id = mod.id,
		name = mod.name,
		desc = mod.desc,
		blackout = mod.blackout == true,
	})
end

local function clearModifier()
	workspace.Gravity = GameConfig.DefaultGravity
	economyService:setRoundMultiplier(1)
	remotes.fireAllClients("RoundModifier", { active = false })
end

roleService = RoleService.new({
	remotes = remotes,
	getSurvivorSpawn = function()
		return mapService:randomSurvivorSpawn()
	end,
	getZombieSpawn = function(survivorRoots)
		return mapService:zombieSpawnNearAction(survivorRoots)
	end,
	getEquippedGunSkin = function(player: Player)
		local data = dataService:get(player)
		return data and data.equipped and data.equipped.Gun or nil
	end,
	-- Spawn/respawn CFrame writes must not trip movement anti-cheat (was kicking real players).
	noteTrustedTeleport = function(player: Player)
		if antiCheatService then
			antiCheatService:noteTrustedTeleport(player)
		end
	end,
	onConversion = function(victim: Player, killer: Player?)
		roundService:recordConversion()
		economyService:onConversion(killer)
		if killer and retentionService then
			retentionService:recordEvent(killer, "convert", 1)
		end
		analyticsService:onConversion(killer)
		local victimRoot = victim.Character and victim.Character:FindFirstChild("HumanoidRootPart")
		remotes.fireAllClients("ConversionAlert", {
			victimName = victim.DisplayName,
			killerName = killer and killer.DisplayName or nil,
			position = (victimRoot and victimRoot:IsA("BasePart")) and victimRoot.Position or nil,
		})
	end,
	onSurvivorCountChanged = function(_count: number)
		refreshCounts()
	end,
	onPatientZeroGone = function()
		-- PZ left before creating any zombies: survivors win by default
		roundService:forceEnd("SURVIVORS")
	end,
})

endgameService = EndgameService.new({
	remotes = remotes,
	roleService = roleService,
	isRoundActive = function()
		return roundService ~= nil and roundService:getState() == "ACTIVE"
	end,
})

botService = BotService.new({
	remotes = remotes,
	getSurvivorSpawn = function()
		return mapService:randomSurvivorSpawn()
	end,
	getZombieSpawn = function(survivorRoots)
		return mapService:zombieSpawnNearAction(survivorRoots)
	end,
	getHumanSurvivors = function()
		return roleService:survivors()
	end,
	getInfectedPlayerRoots = function()
		return roleService:zombiePlayerRoots()
	end,
	convertHuman = function(victim: Player)
		roleService:convert(victim, nil)
	end,
	onBotKilledByHuman = function(killer: Player)
		economyService:onZombieKilled(killer)
		retentionService:recordEvent(killer, "kill", 1)
	end,
	onBotConvertedByHuman = function(killer: Player)
		economyService:onConversion(killer)
		retentionService:recordEvent(killer, "convert", 1)
	end,
	onConversionOccurred = function()
		roundService:recordConversion()
	end,
	onCountsChanged = function()
		refreshCounts()
	end,
	-- Lets bot bullets hurt a human zombie. Without it bots could only damage other bots.
	damageInfectedPlayer = function(character: Model, amount: number)
		local victim = Players:GetPlayerFromCharacter(character)
		if victim == nil then
			return
		end
		-- PATIENT ZERO GUARD: bots must never damage the hidden PZ, or the reaction
		-- (and the kill feed) would expose who they are.
		if roleService:getRole(victim) ~= "ZOMBIE" then
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 and character:FindFirstChildOfClass("ForceField") == nil then
			humanoid:TakeDamage(amount)
		end
	end,
	getPatrolPoint = function()
		return mapService:randomPatrolPoint()
	end,
})

local combatService = CombatService.new({
	remotes = remotes,
	roleService = roleService,
	botService = botService,
	isRoundActive = function()
		return roundService:getState() == "ACTIVE"
	end,
	onZombieKilled = function(killer: Player, _victim: Player)
		economyService:onZombieKilled(killer)
		retentionService:recordEvent(killer, "kill", 1)
	end,
	isLastStand = function(player: Player)
		return endgameService:isLastStand(player)
	end,
	getPrimary = function(player: Player)
		local data = dataService:get(player)
		return data and data.loadout.primary or "AssaultRifle"
	end,
})

antiCheatService = AntiCheatService.new({
	remotes = remotes,
	combatService = combatService,
})

roundService = RoundService.new({
	remotes = remotes,
	getExtraCount = function()
		return botService:plannedCount(#Players:GetPlayers())
	end,
	onRoundStart = function(playersInRound)
		economyService:resetRound()
		combatService:resetRound()
		endgameService:resetRound()
		mapService:loadVotedMap()
		local roundMod = pickModifier()
		applyModifier(roundMod)
		analyticsService:onRoundStart(#playersInRound, roundMod.id)

		-- Decide whether the Patient Zero is a human or a bot. With one human and
		-- several bots, the human is usually a survivor being hunted (more fun solo),
		-- and occasionally the hidden infected.
		local humanCount = #playersInRound
		local botCount = botService:plannedCount(humanCount)
		local totalParticipants = math.max(1, humanCount + botCount)
		local pzIsHuman = humanCount > 0 and rng:NextInteger(1, totalParticipants) <= humanCount

		roleService:assignRoles(playersInRound, { allSurvivors = not pzIsHuman })
		-- assignRoles can yield on LoadCharacter and used to push a humans-only survivor
		-- count mid-setup (0 when the sole human is PZ) which ended the round as INFECTED
		-- before bots existed. Abort cleanly if something else already ended us.
		if roundService:getState() ~= "ACTIVE" then
			return
		end
		botService:spawnForRound(botCount, { botIsPZ = not pzIsHuman })
		if not pzIsHuman then
			local pzName = botService:patientZeroName()
			if pzName then
				roleService:setOriginalPZName(pzName)
			end
		end
		-- First authoritative human+bot count of the round. Must run after bots spawn.
		refreshCounts()
	end,
	onRoundEnd = function(winner)
		local originalPZ = roleService:getOriginalPatientZero()
		local survivors = roleService:survivors()
		local survivorNames = {}
		for _, survivor in survivors do
			table.insert(survivorNames, survivor.DisplayName)
		end
		for _, botName in botService:survivorNames() do
			table.insert(survivorNames, botName)
		end
		economyService:onRoundEnd(winner, survivors, Players:GetPlayers())
		for _, survivor in survivors do
			retentionService:recordEvent(survivor, "survive", 1)
			if winner == "SURVIVORS" then
				retentionService:recordEvent(survivor, "win", 1)
			end
		end
		for _, roundPlayer in Players:GetPlayers() do
			retentionService:recordEvent(roundPlayer, "playRounds", 1)
		end
		local earnings = {}
		local mvpName, mvpCoins = nil, -1
		for player, coins in economyService:roundEarnings() do
			earnings[tostring(player.UserId)] = coins
			if coins > mvpCoins then
				mvpName, mvpCoins = player.DisplayName, coins
			end
		end
		remotes.fireAllClients("RevealScreen", {
			winner = winner,
			patientZeroName = originalPZ and originalPZ.name or "?",
			survivors = survivorNames,
			earnings = earnings,
			mvpName = mvpName,
			mvpCoins = mvpCoins >= 0 and mvpCoins or nil,
		})
		roleService:endRound()
		botService:clear()
		leaderboardService:onRoundEnd(Players:GetPlayers())
		analyticsService:onRoundEnd(winner, #survivorNames)
	end,
	onIntermission = function()
		-- Reset any round modifier (gravity/lighting/multiplier) back to normal.
		clearModifier()
		-- Keep a map loaded as the lobby so players never stand on an empty baseplate.
		mapService:loadLobby()
		mapService:openVote()
	end,
})

dataService:start()
roleService:start()
roundService:start()
combatService:start()
antiCheatService:start()
mapService:start()
economyService:start()
monetizationService:start()
endgameService:start()
botService:start()
retentionService:start()

local emoteService = EmoteService.new({ remotes = remotes, roleService = roleService })
emoteService:start()
leaderboardService:start()
liveConfigService:start()

-- Load a lobby map immediately so the very first pre-round moment isn't an empty
-- baseplate.
mapService:loadLobby()

-- Studio-only smoke test: exercises the whole round loop with fast timers and
-- scripted deaths so a local multi-client playtest verifies itself in the Output.
if game:GetService("RunService"):IsStudio() then
	local SmokeTest = require(script.StudioSmokeTest)
	SmokeTest.run(roundService, roleService)
end

print("[INFECTED] Server booted")
