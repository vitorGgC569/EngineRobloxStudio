--!strict
--[[
	Roll — what was on the line.

	`Roll.fish` is a pure function of its context and an injected random
	stream. That is not tidiness: it is what lets the same code produce the
	catch the server rules on, the fixture a test asserts against, and the
	"what would this rod catch here" preview the shop shows. One day it will
	be Monte-Carloed against a spreadsheet, and it will not have to be
	reimplemented to be simulated.

	Two layers pick the fish. Rarity is drawn first, then the species inside
	it. Drawing species directly would make a zone's twelve commons invisible
	next to one mythic -- the tiers are weights, not a flat menu.
]]

local Config = require(script.Parent.Config)
local FishCatalog = require(script.Parent.FishCatalog)
local Items = require(script.Parent.Items)

local Roll = {}

export type Context = {
	zoneId: string?,
	luck: number,
	hour: number,
	weather: string,
	bait: string?,
	boatLuck: number?,
	rng: () -> number,
}

-- ============================== environment =================================
function Roll.isNight(hour: number): boolean
	return hour >= Config.nightStartHour or hour < Config.nightEndHour
end

--: How much a species' tags tilt the draw in this context. Multiplicative so
--: tags compose: a night storm fish in a storm at night is genuinely a
--: different animal.
function Roll.tagFactor(tags: any, hour: number, weather: string): number
	if not tags then
		return 1
	end
	local factor = 1
	if tags.night and Roll.isNight(hour) then
		factor *= tags.night
	end
	if tags.day and not Roll.isNight(hour) then
		factor *= tags.day
	end
	if tags.rain and (weather == "rain" or weather == "storm") then
		factor *= tags.rain
	end
	if tags.storm and weather == "storm" then
		factor *= tags.storm
	end
	return factor
end

--: Luck ramps a tier's weight: weight * (1 + luck * bias). At luck 15 the
--: mythic tier has moved from 0.45 to 2.5 -- five times as likely, still a
--: tail event.
function Roll.luckFactor(bias: number, luck: number): number
	return 1 + math.max(luck, 0) * bias
end

-- ================================= the draw =================================
local function drawRarity(context: Context, entries: { any }): any
	local seen = {}
	local order = {}
	for _, entry in entries do
		local tier = FishCatalog.rarityById[entry.rarity]
		if tier and not seen[tier.id] then
			seen[tier.id] = true
			table.insert(order, tier)
		end
	end
	table.sort(order, function(a, b)
		return a.order < b.order
	end)

	local total = 0
	local weights = {}
	for index, tier in order do
		local weight = tier.weight * Roll.luckFactor(tier.luckBias, context.luck)
		weights[index] = weight
		total += weight
	end
	if total <= 0 then
		return order[1]
	end

	local point = context.rng() * total
	local running = 0
	for index, tier in order do
		running += weights[index]
		if point <= running then
			return tier
		end
	end
	return order[#order]
end

local function drawSpecies(context: Context, entries: { any }): any
	local total = 0
	local weights = {}
	for index, entry in entries do
		local weight = Roll.tagFactor(entry.tags, context.hour, context.weather)
		weights[index] = weight
		total += weight
	end
	if total <= 0 then
		return entries[1]
	end
	local point = context.rng() * total
	local running = 0
	for index, entry in entries do
		running += weights[index]
		if point <= running then
			return entry
		end
	end
	return entries[#entries]
end

local function drawMutation(context: Context): any
	--: Rarest first, so "rainbow" is not shadowed by the three checks before
	--: it. With luck, every odds tag improves by 6% per point.
	local chances = {}
	for _, mutation in Config.mutations do
		if mutation.odds > 0 then
			table.insert(chances, mutation)
		end
	end
	table.sort(chances, function(a, b)
		return a.odds > b.odds
	end)

	local boost = 1 + math.max(context.luck, 0) * 0.06
	for _, mutation in chances do
		if context.rng() < boost / mutation.odds then
			return mutation
		end
	end
	return Config.mutations[1]
end

--[[
	Resolve one bite. The returned table is the server's truth about a catch:
	the client only ever hears the rendered version of it.
]]
function Roll.fish(context: Context): any
	local zoneId = context.zoneId or "shallows"
	local entries = FishCatalog.byZone[zoneId] or FishCatalog.byZone.shallows

	local tier = drawRarity(context, entries)
	local pool = {}
	for _, entry in entries do
		if entry.rarity == tier.id then
			table.insert(pool, entry)
		end
	end
	local species = drawSpecies(context, pool)

	local bias = Config.weightBias
	--: Bait steers the size a little: better bait, bigger average. Small
	--: enough that it is a nudge, not a purchase.
	local bait = context.bait and Items.baitById[context.bait]
	local sizePush = bait and (0.05 + bait.luck * 0.008) or 0

	local roll = context.rng()
	local sizeT = math.clamp(roll ^ bias + sizePush * context.rng(), 0, 1)
	local weightKg = species.minKg + (species.maxKg - species.minKg) * sizeT

	local mutation = drawMutation(context)
	local value = math.floor(species.value * (0.55 + 0.9 * sizeT) * mutation.weight)
	local xp = math.floor(value * Config.xpPerValue) + tier.xpBonus

	return {
		speciesId = species.id,
		rarity = tier.id,
		weightKg = math.floor(weightKg * 100 + 0.5) / 100,
		sizeT = sizeT,
		mutation = mutation.id,
		value = value,
		xp = xp,
	}
end

--[[
	The whole luck stack for one cast, in one place so the shop, the HUD and
	the roll cannot disagree about what a player's luck is.
]]
function Roll.luckTotal(level: number, rodId: string?, baitId: string?, boatId: string?, aboard: boolean): number
	local luck = (level - 1) * Config.luckPerLevel
	local rod = rodId and Items.rodById[rodId]
	luck += rod and rod.luck or 0
	local bait = baitId and Items.baitById[baitId]
	luck += bait and bait.luck or 0
	if aboard then
		local boat = boatId and Items.boatById[boatId]
		luck += boat and boat.luck or 0
	end
	return luck
end

return Roll
