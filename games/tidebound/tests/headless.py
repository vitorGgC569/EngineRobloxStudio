"""Run Tidebound's pure modules under the headless Luau harness and assert.

The modules this exercises -- the catalogue, the roll, the reel arithmetic,
the quest roll, the price ladders, and the `SeaPlan` the terrain is painted
from -- are the rules of the game. They are pure Luau on purpose so they can
run in three places; this is the third place, and the assertions here are
the ones a Studio playtest cannot make reliably: determinism of a seeded
roll, monotonicity of a ladder, the boundary of a clamp, the share of each
zone's ring that is actually water. Studio evidence proves the game *runs*;
this proves it is *right*.

    python games/tidebound/tests/headless.py

Exits 0 on pass, 1 on any failed assertion. This is not the harness's
`shim` speaking for the engine -- the shim deliberately implements a partial
Roblox and fails loudly on anything else, so a pass here means these
modules are genuinely portable, not that the engine was faked into
agreement.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from rqe.luau_harness import run as run_harness  # noqa: E402

BODY = """
local Config = Require("Config")
local FishCatalog = Require("FishCatalog")
local Items = Require("Items")
local Roll = Require("Roll")
local ReelMath = Require("ReelMath")
local Quests = Require("Quests")
local Format = Require("Format")

local checks = 0
local failures = {}
local function check(name, ok, detail)
	checks += 1
	if not ok then
		table.insert(failures, name .. (detail ~= nil and (": " .. tostring(detail)) or ""))
	end
end

local function rngFrom(seed)
	local state = seed % 4294967296
	return function()
		state = (state * 1664525 + 1013904223) % 4294967296
		return state / 4294967296
	end
end

-- ============================== the catalogue ==============================
check("catalogue size", FishCatalog.total() == 60, FishCatalog.total())

local perZone = {}
for _, species in FishCatalog.species do
	perZone[species.zone] = (perZone[species.zone] or 0) + 1
end
for _, zone in Config.zones do
	check("zone " .. zone.id .. " holds 12 species", perZone[zone.id] == 12, perZone[zone.id])
end

local coherence = 0
local rarityUsed = {}
for _, species in FishCatalog.species do
	rarityUsed[species.rarity] = true
	local tier = FishCatalog.rarityById[species.rarity]
	if not tier then coherence += 1 end
	if type(species.minKg) ~= "number" or type(species.maxKg) ~= "number" then coherence += 1 end
	if not (species.minKg > 0 and species.maxKg > species.minKg) then coherence += 1 end
	if not (type(species.value) == "number" and species.value > 0) then coherence += 1 end
	if Config.zone(species.zone) == nil then coherence += 1 end
end
check("catalogue coherence", coherence == 0, coherence)
for _, tier in FishCatalog.rarities do
	check("rarity " .. tier.id .. " is used", rarityUsed[tier.id] == true)
end

-- ============================== zone lookup ================================
local home = Config.zoneAt(Vector3.new(0, Config.waterLevel, 0))
check("origin is the shallows", home ~= nil and home.id == "shallows")
check("open sea is nothing", Config.zoneAt(Vector3.new(5000, Config.waterLevel, 5000)) == nil)
local deep = Config.zoneAt(Vector3.new(270, Config.waterLevel, -700))
check("the trench is where it says", deep ~= nil and deep.id == "abyss")

-- ============================== the roll ===================================
local rollViolations = 0
local rng = rngFrom(20261015)
for _, zone in Config.zones do
	for _, weather in { "clear", "rain", "storm" } do
		for _, hour in { 3, 12, 21 } do
			for _ = 1, 40 do
				local result = Roll.fish({
					zoneId = zone.id,
					luck = 6,
					hour = hour,
					weather = weather,
					bait = "shrimp",
					rng = rng,
				})
				local species = FishCatalog.byId[result.speciesId]
				if species == nil then
					rollViolations += 1
				else
					if species.zone ~= zone.id then rollViolations += 1 end
					if result.rarity ~= species.rarity then rollViolations += 1 end
					if not (result.weightKg >= species.minKg - 0.01 and result.weightKg <= species.maxKg + 0.01) then
						rollViolations += 1
					end
				end
				if not (result.value > 0 and result.xp > 0) then rollViolations += 1 end
				if result.mutation == nil then rollViolations += 1 end
			end
		end
	end
