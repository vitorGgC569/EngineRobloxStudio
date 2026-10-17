--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
Forge.require("0.2.0")

local Config = require(ReplicatedStorage.Shared.Config)
local Content = require(ReplicatedStorage.Shared.Content)
local Wire = require(ReplicatedStorage.Shared.Wire)
local World = require(script:WaitForChild("World"))
local Rules = require(script:WaitForChild("Rules"))

local Net = Forge.Net
local Save = Forge.Save
local Telemetry = Forge.Telemetry
local Monetization = Forge.Monetization
local Rng = Forge.Core.Rng
local Hatch = Forge.Loop.Hatch

Rng.seed(Config.seed)
Wire.install()
World.build()

Save.configure({
	store = Config.saveStore,
	version = 1,
	autosaveInterval = 60,
	template = {
		stardust = 0,
		lifetimeStardust = 0,
		lastSeen = 0,
		passiveRate = 0,
		joinCount = 0,
		specimens = {},
		collection = {},
		upgrades = { speed = 0, vault = 0, reactor = 0 },
	},
})
Save.start()

local dropRng = Rng.stream("meteor-rush.drops")
local meteorRandom = Random.new(Config.seed)
local meteorSerial = 0

local loop = Hatch.new({
	theme = {
		noun = "meteor core",
		verb = "decode",
		collection = "specimen index",
	},
	drops = Content.drops,
	tier2At = 75,
	funnel = "meteor-rush",
	pityThreshold = 9,
	minRarityForPity = 3,
})

local function profileFor(player: Player): any?
	local profile = Save.get(player)
	if type(profile) ~= "table" then return nil end
	profile.stardust = tonumber(profile.stardust) or 0
	profile.lifetimeStardust = tonumber(profile.lifetimeStardust) or 0
	profile.lastSeen = tonumber(profile.lastSeen) or 0
	profile.passiveRate = tonumber(profile.passiveRate) or 0
	profile.joinCount = math.max(0, math.floor(tonumber(profile.joinCount) or 0))
	profile.specimens = if type(profile.specimens) == "table" then profile.specimens else {}
	profile.collection = if type(profile.collection) == "table" then profile.collection else {}
	profile.upgrades = if type(profile.upgrades) == "table" then profile.upgrades else {}
	profile.upgrades.speed = math.max(0, math.floor(tonumber(profile.upgrades.speed) or 0))
	profile.upgrades.vault = math.max(0, math.floor(tonumber(profile.upgrades.vault) or 0))
	profile.upgrades.reactor = math.max(0, math.floor(tonumber(profile.upgrades.reactor) or 0))
	return profile
end

local function specimenBaseRate(profile: any): number
	local total = 0
	for _, entry in profile.specimens do
		total += Content.income(tostring(entry.id), tostring(entry.mutation or ""))
	end
	return total
end

local function reactorMultiplier(profile: any): number
	return Rules.reactorMultiplier(tonumber(profile.upgrades.reactor) or 0)
end

local function ownsDouble(player: Player): boolean
	return Config.monetization.doubleStardustPassId > 0
		and Monetization.owns(player, "doubleStardust")
end

local function ownsExtraVault(player: Player): boolean
	return Config.monetization.extraVaultPassId > 0
		and Monetization.owns(player, "extraVault")
end

local function incomeRate(player: Player, profile: any): number
	local base = specimenBaseRate(profile)
	local rate = base * reactorMultiplier(profile)
	if ownsDouble(player) then rate *= 2 end
	return rate
end

local function capacity(player: Player, profile: any): number
	return Rules.capacity(tonumber(profile.upgrades.vault) or 0, ownsExtraVault(player))
end

local function collectionKinds(profile: any): number
	local count = 0
	for _, amount in profile.collection do
		if tonumber(amount) and amount > 0 then count += 1 end
	end
	return count
end

