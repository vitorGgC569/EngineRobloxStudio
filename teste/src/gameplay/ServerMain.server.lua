--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

print("==================================================")
print("[ServerMain] BOOTING ZOMBIE SURVIVAL 3D...")
print("==================================================")

-- 1. Setup Network Channels in ReplicatedStorage FIRST
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end

local NetworkProtocol = require(ReplicatedStorage.Shared.NetworkProtocol)
local WeaponCatalog = require(ReplicatedStorage.Shared.WeaponCatalog)
local SkinCatalog = require(ReplicatedStorage.Shared.SkinCatalog)
local ZombieCatalog = require(ReplicatedStorage.Shared.ZombieCatalog)
local EconomyCatalog = require(ReplicatedStorage.Shared.EconomyCatalog)

local remoteEvents: { [string]: RemoteEvent } = {}
local eventNames = {
	NetworkProtocol.Events.FIRE_WEAPON,
	NetworkProtocol.Events.RELOAD_WEAPON,
	NetworkProtocol.Events.EQUIP_WEAPON,
	NetworkProtocol.Events.EQUIP_SKIN,
	NetworkProtocol.Events.BULLET_TRACER,
	NetworkProtocol.Events.DAMAGE_INDICATOR,
	NetworkProtocol.Events.ZOMBIE_HIT,
	NetworkProtocol.Events.WAVE_STATE_CHANGED,
	NetworkProtocol.Events.ZOMBIE_SPAWNED,
	NetworkProtocol.Events.ZOMBIE_DIED,
	NetworkProtocol.Events.BUY_WEAPON,
	NetworkProtocol.Events.BUY_SKIN,
	NetworkProtocol.Events.BUY_SUPPLY,
	NetworkProtocol.Events.PURCHASE_UPGRADE,
	NetworkProtocol.Events.SYNC_PLAYER_DATA,
	NetworkProtocol.Events.BUILD_BARRICADE,
	NetworkProtocol.Events.REPAIR_BARRICADE,
	NetworkProtocol.Events.BARRICADE_DAMAGED,
	NetworkProtocol.Events.ANNOUNCE_EVENT,
}

for _, name in ipairs(eventNames) do
	local event = remotesFolder:FindFirstChild(name) :: RemoteEvent?
	if not event then
		event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = remotesFolder
	end
	remoteEvents[name] = event
end
print("[ServerMain] Remote channels ready.")

-- 2. Build 3D World & Map Environment
local OutpostWorldBuilder = require(ServerScriptService.World.OutpostWorldBuilder)
local mapData = OutpostWorldBuilder.build()

-- 3. Initialize Services
local CombatService = require(script.Parent.Services.CombatService)
local ZombieAiService = require(script.Parent.Services.ZombieAiService)
local WaveService = require(script.Parent.Services.WaveService)
local ShopService = require(script.Parent.Services.ShopService)
local BarricadeService = require(script.Parent.Services.BarricadeService)
local PersistenceService = require(script.Parent.Services.PersistenceService)
local LeaderboardService = require(script.Parent.Services.LeaderboardService)

local persistenceService = PersistenceService.new("ZombieSurvival_v1")
local combatService = CombatService.new()
local zombieAiService = ZombieAiService.new()
local waveService = WaveService.new(zombieAiService, mapData.spawnPoints)
local shopService = ShopService.new(persistenceService)
local barricadeService = BarricadeService.new()
local leaderboardService = LeaderboardService.new()

for _, bar in ipairs(mapData.barricades) do
	barricadeService:register(bar)
end
print("[ServerMain] All 7 core services initialized.")

-- 4. Player Join Lifecycle
local function onPlayerAdded(player: Player)
	print("[ServerMain] Player Joined:", player.Name)
	local data = persistenceService:load(player)
	leaderboardService:setupPlayer(player, data)

	player.CharacterAdded:Connect(function(character)
		local hum = character:WaitForChild("Humanoid") :: Humanoid
		hum.MaxHealth = 100
		hum.Health = 100

		if data.armor and data.armor > 0 then
			hum.MaxHealth = 100 + data.armor
			hum.Health = hum.MaxHealth
		end

		task.delay(0.1, function()
			remoteEvents[NetworkProtocol.Events.SYNC_PLAYER_DATA]:FireClient(player, data)
		end)
	end)

	remoteEvents[NetworkProtocol.Events.SYNC_PLAYER_DATA]:FireClient(player, data)
end