end
check("roll invariants across 1800 casts", rollViolations == 0, rollViolations)

local first = Roll.fish({ zoneId = "kelp", luck = 0, hour = 12, weather = "clear", rng = rngFrom(7) })
local second = Roll.fish({ zoneId = "kelp", luck = 0, hour = 12, weather = "clear", rng = rngFrom(7) })
check(
	"same seed, same fish",
	first.speciesId == second.speciesId
		and first.weightKg == second.weightKg
		and first.value == second.value
		and first.mutation == second.mutation)

--: Night-tagged fish should genuinely prefer the dark. Two runs of the same
--: stream, only the clock differs; the bug this catches is a tag factor
--: applied with the wrong sign or against the wrong hour.
local function nightTaggedShare(hour)
	local stream = rngFrom(99)
	local tagged = 0
	local total = 1500
	for _ = 1, total do
		local result = Roll.fish({ zoneId = "shallows", luck = 0, hour = hour, weather = "clear", rng = stream })
		local species = FishCatalog.byId[result.speciesId]
		if species and species.tags and species.tags.night then
			tagged += 1
		end
	end
	return tagged / total
end
local nightShare = nightTaggedShare(23)
local dayShare = nightTaggedShare(12)
check("night favours night fish", nightShare > dayShare, string.format("%.3f vs %.3f", nightShare, dayShare))

-- ============================== luck stack =================================
check("base luck is zero", Roll.luckTotal(1, "bamboo", nil, nil, false) == 0)
check("levels pay luck", Roll.luckTotal(5, nil, nil, nil, false) > Roll.luckTotal(1, nil, nil, nil, false))
local ashore = Roll.luckTotal(10, "tidecaller", "kraken", "cutter", false)
local aboard = Roll.luckTotal(10, "tidecaller", "kraken", "cutter", true)
check("the boat adds while aboard", aboard == ashore + 2, string.format("%.2f vs %.2f", ashore, aboard))

-- ============================== the fight ==================================
for _, difficulty in { 0.3, 0.9, 1.5 } do
	local params = {
		seed = 424242,
		difficulty = difficulty,
		duration = Config.reelTimeoutBase + difficulty * Config.reelTimeoutPerDifficulty,
	}
	local won = ReelMath.autoplay(params)
	check("a competent hand lands a " .. tostring(difficulty) .. " fish", won.done and won.won, won.reason)
	check("and it takes at least the floor", won.t >= Config.minReelSeconds, won.t)
	local replay = ReelMath.autoplay(params)
	check("the dance is deterministic", replay.t == won.t and replay.reason == won.reason)

	local idle = ReelMath.new(params)
	while not idle.done do
		ReelMath.step(idle, false, 1 / 60)
	end
	if difficulty == 1.5 then
		check("doing nothing loses the 1.5 fish", idle.done and not idle.won, idle.reason)
	end
end