local function hotPublish(player: Player, profile: any)
	local rate = incomeRate(player, profile)
	local saveStatus = Save.status(player)
	profile.passiveRate = rate
	player:SetAttribute("Stardust", math.floor(profile.stardust))
	player:SetAttribute("ProfileJoinCount", profile.joinCount)
	player:SetAttribute("SavePersistent", saveStatus.persistent == true)
	player:SetAttribute("SaveMemoryOnly", saveStatus.memoryOnly == true)
	player:SetAttribute("StardustPerSecond", rate)
	player:SetAttribute("Specimens", #profile.specimens)
	player:SetAttribute("VaultCapacity", capacity(player, profile))
	player:SetAttribute("CollectionKinds", collectionKinds(profile))
	player:SetAttribute("SpeedLevel", profile.upgrades.speed)
	player:SetAttribute("VaultLevel", profile.upgrades.vault)
	player:SetAttribute("ReactorLevel", profile.upgrades.reactor)
	player:SetAttribute("CarryingMeteor", player:GetAttribute("CarryingMeteor") == true)
	local stats = player:FindFirstChild("leaderstats")
	if not stats then
		stats = Instance.new("Folder")
		stats.Name = "leaderstats"
		stats.Parent = player
	end
	local value = stats:FindFirstChild("Stardust")
	if not value then
		value = Instance.new("IntValue")
		value.Name = "Stardust"
		value.Parent = stats
	end
	;(value :: IntValue).Value = math.floor(profile.stardust)
end

local function fullState(player: Player): any
	local profile = profileFor(player)
	if not profile then return nil end
	local specimens = {}
	for index, entry in profile.specimens do
		local specimen = Content.specimen(tostring(entry.id))
		if specimen then
			table.insert(specimens, {
				uid = tostring(entry.uid or index),
				id = specimen.id,
				name = specimen.name,
				rarity = specimen.rarity,
				rarityName = Content.rarity(specimen.rarity).name,
				mutation = tostring(entry.mutation or ""),
				income = Content.income(specimen.id, tostring(entry.mutation or "")),
			})
		end
	end
	return {
		stardust = math.floor(profile.stardust),
		rate = incomeRate(player, profile),
		capacity = capacity(player, profile),
		specimens = specimens,
		collection = profile.collection,
		upgrades = profile.upgrades,
		costs = {
			speed = Content.upgradeCost("speed", profile.upgrades.speed),
			vault = Content.upgradeCost("vault", profile.upgrades.vault),
			reactor = Content.upgradeCost("reactor", profile.upgrades.reactor),
		},
		carrying = player:GetAttribute("CarryingMeteor") == true,
	}
end

local function sync(player: Player)
	local profile = profileFor(player)
	if not profile then return end
	hotPublish(player, profile)
	Net.fire(player, "State", fullState(player))
	World.renderSpecimens(player, profile.specimens)
end

local function persist(player: Player)
	local profile = profileFor(player)
	if not profile then return end
	profile.lastSeen = os.time()
	profile.passiveRate = incomeRate(player, profile)
	pcall(function()
		Save.write(player)
	end)
end

local function notify(player: Player, text: string, kind: string?)
	Net.fire(player, "Notify", { text = text, kind = kind or "info" })
end

local function applyWalkSpeed(player: Player)
	local profile = profileFor(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (profile and humanoid) then return end
	humanoid.WalkSpeed = Rules.walkSpeed(profile.upgrades.speed)
end

local function clearCarry(player: Player)
	player:SetAttribute("CarryingMeteor", false)
	player:SetAttribute("CarriedMeteorType", "")
	player:SetAttribute("CarriedMeteorName", "")
	player:SetAttribute("CarriedMeteorRarity", 0)
	player:SetAttribute("CarriedMeteorMultiplier", 1)
	World.clearCarriedCore(player)
end

local function onCharacter(player: Player, character: Model)
	if character:GetAttribute("MeteorRushPrepared") == true then return end
	character:SetAttribute("MeteorRushPrepared", true)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	task.defer(function()
		applyWalkSpeed(player)
		task.wait(0.1)
		World.teleportHome(player)
	end)
	humanoid.Died:Connect(function()
		if player:GetAttribute("CarryingMeteor") == true then
			clearCarry(player)
			notify(player, "The meteor core destabilized when you were knocked out.", "warn")
		end
	end)
end

local function payOffline(player: Player, profile: any)
	if profile.lastSeen <= 0 then
		profile.lastSeen = os.time()
		return
	end
	local storedRate = math.max(0, tonumber(profile.passiveRate) or 0)
	local amount, paidSeconds = Rules.offlinePayout(storedRate, os.time() - profile.lastSeen)
	profile.lastSeen = os.time()
	if amount > 0 then
		profile.stardust += amount
		profile.lifetimeStardust += amount
		notify(player, ("Your lab generated %s Stardust while you were away."):format(amount), "good")
		Telemetry.event("meteor.offline", { seconds = paidSeconds, amount = amount })
	end
end

local function setupMonetization()
	local definitions = { products = {}, passes = {} }
	if Config.monetization.doubleStardustPassId > 0 then
		definitions.passes.doubleStardust = {
			passId = Config.monetization.doubleStardustPassId,
			label = "2x Stardust",
			onOwned = function(player)
				task.defer(sync, player)
			end,
		}
	end
	if Config.monetization.extraVaultPassId > 0 then
		definitions.passes.extraVault = {
			passId = Config.monetization.extraVaultPassId,
			label = "+4 Vault Slots",
			onOwned = function(player)
				task.defer(sync, player)
			end,
		}
	end
	if Config.monetization.stardustPackProductId > 0 then
		definitions.products.stardustPack = {
			productId = Config.monetization.stardustPackProductId,
			label = "1,500 Stardust",
			apply = function(profile)
				profile.stardust = (tonumber(profile.stardust) or 0) + 1500
				profile.lifetimeStardust = (tonumber(profile.lifetimeStardust) or 0) + 1500
				return true
			end,
		}
	end
	Monetization.defineMany(definitions)
	Monetization.start()
	Monetization.purchased:Connect(function(player)
		task.defer(sync, player)
	end)
end
setupMonetization()

Save.observe(function(player, profile)
	if type(profile) ~= "table" then return end
	profileFor(player)
	payOffline(player, profile)
	profile.joinCount = (tonumber(profile.joinCount) or 0) + 1
	local base = World.assign(player)
	if not base then
		notify(player, "No lab slot is available in this server.", "warn")
		return
	end
	clearCarry(player)
	sync(player)
	persist(player)
	if player.Character then task.spawn(onCharacter, player, player.Character) end
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
end)
for _, player in Players:GetPlayers() do
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
end

local function chooseMutation(meteorRarity: number): string
	local roll = dropRng:number(0, 1)
	local rarity = math.clamp(meteorRarity, 1, 6)
	local voidChance = 0.004 + math.max(0, rarity - 3) * 0.0025
	local radiantChance = 0.05 + (rarity - 1) * 0.012
	if roll < voidChance then return "void" end
	if roll < voidChance + radiantChance then return "radiant" end
	return ""
end

local function decode(player: Player, base: World.Base)
	if base.owner ~= player then
		notify(player, "That decoder belongs to another lab.", "warn")
		return
	end
	if player:GetAttribute("CarryingMeteor") ~= true then
		notify(player, "Bring a meteor core here first.", "warn")
		return
	end
	local profile = profileFor(player)
	if not profile then return end
	if #profile.specimens >= capacity(player, profile) then
		notify(player, "Your vault is full. Upgrade Vault Slots.", "warn")
		return
	end

	local subject = tostring(player.UserId)
	local drop = loop:open(subject, function()
		return dropRng:number(0, 1)
	end)
	local specimen = Content.specimen(drop.id)
	if not specimen then
		notify(player, "Decoder produced an unknown specimen.", "warn")
		return
	end

	local meteorRarity = tonumber(player:GetAttribute("CarriedMeteorRarity")) or 1
	local meteorType = tostring(player:GetAttribute("CarriedMeteorType") or "")
	local meteorName = tostring(player:GetAttribute("CarriedMeteorName") or "Meteor")
	local burstMultiplier = tonumber(player:GetAttribute("CarriedMeteorMultiplier")) or 1
	local mutation = chooseMutation(meteorRarity)
	local uid = ("%d-%d-%d"):format(player.UserId, os.time(), #profile.specimens + 1)
	table.insert(profile.specimens, {
		uid = uid,
		id = specimen.id,
		mutation = mutation,
	})
	profile.collection[specimen.id] = (tonumber(profile.collection[specimen.id]) or 0) + 1
	local burst = math.max(4, math.floor(5 * burstMultiplier))
	profile.stardust += burst
	profile.lifetimeStardust += burst
	loop:kept(subject)
	clearCarry(player)

	Telemetry.event("meteor.decoded", {
		id = specimen.id,
		rarity = specimen.rarity,
		mutation = mutation,
		meteorType = meteorType,
		meteorRarity = meteorRarity,
		meteorName = meteorName,
		burstMultiplier = burstMultiplier,
	})
	Net.fire(player, "Decoded", {
		id = specimen.id,
		name = specimen.name,
		rarity = specimen.rarity,
		rarityName = Content.rarity(specimen.rarity).name,
		color = Content.rarity(specimen.rarity).color,
		mutation = mutation,
		income = Content.income(specimen.id, mutation),
		burst = burst,
		meteorType = meteorType,
		meteorName = meteorName,
		meteorRarity = meteorRarity,
		meteorRarityName = Content.rarity(meteorRarity).name,
	})
	if specimen.rarity >= 5 or mutation ~= "" then
		Net.fireAll("Announce", {
			who = player.DisplayName,
			name = specimen.name,
			rarity = Content.rarity(specimen.rarity).name,
			mutation = mutation,
		})
	end
	sync(player)
	persist(player)
end

for _, base in World.bases do
	base.decoderPrompt.Triggered:Connect(function(player)
		decode(player, base)
	end)
end

local function liveMeteorCount(): number
	if not World.meteors then return 0 end
	return #World.meteors:GetChildren()
end

local function claimMeteor(player: Player, model: Model)
	if model:GetAttribute("Claimed") == true then return end
	if player:GetAttribute("CarryingMeteor") == true then
		notify(player, "Decode the core you are already carrying.", "warn")
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local core = model:FindFirstChild("Core")
	if not (root and root:IsA("BasePart") and core and core:IsA("BasePart")) then return end
	if (root.Position - core.Position).Magnitude > Config.captureRadius + 3 then
		return
	end

	local typeId = tostring(model:GetAttribute("MeteorType") or "duststone")
	local meteor = Content.meteor(typeId) or Content.meteors[1]
	model:SetAttribute("Claimed", true)
	player:SetAttribute("CarryingMeteor", true)
	player:SetAttribute("CarriedMeteorType", meteor.id)
	player:SetAttribute("CarriedMeteorName", meteor.name)
	player:SetAttribute("CarriedMeteorRarity", meteor.rarity)
	player:SetAttribute("CarriedMeteorMultiplier", meteor.burstMultiplier)
	World.attachCarriedCore(player, meteor)

	local rarity = Content.rarity(meteor.rarity)
	Net.fire(player, "MeteorClaimed", {
		typeId = meteor.id,
		name = meteor.name,
		rarity = meteor.rarity,
		rarityName = rarity.name,
		color = rarity.color,
		bonus = meteor.burstMultiplier,
	})
	Telemetry.event("meteor.claimed", {
		typeId = meteor.id,
		rarity = meteor.rarity,
		bonus = meteor.burstMultiplier,
	})
	model:Destroy()
	hotPublish(player, profileFor(player))
end

local function spawnMeteor(ignoreLimit: boolean?, luck: number?)
	if not World.meteors then return end
	if not ignoreLimit and liveMeteorCount() >= Config.maxLiveMeteors then return end
	meteorSerial += 1
	local meteor = Content.rollMeteor(meteorRandom, luck or 0)
	local position = World.randomMeteorPosition(meteorRandom)
	local model, prompt = World.spawnMeteor(tostring(meteorSerial), position, meteor)
	prompt.Triggered:Connect(function(player)
		claimMeteor(player, model)
	end)

	if meteor.rarity >= 4 then
		Net.fireAll("MeteorSpawned", {
			typeId = meteor.id,
			name = meteor.name,
			rarity = meteor.rarity,
			rarityName = Content.rarity(meteor.rarity).name,
			color = Content.rarity(meteor.rarity).color,
			position = { position.X, position.Y, position.Z },
		})
	end

	task.delay(Config.meteorLifetime + meteor.rarity * 4, function()
		if model.Parent and model:GetAttribute("Claimed") ~= true then
			model:Destroy()
		end
	end)
end

Net.on("state", function(player)
	return fullState(player)
end)

Net.on("collectionSeen", function(player)
	loop:sawCollection(tostring(player.UserId))
	return { ok = true }
end)

Net.on("buyUpgrade", function(player, payload)
	local profile = profileFor(player)
	if not profile then return { ok = false, reason = "still loading" } end
	local id = tostring((payload or {}).id or "")
	local spec = Content.upgrades[id]
	if not spec then return { ok = false, reason = "unknown upgrade" } end
	local level = tonumber(profile.upgrades[id]) or 0
	if level >= spec.max then return { ok = false, reason = "max level" } end
	local cost = Content.upgradeCost(id, level)
	if profile.stardust < cost then return { ok = false, reason = "not enough Stardust" } end

	profile.stardust -= cost
	profile.upgrades[id] = level + 1
	if id == "speed" then applyWalkSpeed(player) end
	if level == 0 then loop:reachedTierTwo(tostring(player.UserId)) end
	Telemetry.event("meteor.upgrade", { id = id, level = level + 1, cost = cost })
	sync(player)
	persist(player)
	return { ok = true, level = level + 1, cost = cost }
end)

Net.on("promptPurchase", function(player, payload)
	local id = tostring((payload or {}).id or "")
	local enabled = (
		(id == "doubleStardust" and Config.monetization.doubleStardustPassId > 0)
		or (id == "extraVault" and Config.monetization.extraVaultPassId > 0)
		or (id == "stardustPack" and Config.monetization.stardustPackProductId > 0)
	)
	if not enabled then
		return { ok = false, reason = "purchase becomes available after publishing" }
	end
	return { ok = Monetization.prompt(player, id) }
end)

Players.PlayerRemoving:Connect(function(player)
	persist(player)
	clearCarry(player)
	World.release(player)
end)

task.spawn(function()
	while true do
		task.wait(1)
		for _, player in Players:GetPlayers() do
			local profile = profileFor(player)
			if profile then
				profile.lastSeen = os.time()
				local rate = incomeRate(player, profile)
				if rate > 0 then
					profile.stardust += rate
					profile.lifetimeStardust += rate
				end
				hotPublish(player, profile)
			end
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(Config.meteorSpawnEvery)
		if #Players:GetPlayers() > 0 then
			spawnMeteor(false)
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(math.max(10, Config.showerEvery - 10))
		if #Players:GetPlayers() > 0 then
			Net.fireAll("Shower", { seconds = 10 })
			task.wait(10)
			Net.fireAll("Shower", { seconds = 0 })
			for _ = 1, Config.showerCount do
				spawnMeteor(true, 1.4)
			end
			Telemetry.event("meteor.shower", { count = Config.showerCount })
		else
			task.wait(10)
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(15)
		for _, player in Players:GetPlayers() do
			local findings = loop:check(tostring(player.UserId))
			if #findings > 0 then
				player:SetAttribute("LoopFinding", findings[1].rule)
			else
				player:SetAttribute("LoopFinding", "")
			end
		end
	end
end)

if Config.selfTest then
	task.defer(function()
		local suite = script:FindFirstChild("tests")
		if suite then
			local report = Forge.Testing.runAndPublish(suite, nil, "meteor-rush")
			print(("[Meteor Rush] self-test: %d passed, %d failed, %d hung"):format(
				report.passed or 0, report.failed or 0, report.timedOut or 0))
		end
	end)
end

print("[Meteor Rush] server ready", RunService:IsStudio() and "(Studio)" or "")
