--!strict
--[[
	Tidebound — a fishing and sailing game.

	What this file is: the numbers a player can argue about. Catch odds,
	rod power, level pace, what a boat costs. If a value shapes the feel of
	the game, it lives here and nowhere else.

	What this file is not: anything about how it is built. Terrain, models
	and layout are WorldService's; this is the economy and the physics of
	the fishing loop.
]]

local Config = {}

Config.name = "Tidebound"

-- One seed, named streams downstream. The world a player sails is the world
-- every other server sails.
Config.seed = 20261015

-- The waterline every other system measures from. WorldService paints terrain
-- against this; fishing, boats and swimming all trust it.
Config.waterLevel = 24

Config.worldSize = 2048

-- Where the game puts things the player or a validator may want to count.
Config.containers = { "Tidebound", "Bobbers", "Boats" }

Config.saveStore = "tidebound_v1"
Config.saveVersion = 1

--: Studio-only self test. Off in play sessions; `forge gametest` flips it.
Config.selfTest = true

-- ============================== progression ================================
-- Level is derived, never stored as truth: xp is the number, level is a
-- reading of it. That way a balance change to the curve never corrupts saves.
Config.maxLevel = 50

--: Total xp required to *reach* level n, for n >= 10: 90 * n^1.62.
function Config.xpForLevel(level: number): number
	if level <= 10 then
		return math.floor((level - 1) * 420 + (level - 1) ^ 2 * 55)
	end
	return math.floor(90 * level ^ 1.62) - 1520
end

function Config.levelForXp(xp: number): number
	local level = 1
	for n = 2, Config.maxLevel do
		if xp >= Config.xpForLevel(n) then
			level = n
		else
			break
		end
	end
	return level
end

--: Every level pays a small permanent luck bonus, so grinding is fishing
--: luck and not only a bigger rod.
Config.luckPerLevel = 0.045

-- ================================= economy ==================================
Config.startingCoins = 150

--: Selling can happen from anywhere through the crate, but the dock sells
--: better: the difference is why the dock is a place people stand.
Config.dockSellBonus = 1.15

Config.travelCost = 60

--: Crate capacity grows with the boat. Selling in the field is convenient;
--: selling at the dock is worth a trip.
Config.baseCrate = 24

-- ================================= fishing ==================================
Config.castChargeSeconds = 1.15
Config.biteMinSeconds = 2.2
Config.biteMaxSeconds = 6.8
Config.bobberSettleSeconds = 0.35

--: The reel minigame's outer clock. Losing to time is a real loss.
Config.reelTimeoutBase = 12
Config.reelTimeoutPerDifficulty = 6

--: Anti-cheat floors. A reported win faster than this is refused; the number
--: is below any physically winnable time at the hardest difficulty.
Config.minReelSeconds = 0.9

--: Weight is rolled with a bias toward the small end. r^bias, so the record
--: fish in a species is genuinely rare instead of uniform noise.
Config.weightBias = 1.7

--: Fish give xp per coin of value plus a flat rarity bonus.
Config.xpPerValue = 0.55

--: Mutation odds, rolled once per catch after the species. A mutation
--: multiplies the sale value and is etched onto the catch card.
Config.mutations = {
	{ id = "normal", name = "Normal", odds = 0, weight = 1.0, color = Color3.fromRGB(210, 214, 220) },
	{ id = "shiny", name = "Shiny", odds = 60, weight = 2.0, color = Color3.fromRGB(122, 224, 255) },
	{ id = "frozen", name = "Frozen", odds = 170, weight = 2.5, color = Color3.fromRGB(168, 216, 255) },
	{ id = "golden", name = "Golden", odds = 240, weight = 3.5, color = Color3.fromRGB(240, 200, 96) },
	{ id = "rainbow", name = "Rainbow", odds = 950, weight = 5.0, color = Color3.fromRGB(255, 122, 222) },
}

-- ================================= weather =================================
--: Weather is server-authoritative and cyclical. Each phase tilts the water:
--: rain wakes the fish up, a storm drags the big ones close to the surface.
Config.weather = {
	sequence = { "clear", "breeze", "rain", "storm" },
	secondsPerPhase = 210,
	--: Per-phase bite window and luck. Any phase absent from this table is
	--: neutral.
	modifier = {
		clear = { bite = 1.0, luck = 0.0, label = "Clear" },
		breeze = { bite = 0.92, luck = 0.5, label = "Breezy" },
		rain = { bite = 0.75, luck = 1.5, label = "Rain" },
		storm = { bite = 0.85, luck = 3.0, label = "Storm" },
	},
}

--: Night fish bite through the window from dusk to dawn. Hour is real
--: Roblox clock time, synced to players.
Config.nightStartHour = 19.5
Config.nightEndHour = 5.5
Config.nightLuckBonus = 1.2

-- =================================== zones ==================================
-- Five waters. Unlock cost gates the teleport and the fishing both; the
-- species come from FishCatalog.
Config.zones = {
	{
		id = "shallows",
		name = "Saltwind Shallows",
		center = Vector2.new(0, 0),
		radius = 300,
		depth = "shallow",
		unlockLevel = 1,
		cost = 0,
		blurb = "Green water over white sand. Everything starts here.",
	},
	{
		id = "kelp",
		name = "Kelp Hollow",
		center = Vector2.new(-660, 250),
		radius = 260,
		depth = "reef",
		unlockLevel = 5,
		cost = 2500,
		blurb = "A sunken forest that swallows sound and hides bright things.",
	},
	{
		id = "coral",
		name = "Coral Steps",
		center = Vector2.new(540, 450),
		radius = 260,
		depth = "reef",
		unlockLevel = 12,
		cost = 12000,
		blurb = "Terraces of colour dropping away into blue.",
	},
	{
		id = "storm",
		name = "Stormbreak Shelf",
		center = Vector2.new(-500, -580),
		radius = 260,
		depth = "open",
		unlockLevel = 20,
		cost = 45000,
		blurb = "Weather arrives here first and never quite leaves.",
	},
	{
		id = "abyss",
		name = "Abyss Trench",
		center = Vector2.new(270, -700),
		radius = 280,
		depth = "trench",
		unlockLevel = 30,
		cost = 150000,
		blurb = "Past the shelf light stops. The catalogue gets strange.",
	},
}

function Config.zone(id: string): any
	for _, zone in Config.zones do
		if zone.id == id then
			return zone
		end
	end
	return nil
end

--: Which zone a world position falls in, or nil for open sea between zones.
--: Open sea fishes from the shallows table so a stray cast is never nothing.
function Config.zoneAt(position: Vector3): any
	local point = Vector2.new(position.X, position.Z)
	for _, zone in Config.zones do
		if (point - zone.center).Magnitude <= zone.radius then
			return zone
		end
	end
	return nil
end

return Config