local function onPlayerRemoving(player: Player)
	local data = persistenceService:get(player)
	if data then
		persistenceService:save(player, data)
	end
	persistenceService:clear(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

-- 5. Weapon Firing & Combat
remoteEvents[NetworkProtocol.Events.FIRE_WEAPON].OnServerEvent:Connect(function(player, weaponId, origin, direction, clientTarget)
	local data = persistenceService:get(player)
	if not data then return end

	local weaponDef = WeaponCatalog.get(weaponId)
	if not weaponDef then return end

	local cat = weaponDef.category
	if cat ~= "Melee" then
		local currentAmmo = data.ammo[cat] or 0
		if currentAmmo <= 0 then return end
		data.ammo[cat] = currentAmmo - 1
	end

	if cat ~= "Melee" then
		zombieAiService:alertNearbyZombies(origin, 150)
	end

	local hitResult = combatService:processShot(player, weaponId, origin, direction, clientTarget)
	remoteEvents[NetworkProtocol.Events.BULLET_TRACER]:FireAllClients(origin, hitResult.hitPosition, weaponDef.id, data.equippedSkin)

	if hitResult.hit and hitResult.damage > 0 then
		remoteEvents[NetworkProtocol.Events.DAMAGE_INDICATOR]:FireClient(player, hitResult.hitPosition, hitResult.damage, hitResult.isHeadshot)

		if hitResult.isKill and hitResult.target then
			local zType = hitResult.target:GetAttribute("ZombieType") or "walker"
			local zDef = ZombieCatalog.get(zType) or ZombieCatalog.Zombies.walker

			local scrapReward = zDef.scrapReward
			local xpReward = zDef.xpReward

			data.scraps += scrapReward
			data.xp += xpReward
			data.totalKills += 1

			leaderboardService:updateStats(player, nil, data.totalKills, data.scraps)
			remoteEvents[NetworkProtocol.Events.SYNC_PLAYER_DATA]:FireClient(player, data)
			remoteEvents[NetworkProtocol.Events.ZOMBIE_DIED]:FireAllClients(hitResult.target, zType)
		end
	end
end)

-- 6. Shop & Upgrade Actions
remoteEvents[NetworkProtocol.Events.BUY_WEAPON].OnServerEvent:Connect(function(player, weaponId)
	local ok, _ = shopService:buyWeapon(player, weaponId)
	if ok then
		local data = persistenceService:get(player)
		remoteEvents[NetworkProtocol.Events.SYNC_PLAYER_DATA]:FireClient(player, data)
	end
end)

remoteEvents[NetworkProtocol.Events.BUY_SKIN].OnServerEvent:Connect(function(player, skinId)
	local ok, _ = shopService:buySkin(player, skinId)
	if ok then
		local data = persistenceService:get(player)
		remoteEvents[NetworkProtocol.Events.SYNC_PLAYER_DATA]:FireClient(player, data)
	end
end)

remoteEvents[NetworkProtocol.Events.BUY_SUPPLY].OnServerEvent:Connect(function(player, supplyId)
	local ok, _ = shopService:buySupply(player, supplyId)
	if ok then
		local data = persistenceService:get(player)
		remoteEvents[NetworkProtocol.Events.SYNC_PLAYER_DATA]:FireClient(player, data)
	end
end)

remoteEvents[NetworkProtocol.Events.EQUIP_WEAPON].OnServerEvent:Connect(function(player, weaponId)
	local data = persistenceService:get(player)
	if not data then return end
	if table.find(data.unlockedWeapons, weaponId) then
		data.equippedWeapon = weaponId
		remoteEvents[NetworkProtocol.Events.SYNC_PLAYER_DATA]:FireClient(player, data)
	end
end)

remoteEvents[NetworkProtocol.Events.EQUIP_SKIN].OnServerEvent:Connect(function(player, skinId)
	local data = persistenceService:get(player)
	if not data then return end
	if table.find(data.unlockedSkins, skinId) then
		data.equippedSkin = skinId
		remoteEvents[NetworkProtocol.Events.SYNC_PLAYER_DATA]:FireClient(player, data)
	end
end)

-- 7. Wave Progression Callbacks
waveService:onWaveStarted(function(wave)
	remoteEvents[NetworkProtocol.Events.WAVE_STATE_CHANGED]:FireAllClients("Active", wave)
	remoteEvents[NetworkProtocol.Events.ANNOUNCE_EVENT]:FireAllClients("WAVE " .. wave .. " STARTING", Color3.fromRGB(255, 60, 40))
end)

waveService:onWaveCompleted(function(wave)
	local bonusScraps = 50 + (wave * 25)
	for _, player in ipairs(Players:GetPlayers()) do
		local data = persistenceService:get(player)
		if data then
			data.scraps += bonusScraps
			data.highestWave = math.max(data.highestWave, wave)
			leaderboardService:updateStats(player, data.highestWave, nil, data.scraps)
			remoteEvents[NetworkProtocol.Events.SYNC_PLAYER_DATA]:FireClient(player, data)
		end
	end
	remoteEvents[NetworkProtocol.Events.WAVE_STATE_CHANGED]:FireAllClients("Intermission", wave)
	remoteEvents[NetworkProtocol.Events.ANNOUNCE_EVENT]:FireAllClients("WAVE " .. wave .. " CLEARED! +" .. bonusScraps .. " SCRAPS", Color3.fromRGB(80, 240, 120))
end)

-- Start Wave loop with 8s warmup
waveService:startIntermission(8.0)

-- 8. Master Server Loop
RunService.Heartbeat:Connect(function(deltaTime)
	zombieAiService:update(deltaTime)
	waveService:update(deltaTime)
end)

print("[ServerMain] SERVER ONLINE & READY!")
