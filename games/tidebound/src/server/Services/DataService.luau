--!strict
--[[
	DataService — the save file, and everyone else's handle on it.

	Everything mutated by gameplay passes through here: coins, xp, the crate,
	the bestiary, quests. Services ask; this module is the only thing that
	answers, which is what keeps "the balance went negative" a single-file
	question with a single-file answer.

	`push` is debounced. A catch moves five fields and each one firing its
	own sync would put the whole profile on the wire twenty times a minute
	for a player doing what the game wants them to do.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Save = Forge.Save
local Net = Forge.Net
local Debug = Forge.Debug

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Format = require(Shared.Format)
local Roll = require(Shared.Roll)

local DataService = {}

local pushing: { [Player]: boolean } = {}

local function template(): any
	return {
		coins = Config.startingCoins,
		xp = 0,
		rods = { owned = { bamboo = true }, equipped = "bamboo" },
		baits = { owned = { worm = 5 }, equipped = "worm" },
		boats = { owned = { rowboat = true }, equipped = "rowboat" },
		zones = { shallows = true },
		crate = {},
		bestiary = {},
		stats = {
			caught = 0, sold = 0, coinsEarned = 0, perfect = 0, escaped = 0,
			species = 0, biggest = nil,
		},
		quests = { day = "", streak = 0, lastLogin = "", list = {}, dailyClaimed = true },
		settings = { music = 0.6, sfx = 0.8 },
		tutorial = { seen = {} },
	}
end

-- ================================= start ====================================
function DataService.start()
	Save.configure({
		store = Config.saveStore,
		version = Config.saveVersion,
		template = template(),
	})

	Save.observe(function(player: Player, profile: any)
		Debug.count("profiles.loaded")
		DataService.push(player, true)
		local level = Config.levelForXp(profile.xp or 0)
		Debug.info(string.format("profile loaded: level %d, %d coins", level, profile.coins or 0))
	end)

	Save.start()
end

-- ================================= access ===================================
function DataService.profile(player: Player): any?
	return Save.get(player)
end

function DataService.await(player: Player, timeout: number?): any?
	return Save.await(player, timeout)
end

--: The client-visible projection. Levels, capacity and luck are derived here
--: once so every consumer reads the same arithmetic.
function DataService.state(player: Player): any
	local profile = Save.get(player)
	if not profile then
		return nil
	end
	local level = Config.levelForXp(profile.xp or 0)

	--: Boat luck applies while *aboard your own boat*, which is the seat's
	--: own attribute rather than a geometry guess.
	local aboard = false
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if seat and seat:GetAttribute("Owner") == player.UserId then
		aboard = true
	end
	return {
		coins = profile.coins,
		xp = profile.xp,
		level = level,
		xpFloor = Config.xpForLevel(level),
		xpCeil = Config.xpForLevel(math.min(level + 1, Config.maxLevel)),
		rods = profile.rods,
		baits = profile.baits,
		boats = profile.boats,
		zones = profile.zones,
		crate = profile.crate,
		crateCap = Items.crateCapacity(profile.boats.equipped),
		bestiary = profile.bestiary,
		stats = profile.stats,
		quests = profile.quests,
		settings = profile.settings,
		luck = Roll.luckTotal(level, profile.rods.equipped, profile.baits.equipped,
			profile.boats.equipped, aboard),
	}
end

-- ================================== push ====================================
--[[
	Queue the whole state to one client. Consecutive calls inside the debounce
	window collapse into one send; `now` skips the queue for the moments that
	must land -- a purchase, a level-up, a claim.
]]
function DataService.push(player: Player, now: boolean?)
	if now then
		pushing[player] = nil
		local state = DataService.state(player)
		if state then
			Net.fire(player, "ProfileSync", state)
		end
		return
	end
	if pushing[player] then
		return
	end
	pushing[player] = true
	task.delay(0.4, function()
		pushing[player] = nil
		if player.Parent then
			DataService.push(player, true)
		end
	end)
end

-- ================================== coins ===================================
function DataService.addCoins(player: Player, amount: number): number?
	local profile = Save.get(player)
	if not profile then
		return nil
	end
	profile.coins = math.max(0, profile.coins + amount)
	if amount > 0 then
		profile.stats.coinsEarned += amount
	end
	return profile.coins
end

function DataService.spend(player: Player, amount: number): boolean
	local profile = Save.get(player)
	if not profile or profile.coins < amount then
		return false
	end
	profile.coins -= amount
	return true
end

-- =================================== xp =====================================
--: Returns the previous and new level so the caller can celebrate a ding.
function DataService.addXp(player: Player, amount: number): (number, number)
	local profile = Save.get(player)
	if not profile then
		return 1, 1
	end
	local before = Config.levelForXp(profile.xp or 0)
	profile.xp = math.max(0, (profile.xp or 0) + amount)
	local after = Config.levelForXp(profile.xp)
	if after > before then
		--: Every level pays a small purse, so a level is spendable, not just
		--: a number next to the name.
		local grant = after * 120
		profile.coins += grant
		Net.fire(player, "LevelUp", { level = after, coins = grant })
		Debug.count("levelups")
	end
	return before, after
end

-- ================================== crate ===================================
function DataService.crateAdd(player: Player, catch: any): boolean
	local profile = Save.get(player)
	if not profile then
		return false
	end
	local capacity = Items.crateCapacity(profile.boats.equipped)
	if #profile.crate >= capacity then
		return false
	end
	table.insert(profile.crate, catch)
	return true
end

function DataService.crateCapacity(player: Player): number
	local profile = Save.get(player)
	if not profile then
		return Config.baseCrate
	end
	return Items.crateCapacity(profile.boats.equipped)
end

-- ================================= bestiary =================================
function DataService.recordCatch(player: Player, catch: any): (boolean, boolean)
	local profile = Save.get(player)
	if not profile then
		return false, false
	end
	local entry = profile.bestiary[catch.speciesId]
	local isNew = entry == nil
	local isRecord = false
	if not entry then
		profile.bestiary[catch.speciesId] = {
			count = 1,
			record = catch.weightKg,
			firstAt = os.time(),
		}
		profile.stats.species += 1
	else
		entry.count += 1
		if catch.weightKg > entry.record then
			entry.record = catch.weightKg
			isRecord = true
		end
	end
	local biggest = profile.stats.biggest
	if not biggest or catch.weightKg > biggest.weight then
		profile.stats.biggest = { speciesId = catch.speciesId, weight = catch.weightKg }
	end
	profile.stats.caught += 1
	if catch.integrity and catch.integrity >= 0.85 then
		profile.stats.perfect += 1
	end
	return isNew, isRecord
end

-- ================================== daily ===================================
--: Which login calendar day this session lands on, and whether it is claimable.
--: A pure read; the claim itself is QuestService's.
function DataService.rollLogin(player: Player): any?
	local profile = Save.get(player)
	if not profile then
		return nil
	end
	local today = Format.dayKey()
	local yesterday = Format.dayKey(-1)
	if profile.quests.lastLogin ~= today then
		if profile.quests.lastLogin == yesterday then
			profile.quests.streak += 1
		else
			profile.quests.streak = 1
		end
		profile.quests.lastLogin = today
		profile.quests.dailyClaimed = false
		Debug.count("daily.rolls")
	end
	return profile.quests
end

-- ================================ startup sync ==============================
Players.PlayerRemoving:Connect(function(player: Player)
	pushing[player] = nil
end)

--: A small periodic save nudge for players who never trigger a mutation but
--: keep playing: the crate read is cheap and the write only happens if the
--: profile is dirty.
if RunService:IsServer() then
	task.spawn(function()
		while true do
			task.wait(150)
			for _, player in Players:GetPlayers() do
				if Save.isLoaded(player) then
					Save.write(player)
				end
			end
		end
	end)
end

return DataService
