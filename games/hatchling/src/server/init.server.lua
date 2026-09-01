--!strict
--[[
	hatchling — server bootstrap.

	The loop, in one place: run into a crate, spend the coins on an egg, hatch
	a pet, put the best ones out, pay a toll, and do it all again somewhere the
	crates are worth more.

	What the client is never trusted with
	-------------------------------------

	Every number is decided here from state the server owns. A remote carries a
	crate name, an egg tier or a pet id -- never a value, never a rarity, never
	an elapsed time. In a game whose whole economy is a drop table, a client
	that could name its own drop would be the entire game.

	Two seams, and they are different on purpose
	--------------------------------------------

	Crates are *touched*, so the first report comes from the client and the
	server verifies the character was actually near it. Eggs are *prompted*, so
	the server sees the trigger itself and no client claim is involved at all.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
Forge.require("0.2.0")

local Config = require(ReplicatedStorage.Shared.Config)
local Theme = require(ReplicatedStorage.Shared.Theme)
local Wire = require(ReplicatedStorage.Shared.Wire)

local systems = ServerScriptService.Server.systems
local Sim = require(systems.Sim)
local World = require(systems.World)

local Net = Forge.Net
local Save = Forge.Save
local Debug = Forge.Debug
local Rng = Forge.Core.Rng

local startedAt = os.clock()
Rng.seed(Config.seed)

--: Remotes before any handler. `Net.define` creates the instances; a handler
--: registered first attaches to nothing and the client's call hangs until it
--: times out, which looks exactly like a broken button.
Wire.install()

--[[
	The theme is checked at boot, and the boot fails loudly if it is short.

	This game exists to be reskinned. A theme naming four rarity tiers when the
	machine has seven produces a game whose rarest creature has no name, and the
	only way to discover that by playing is to hatch one -- which, by
	construction, almost never happens.
]]
do
	local ok, why = Theme.check(Sim.TIERS, Sim.EGG_TIERS, Sim.ZONES)
	if not ok then
		error("[hatchling] " .. tostring(why), 0)
	end
end

Save.configure({
	store = "HatchlingSaves",
	template = { save = false },
	autosaveInterval = 90,
})
Save.start()

--: The ground, before anybody can stand on it. A player joins faster than a
--: profile loads, and a world built inside `arrive` is a world they fall
--: through while waiting for it.
World.build()

local states: { [Player]: Sim.State } = {}
local drops = Rng.stream("hatchling.drops")

--: Per-crate cooldown, server-side. The remote's rate limit caps traffic; this
--: decides how fast a crate can actually pay, and it is the one a macro cannot
--: argue with.
local CRATE_COOLDOWN = 1.6
local REACH = 26
local cooling: { [BasePart]: number } = {}

-- ================================ publishing ================================
local function publish(player: Player)
	local state = states[player]
	if not state then
		return
	end
	player:SetAttribute("coins", state.coins)
	player:SetAttribute("multiplier", Sim.multiplier(state))
	player:SetAttribute("zone", state.zone)
	player:SetAttribute("unlocked", state.unlocked)
	player:SetAttribute("pets", Sim.owned(state))
	player:SetAttribute("slots", state.slots)
	player:SetAttribute("collected", Sim.collected(state))
	player:SetAttribute("roster", #Theme.roster())
	player:SetAttribute("shards", state.shards)
	player:SetAttribute("rebirths", state.rebirths)
end

local function persist(player: Player)
	local state = states[player]
	local profile = Save.get(player)
	if not state or type(profile) ~= "table" then
		return
	end
	state.lastSeen = os.time()
	profile.save = state
	pcall(function()
		Save.write(player)
	end)
end

local function tell(player: Player, kind: string, text: string)
	Net.fire(player, "notice", { kind = kind, text = text })
end

--[[
	One place where an action lands.

	Republish and persist together, always. The previous game in this project
	grew four separate action handlers before anybody noticed one of them had
	stopped saving.
]]
local function apply(player: Player, ok: boolean, detail: any, said: string?): any
	if not ok then
		tell(player, "refused", tostring(detail))
		return { ok = false, reason = tostring(detail) }
	end
	publish(player)
	persist(player)
	if said then
		tell(player, "good", said)
	end
	return { ok = true, detail = detail }
end

--[[
	Which creature a hatch produces, once the machine has chosen a tier.

	The machine decides *how rare*; the theme decides *what*. Splitting it here
	is the only reason a reskin cannot move the drop rates: `Sim.hatch` never
	sees a name and this never sees a weight.
]]
local function pickCreature(tier: number): string
	local list = Theme.pets[math.clamp(tier, 1, #Theme.pets)]
	return list[drops:int(1, #list)].id
end

-- ================================== crates ==================================
Net.on("smash", function(player: Player, payload: any)
	local state = states[player]
	if not state then
		return { ok = false, reason = "still loading" }
	end
	local zone = World.zone(state.zone)
	if not zone then
		return { ok = false, reason = "nowhere to break anything" }
	end
	local crate = zone.folder:FindFirstChild(tostring((payload or {}).crate), true)
	if not (crate and crate:IsA("BasePart") and crate.Name == "Crate") then
		return { ok = false, reason = "no such crate" }
	end

	--: Reach, checked against the character rather than believed. This is the
	--: whole security model for the touch seam.
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart"))
			or (root.Position - crate.Position).Magnitude > REACH then
		return { ok = false, reason = "too far" }
	end
	local now = os.clock()
	if now < (cooling[crate] or 0) then
		return { ok = false, reason = "still reforming" }
	end
	cooling[crate] = now + CRATE_COOLDOWN

	local _, detail = Sim.breakCrate(state)
	--: Gone and back in the same place, rather than respawning elsewhere, so a
	--: player learns a route through the zone instead of chasing.
	crate.Transparency = 1
	crate.CanCollide = false
	task.delay(CRATE_COOLDOWN, function()
		if crate.Parent then
			crate.Transparency = 0
		end
	end)
	Net.fire(player, "smashed", {
		crate = crate.Name, coins = detail.coins, at = crate.Position,
		multiplier = detail.multiplier,
	})
	publish(player)
	return { ok = true, detail = detail }
end)

-- =================================== eggs ===================================
local function hatchFor(player: Player, egg: number): any
	local state = states[player]
	if not state then
		return { ok = false, reason = "still loading" }
	end
	local ok, detail = Sim.hatch(state, egg, pickCreature,
		drops:number(0, 1), drops:number(0, 1))
	if not ok then
		return apply(player, false, detail)
	end

	local pet = Theme.pet(detail.id)
	local rarity = Sim.rarity(detail.tier)
	Net.fire(player, "hatched", {
		uid = detail.uid, id = detail.id,
		name = if pet then pet.name else detail.id,
		tier = detail.tier, rarity = rarity.name, power = rarity.power,
		shiny = detail.shiny, isNew = detail.isNew, egg = egg,
	})

	--[[
		Everybody hears about a good one.

		The cheapest retention mechanic this genre has: seeing somebody else
		pull a Mythic is what tells a new player the ladder goes that far.
		Thresholded, or it is spam.
	]]
	if detail.tier >= Sim.TIERS - 1 or detail.shiny then
		Net.fireAll("announce", {
			who = player.DisplayName,
			name = if pet then pet.name else detail.id,
			rarity = rarity.name, tier = detail.tier, shiny = detail.shiny,
		})
	end
	return apply(player, true, detail, nil)
end

Net.on("hatch", function(player: Player, payload: any)
	return hatchFor(player, math.floor(tonumber((payload or {}).egg) or 0))
end)

-- =================================== bench ==================================
local benchActions: { [string]: (Sim.State, any) -> (boolean, any) } = {
	equip = function(state, payload)
		return Sim.equip(state, tostring(payload.uid))
	end,
	unequip = function(state, payload)
		return Sim.unequip(state, tostring(payload.uid))
	end,
	release = function(state, payload)
		return Sim.release(state, tostring(payload.uid))
	end,
	equipBest = function(state)
		return Sim.equipBest(state)
	end,
	buySlot = function(state)
		return Sim.buySlot(state)
	end,
	rebirth = function(state)
		return Sim.rebirth(state)
	end,
}
for name, rule in benchActions do
	Net.on(name, function(player: Player, payload: any)
		local state = states[player]
		if not state then
			return { ok = false, reason = "still loading" }
		end
		local ok, detail = rule(state, payload or {})
		return apply(player, ok, detail, nil)
	end)
end

-- =================================== zones ==================================
local function moveTo(player: Player, zone: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.CFrame = World.arrival(zone)
	end
end

Net.on("unlockZone", function(player: Player)
	local state = states[player]
	if not state then
		return { ok = false, reason = "still loading" }
	end
	local ok, detail = Sim.unlockZone(state)
	if ok then
		moveTo(player, detail.zone)
	end
	return apply(player, ok, detail,
		if ok then "Welcome to " .. Theme.zones[detail.zone].name else nil)
end)

Net.on("travel", function(player: Player, payload: any)
	local state = states[player]
	if not state then
		return { ok = false, reason = "still loading" }
	end
	local ok, detail = Sim.travel(state, math.floor(tonumber((payload or {}).zone) or 0))
	if ok then
		moveTo(player, detail.zone)
	end
	return apply(player, ok, detail, nil)
end)

-- ================================ the picture ===============================
Net.on("state", function(player: Player)
	local state = states[player]
	if not state then
		return nil
	end
	local pets = {}
	for uid, pet in state.pets do
		local entry = Theme.pet(pet.id)
		pets[uid] = {
			id = pet.id, tier = pet.tier, shiny = pet.shiny,
			name = if entry then entry.name else pet.id,
			rarity = Sim.rarity(pet.tier).name, power = Sim.power(pet),
		}
	end
	local book = {}
	for _, entry in Theme.roster() do
		book[entry.id] = {
			name = entry.name, tier = entry.tier,
			rarity = Sim.rarity(entry.tier).name,
			seen = state.seen[entry.id] == true,
		}
	end
	local eggs = {}
	for tier = 1, Sim.EGG_TIERS do
		eggs[tier] = {
			name = Theme.eggs[tier].name, cost = Sim.eggCost(tier),
			--: "Ninety more crates" is the most useful sentence this genre can
			--: put on a screen, and almost nobody does.
			crates = Sim.cratesTo(state, Sim.eggCost(tier)),
		}
	end
	local nextZone = state.unlocked + 1
	return {
		coins = state.coins, shards = state.shards, earned = state.earned,
		zone = state.zone, unlocked = state.unlocked,
		zoneName = Theme.zones[state.zone].name,
		multiplier = Sim.multiplier(state),
		slots = state.slots,
		slotCost = if state.slots < Sim.MAX_SLOTS
			then Sim.slotCost(state.slots) else nil,
		equipped = state.equipped, pets = pets, book = book, eggs = eggs,
		collected = Sim.collected(state), roster = #Theme.roster(),
		rebirths = state.rebirths, rebirthCost = Sim.rebirthCost(state.rebirths),
		nextZone = if nextZone <= Sim.ZONES then {
			zone = nextZone, name = Theme.zones[nextZone].name,
			toll = Sim.zoneToll(nextZone),
			crates = Sim.cratesTo(state, Sim.zoneToll(nextZone)),
		} else nil,
	}
end)

-- ================================== prompts =================================
--: Egg stands and toll gates are server-owned prompts, so no client claim is
--: involved in either.
ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
	local part = prompt.Parent
	if not (part and part:IsA("BasePart")) then
		return
	end
	local egg = part:GetAttribute("egg")
	if prompt.Name == "Hatch" and type(egg) == "number" then
		hatchFor(player, egg)
	end
end)

-- ================================== players =================================
local function arrive(player: Player)
	local profile = Save.await(player, 12)
	local state = Sim.reconcile(if type(profile) == "table" then profile.save else nil)
	states[player] = state
	if type(profile) == "table" then
		profile.save = state
	end
	publish(player)

	if state.zone > 1 then
		--: Put them back where they were, once there is a character to move.
		task.defer(function()
			local character = player.Character or player.CharacterAdded:Wait()
			local root = character:WaitForChild("HumanoidRootPart", 8)
			if root and root:IsA("BasePart") then
				root.CFrame = World.arrival(state.zone)
			end
		end)
	end
end

for _, player in Players:GetPlayers() do
	task.spawn(arrive, player)
end
Players.PlayerAdded:Connect(function(player)
	task.spawn(arrive, player)
end)
Players.PlayerRemoving:Connect(function(player)
	persist(player)
	states[player] = nil
end)

-- =================================== seams ==================================
if Config.selfTest then
	task.defer(function()
		local report = Forge.Testing.runAndPublish(script:FindFirstChild("tests"))
		Debug.info(string.format("self test: %d passed, %d failed, %d hung",
			report.passed or 0, report.failed or 0, report.timedOut or 0))
	end)
end

Debug.probe("hatchling", function()
	local live, coins = 0, 0
	for _, state in states do
		live += 1
		coins += state.coins
	end
	return {
		players = live, totalCoins = coins, theme = Theme.id,
		world = World.describe(), tiers = Sim.TIERS, eggs = Sim.EGG_TIERS,
		roster = #Theme.roster(),
	}
end)

Debug.expose()
Debug.info(string.format("%s up in %.2fs", Config.name, os.clock() - startedAt))
