--!strict
-- Awards coins/XP for round events, applies win bonuses and gamepass multipliers,
-- owns the shop actions (crates, equipping skins). All grants are server-side.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local Rewards = require(Shared.Rewards)
local SkinCatalog = require(Shared.SkinCatalog)
local CrateRoll = require(Shared.CrateRoll)
local LevelMath = require(Shared.LevelMath)
local Titles = require(Shared.Titles)

local EconomyService = {}
EconomyService.__index = EconomyService

export type Deps = {
	remotes: any,
	dataService: any,
}

local rng = Random.new()

function EconomyService.new(deps: Deps)
	local self = setmetatable({}, EconomyService)
	self._deps = deps
	self._firstBloodClaimed = false
	self._roundMultiplier = 1 -- round-modifier coin multiplier (Double Coins, etc.)
	self._roundEarnings = {} :: { [Player]: number } -- for reveal-screen MVP stats
	self._gamepassCache = {} :: { [Player]: { [number]: boolean } }
	self._policyCache = {} :: { [Player]: boolean }
	Players.PlayerRemoving:Connect(function(player)
		self._roundEarnings[player] = nil
		self._gamepassCache[player] = nil
		self._policyCache[player] = nil
	end)
	return self
end

-- Gamepass ownership is prefetched on join so award() never yields on a web call
-- mid-round (a yield inside the conversion path can flip round winners —
-- finding #3). Only successful lookups are cached, so a transient API failure
-- doesn't strip a paying player's multiplier for the session (finding #8).
function EconomyService:_prefetchGamePasses(player: Player)
	local cache = self._gamepassCache[player]
	if cache == nil then
		cache = {}
		self._gamepassCache[player] = cache
	end
	for _, passId in GameConfig.Products.GamePasses :: any do
		if passId ~= 0 and cache[passId] == nil then
			local ok, owns =
				pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, passId)
			if ok then
				cache[passId] = owns
			end
		end
	end
end

-- Public read for other services (e.g. season-pass premium track). Cache-only, no yield.
function EconomyService:ownsGamePass(player: Player, passId: number): boolean
	return self:_ownsGamePass(player, passId)
end

function EconomyService:_ownsGamePass(player: Player, passId: number): boolean
	if passId == 0 then
		return false -- not created yet
	end
	local cache = self._gamepassCache[player]
	-- Cache read only — never yields; nil (prefetch pending/failed) = not owned yet
	return cache ~= nil and cache[passId] == true
end

function EconomyService:resetRound()
	self._firstBloodClaimed = false
	table.clear(self._roundEarnings)
end

-- Set by the round-modifier system each round (1 = normal). Applied on top of the
-- DoubleCoins gamepass, so a player with the pass on a Double Coins round earns 4x.
function EconomyService:setRoundMultiplier(mult: number)
	self._roundMultiplier = mult
end

function EconomyService:award(player: Player, event: string, won: boolean)
	local data = self._deps.dataService:get(player)
	if data == nil then
		return
	end
	local playerCount = #Players:GetPlayers()
	local amount = Rewards.payout(GameConfig.Rewards :: any, event :: any, {
		won = won,
		playerCount = playerCount,
		minPlayers = GameConfig.Round.MinPlayersToStart,
		fullRewardCount = GameConfig.Round.FullRewardPlayerCount,
	})
	local coins = math.floor(amount * self._roundMultiplier)
	local xp = amount
	if self:_ownsGamePass(player, GameConfig.Products.GamePasses.DoubleCoins) then
		coins *= 2
	end
	if self:_ownsGamePass(player, GameConfig.Products.GamePasses.XPBoost) then
		xp = math.floor(xp * 1.5)
	end
	local oldXp = data.xp
	data.coins += coins
	data.xp += xp
	self._roundEarnings[player] = (self._roundEarnings[player] or 0) + coins
	-- Level-up: grant the milestone reward and tell the client to celebrate.
	local levelUp = LevelMath.levelUpRewards(oldXp, data.xp)
	if levelUp.levelsGained > 0 then
		data.coins += levelUp.coins
		data.crateKeys += levelUp.keys
		-- Unlock any nametag titles the new level grants.
		for _, title in Titles.unlockedAt(levelUp.newLevel) do
			data.ownedTitles[title.id] = true
		end
		self._deps.remotes.fireClient("LevelUp", player, {
			level = levelUp.newLevel,
			coins = levelUp.coins,
			keys = levelUp.keys,
		})
	end
	self._deps.dataService:sync(player)
end

-- Round-event helpers (called from the service wiring) ---------------------------

function EconomyService:onConversion(killer: Player?)
	if killer == nil then
		return
	end
	if not self._firstBloodClaimed then
		self._firstBloodClaimed = true
		local data = self._deps.dataService:get(killer)
		if data then
			data.stats.firstBloods += 1
		end
		self:award(killer, "FirstBlood", false)
	end
	local data = self._deps.dataService:get(killer)
	if data then
		data.stats.conversions += 1
	end
	self:award(killer, "Conversion", false)
end

function EconomyService:onZombieKilled(shooter: Player)
	local data = self._deps.dataService:get(shooter)
	if data then
		data.stats.kills += 1
	end
	self:award(shooter, "ZombieKill", false)
end

function EconomyService:onRoundEnd(winner: string, survivors: { Player }, everyone: { Player })
	for _, player in everyone do
		local data = self._deps.dataService:get(player)
		if data then
			data.stats.rounds += 1
		end
	end
	local survivorsWon = winner == "SURVIVORS"
	for _, survivor in survivors do
		self:award(survivor, "SurvivedRound", survivorsWon)
		local data = self._deps.dataService:get(survivor)
		if data and survivorsWon then
			data.stats.wins += 1
		end
	end
	if #survivors == 1 then
		self:award(survivors[1], "LastSurvivor", survivorsWon)
		local data = self._deps.dataService:get(survivors[1])
		if data then
			data.stats.lastSurvivor += 1
		end
	end
	for _, player in everyone do
		self._deps.dataService:sync(player)
	end
end

function EconomyService:roundEarnings(): { [Player]: number }
	return self._roundEarnings
end

-- Shop ----------------------------------------------------------------------------

-- Paid-random-item compliance (declared in the content questionnaire): players in
-- regions where paid random items are restricted cannot open crates at all.
function EconomyService:_crateAllowedFor(player: Player): boolean
	local cache = self._policyCache[player]
	if cache == nil then
		local ok, info = pcall(PolicyService.GetPolicyInfoForPlayerAsync, PolicyService, player)
		cache = not (ok and info and info.ArePaidRandomItemsRestricted == true)
		self._policyCache[player] = cache
	end
	return cache
end

-- method: "coins" (spend coins) | "keys" (spend an earned crate key) | "robux" (already
-- paid via a dev product; no in-game deduction).
function EconomyService:openCrate(player: Player, method: string): boolean
	if not self:_crateAllowedFor(player) then
		return false
	end
	local data = self._deps.dataService:get(player)
	if data == nil then
		return false
	end
	if method == "keys" then
		if (data.crateKeys or 0) < 1 then
			return false
		end
		data.crateKeys -= 1
	elseif method == "coins" then
		if data.coins < GameConfig.Economy.CrateCostCoins then
			return false
		end
		data.coins -= GameConfig.Economy.CrateCostCoins
	end
	local winnerId, decoys = CrateRoll.open(
		SkinCatalog :: any,
		GameConfig.Economy.Rarities :: any,
		3,
		function()
			return rng:NextNumber()
		end
	)
	local duplicate = data.ownedSkins[winnerId] == true
	if duplicate then
		-- Duplicate converts to coins (30% of crate cost)
		data.coins += math.floor(GameConfig.Economy.CrateCostCoins * 0.3)
	else
		data.ownedSkins[winnerId] = true
	end
	self._deps.remotes.fireClient("CrateResult", player, {
		winner = winnerId,
		decoys = decoys,
		duplicate = duplicate,
	})
	self._deps.dataService:sync(player)
	return true
end

function EconomyService:equipSkin(player: Player, skinId: string)
	local data = self._deps.dataService:get(player)
	if data == nil or data.ownedSkins[skinId] ~= true then
		return
	end
	for _, skin in SkinCatalog do
		if skin.id == skinId then
			data.equipped[skin.slot] = skinId
			self._deps.dataService:sync(player)
			return
		end
	end
end

-- Titles: stamp the equipped title text onto the character so all clients can render it
-- over the player's head.
function EconomyService:_applyTitleAttribute(player: Player)
	local data = self._deps.dataService:get(player)
	local character = player.Character
	if data and character then
		local title = Titles.get(data.equipped.Title or "")
		character:SetAttribute("InfectedTitle", title and title.text or "")
	end
end

function EconomyService:equipTitle(player: Player, titleId: string)
	local data = self._deps.dataService:get(player)
	if data == nil or data.ownedTitles[titleId] ~= true then
		return
	end
	data.equipped.Title = titleId
	self:_applyTitleAttribute(player)
	self._deps.dataService:sync(player)
end

function EconomyService:setLoadout(player: Player, primary: string)
	local data = self._deps.dataService:get(player)
	if data then
		data.loadout.primary = primary
		self._deps.dataService:sync(player)
	end
end

function EconomyService:start()
	local remotes = self._deps.remotes
	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			self:_prefetchGamePasses(player)
		end)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_prefetchGamePasses(player)
		end)
	end
	remotes.onValidated("BuyCrate", function(player, payload)
		self:openCrate(player, payload.currency == "Keys" and "keys" or "coins")
	end)
	remotes.onValidated("EquipSkin", function(player, payload)
		self:equipSkin(player, payload.skinId)
	end)
	remotes.onValidated("SelectLoadout", function(player, payload)
		self:setLoadout(player, payload.primary)
	end)
	remotes.onValidated("EquipTitle", function(player, payload)
		self:equipTitle(player, payload.titleId)
	end)
	-- Stamp the equipped title onto each character as it spawns.
	local function hookCharacter(player: Player)
		player.CharacterAdded:Connect(function()
			task.defer(function()
				self:_applyTitleAttribute(player)
			end)
		end)
		if player.Character then
			self:_applyTitleAttribute(player)
		end
	end
	for _, player in Players:GetPlayers() do
		hookCharacter(player)
	end
	Players.PlayerAdded:Connect(hookCharacter)
end

return EconomyService