-- ============================== the quests =================================
local dayKey = "2026-10-15"
local unlocked = { "shallows", "kelp" }
local questsA = Quests.roll(12345, dayKey, 10, unlocked)
local questsB = Quests.roll(12345, dayKey, 10, unlocked)
check("three quests a day", #questsA == 3, #questsA)
check(
	"same player, same day, same quests",
	#questsA == #questsB
		and questsA[1].label == questsB[1].label
		and questsA[2].label == questsB[2].label
		and questsA[3].label == questsB[3].label)
local kindSeen = {}
for _, quest in questsA do
	kindSeen[quest.kind] = true
	check("quest reward pays", quest.rewardCoins > 0 and quest.rewardXp > 0)
	check("quest starts empty", quest.progress == 0 and quest.claimed == false)
end

local zoneQuest = { kind = "zone", zoneId = "kelp", target = 3, progress = 2, seen = {} }
check("progress clamps at target", Quests.apply(zoneQuest, { kind = "catch", zoneId = "kelp" }) == 3)
check("other water is not this quest", Quests.apply(zoneQuest, { kind = "catch", zoneId = "shallows" }) == nil)

--: `apply` returns the new progress and mutates nothing but `seen`, exactly
--: as QuestService consumes it (writes the return value back). The test has
--: to play by the same contract, or it is testing a service that does not
--: exist.
local function feed(quest, event)
	local next_ = Quests.apply(quest, event)
	if next_ ~= nil then
		quest.progress = next_
	end
	return next_
end

local varietyQuest = { kind = "variety", target = 2, progress = 0, seen = {} }
check("first species counts", feed(varietyQuest, { kind = "catch", speciesId = "minnow" }) == 1)
check("the same species twice does not", feed(varietyQuest, { kind = "catch", speciesId = "minnow" }) == nil)
check("a new species does", feed(varietyQuest, { kind = "catch", speciesId = "perch" }) == 2)

local sellQuest = { kind = "sell", target = 1000, progress = 0, seen = {} }
check("a sale pays the quest", feed(sellQuest, { kind = "sell", coins = 400 }) == 400)
check("and it can overshoot", feed(sellQuest, { kind = "sell", coins = 900 }) == 1000)

check("streak starts at one", Quests.streakMultiplier(1) == 1)
check("streak caps", Quests.streakMultiplier(100) == 1.5)
check("day one of the calendar", Quests.loginReward(1).coins == 250)
check("the calendar cycles", Quests.loginReward(8).coins == Quests.loginReward(1).coins)

-- ============================== the ladders ================================
local ladderViolations = 0
for index = 2, #Items.rods do
	local previous = Items.rods[index - 1]
	local current = Items.rods[index]
	if not (current.cost > previous.cost) then ladderViolations += 1 end
	if not (current.power > previous.power) then ladderViolations += 1 end
	if not (current.range >= previous.range) then ladderViolations += 1 end
	if not (current.luck >= previous.luck) then ladderViolations += 1 end
	if not (current.reel >= previous.reel) then ladderViolations += 1 end
end
check("rods ascend on every axis", ladderViolations == 0, ladderViolations)

local boatViolations = 0
for index = 2, #Items.boats do
	local previous = Items.boats[index - 1]
	local current = Items.boats[index]
	if not (current.cost > previous.cost) then boatViolations += 1 end
	if not (current.speed > previous.speed) then boatViolations += 1 end
	if not (current.crate >= previous.crate) then boatViolations += 1 end
	if not (current.luck >= previous.luck) then boatViolations += 1 end
end
check("boats ascend on every axis", boatViolations == 0, boatViolations)
check("crate capacity reads the boat", Items.crateCapacity(nil) == Config.baseCrate)
check("cutter holds the most", Items.crateCapacity("cutter") > Items.crateCapacity("trawler"))

local baitViolations = 0
for index = 2, #Items.baits do
	local previous = Items.baits[index - 1]
	local current = Items.baits[index]
	if not (current.cost > previous.cost) then baitViolations += 1 end
	if not (current.bite < previous.bite) then baitViolations += 1 end
	if not (current.luck >= previous.luck) then baitViolations += 1 end
end
check("baits get faster and luckier with price", baitViolations == 0, baitViolations)

-- ============================== the numbers read ===========================
check("money under a thousand", Format.money(999) == "$999", Format.money(999))
check("money in thousands", Format.money(1500) == "$1.5K", Format.money(1500))
check("money in millions", Format.money(2500000) == "$2.5M", Format.money(2500000))
check("money is exact when asked", Format.moneyFull(12450) == "$12,450", Format.moneyFull(12450))
check("weight to two decimals", Format.weight(3.456) == "3.46 kg", Format.weight(3.456))
check("weight to one", Format.weight(42.42) == "42.4 kg", Format.weight(42.42))
check("weight whole above a hundred", Format.weight(123.6) == "124 kg", Format.weight(123.6))
check("clock pads", Format.hour(7.5) == "07:30", Format.hour(7.5))
check("clock does not round up hours", Format.hour(23.999) == "23:59", Format.hour(23.999))
check("percent rounds", Format.percent(0.856) == "86%", Format.percent(0.856))
check("day key shape", string.match(Format.dayKey(), "^%d%d%d%d%-%d%d%-%d%d$") ~= nil, Format.dayKey())

-- ============================== the weather ================================
for _, phase in Config.weather.sequence do
	local modifier = Config.weather.modifier[phase]
	check("phase " .. phase .. " is defined", modifier ~= nil and modifier.label ~= nil)
	if modifier then
		check("phase " .. phase .. " bites honestly", type(modifier.bite) == "number" and modifier.bite > 0)
	end
end
check("clear is the baseline", Config.weather.modifier.clear.bite == 1.0)

-- ============================== the sea ====================================
--[[
	The plan the terrain is painted from, measured here because the failure
	it guards is invisible until paginated against reality: an early
	`range` put the mean height of the base relief above the waterline, so
	the world shipped as a dry plain and only a live smoke test found out.
	Everything below reads `SeaPlan` through `World.heightfield` -- the
	same numbers `WorldService` builds -- with no engine involved.
]]
local World = Require("World")
local Rng = Require("Rng")
local SeaPlan = Require("SeaPlan")

local SEA = Config.waterLevel
local seaField = World.heightfield(SeaPlan.heightfieldConfig())

local wetShare, mapSamples = 0, 0
for x = -980, 980, 60 do
	for z = -980, 980, 60 do
		mapSamples += 1
		if seaField:height(x, z) < SEA - 1.2 then
			wetShare += 1
		end
	end
end
check("most of the map is water", wetShare >= mapSamples * 0.6,
	string.format("%d/%d wet", wetShare, mapSamples))

for _, zone in Config.zones do
	local stream = Rng.at("headless.sea." .. zone.id, 3, 5)
	local deep = 0
	local samples = 300
	for _ = 1, samples do
		local angle = stream:number(0, math.pi * 2)
		local radius = stream:number(zone.radius * 0.25, zone.radius * 0.8)
		local height = seaField:height(
			zone.center.X + math.cos(angle) * radius,
			zone.center.Y + math.sin(angle) * radius)
		if SEA - height >= 1 then
			deep += 1
		end
	end
	check(zone.id .. " has castable water", deep >= samples * 0.4,
		string.format("%d/%d deep", deep, samples))

	local dock = SeaPlan.dockPoint(zone)
	local dockHeight = seaField:height(dock.X, dock.Y)
	check(zone.id .. " dock is on the plan above the waterline", dockHeight >= SEA + 1,
		string.format("h=%.1f", dockHeight))
end

local trench = Config.zone("abyss")
check("the abyss is the deep one", SEA - seaField:height(trench.center.X, trench.center.Y) >= 15,
	string.format("depth=%.1f", SEA - seaField:height(trench.center.X, trench.center.Y)))

-- ================================= verdict =================================
local status = if #failures == 0 then "PASS" else "FAIL"
print("TIDEBOUND_HEADLESS " .. status .. " checks=" .. tostring(checks) .. " failures=" .. tostring(#failures))
for _, failure in failures do
	print("  FAIL " .. failure)
end
if #failures > 0 then
	error("tidebound headless validation failed")
end
"""


def main() -> int:
    result = run_harness(
        ROOT,
        libraries=[
            ROOT / "forge" / "luau" / "Forge" / "Core",
            ROOT / "forge" / "luau" / "Forge" / "World",
            ROOT / "games" / "tidebound" / "src" / "shared",
        ],
        body=BODY,
        timeout=90.0,
    )

    output = (result.stdout or "") + (result.stderr or "")
    print(output.rstrip())

    if not result.ok:
        print("HEADLESS VERDICT: FAILED TO RUN")
        return 1

    verdict_ok = "TIDEBOUND_HEADLESS PASS" in result.stdout
    print("HEADLESS VERDICT:", "PASS" if verdict_ok else "FAIL")
    return 0 if verdict_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
