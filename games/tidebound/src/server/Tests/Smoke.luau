--!strict
--[[
	Studio smoke self-check. Runs on boot in Studio (Config.selfTest) and
	prints to Output, so verifying the rules is a boot and a log read.

	It checks the things that are pure and cheap: the world exists where the
	plan says, the catalogue is complete, the catch roll is deterministic and
	never empty, the fight is winnable at every difficulty, and the economy
	ladders actually ascend. Anything that needs a player is exercised by
	playing, not by this file.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Rng = Forge.Core.Rng

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local FishCatalog = require(Shared.FishCatalog)
local Roll = require(Shared.Roll)
local ReelMath = require(Shared.ReelMath)
local Quests = require(Shared.Quests)
local Format = require(Shared.Format)

local Smoke = {}

local passed, failed = 0, 0

local function report(ok: boolean, label: string)
	if ok then
		passed += 1
	else
		failed += 1
	end
	print(string.format("[SMOKE] %s %s", ok and "PASS" or "FAIL", label))
end

local function check(label: string, fn: () -> boolean)
	local ok, result = pcall(fn)
	report(ok and result == true, label .. (ok and "" or " (threw)"))
end

-- ================================== world ===================================
local function checkWorld(services: any)
	local WorldService = services.WorldService
	check("every zone has a dock", function()
		for _, zone in Config.zones do
			if not WorldService.docks[zone.id] then
				return false
			end
		end
		return true
	end)
	check("the harbor spawn exists", function()
		return Workspace:FindFirstChild("Tidebound") ~= nil
			and Workspace.Tidebound:FindFirstChild("HarborSpawn") ~= nil
	end)
	check("the docks are on land above the waterline", function()
		for _, zone in Config.zones do
			local dock = WorldService.docks[zone.id]
			if not dock or dock.Y < Config.waterLevel + 1 then
				print(string.format("[SMOKE]   dock %s y=%s (needs >= %.1f)",
					zone.id,
					dock and string.format("%.1f", dock.Y) or "nil",
					Config.waterLevel + 1))
				return false
			end
		end
		return true
	end)
	check("a named water point is wet and deep", function()
		for index, zone in Config.zones do
			local point = WorldService.waterPoint(zone.id, Rng.at("smoke.water", index, 0))
			local wet = WorldService.isWater(point)
			local depth = WorldService.depthAt(point)
			if not wet or depth < 1 then
				print(string.format("[SMOKE]   %s point=(%.0f, %.0f, %.0f) water=%s depth=%.2f",
					zone.id, point.X, point.Y, point.Z, tostring(wet), depth))
				return false
			end
		end
		return true
	end)
end

-- ================================ catalogue =================================
local function checkCatalog()
	check("the catalogue has 60 species", function()
		return FishCatalog.total() == 60
	end)
	check("every zone is stocked with 12", function()
		for _, zone in Config.zones do
			if #(FishCatalog.byZone[zone.id] or {}) ~= 12 then
				return false
			end
		end
		return true
	end)
	check("every species is coherent", function()
		for _, entry in FishCatalog.species do
			if entry.minKg <= 0 or entry.maxKg <= entry.minKg or entry.value <= 0 then
				return false
			end
			if not FishCatalog.rarityById[entry.rarity] then
				return false
			end
		end
		return true
	end)
end

-- =================================== roll ===================================
local function checkRoll()
	check("rolls are deterministic for a fixed stream", function()
		local function run()
			local stream = Rng.at("smoke.roll", 7, 11)
			local out = {}
			for index = 1, 20 do
				local result = Roll.fish({
					zoneId = "coral", luck = 5, hour = 12, weather = "clear", bait = "squid",
					rng = function()
						return stream:number()
					end,
				})
				out[index] = result.speciesId .. ":" .. tostring(result.weightKg)
			end
			return table.concat(out, ",")
		end
		return run() == run()
	end)
	check("every zone only ever produces its own species", function()
		for _, zone in Config.zones do
			local stream = Rng.at("smoke.zone", #zone.id, 3)
			for _ = 1, 60 do
				local result = Roll.fish({
					zoneId = zone.id, luck = 0, hour = 12, weather = "clear",
					rng = function()
						return stream:number()
					end,
				})
				local entry = FishCatalog.byId[result.speciesId]
				if not entry or entry.zone ~= zone.id then
					return false
				end
				if result.value <= 0 or result.xp <= 0 then
					return false
				end
			end
		end
		return true
	end)
	check("night and day are different waters", function()
		local function nightShare(hour: number): number
			local stream = Rng.at("smoke.night", 5, 9)
			local tagged = 0
			for _ = 1, 200 do
				local result = Roll.fish({
					zoneId = "abyss", luck = 0, hour = hour, weather = "clear",
					rng = function()
						return stream:number()
					end,
				})
				local entry = FishCatalog.byId[result.speciesId]
				if entry.tags and entry.tags.night then
					tagged += 1
				end
			end
			return tagged / 200
		end
		return nightShare(23) > nightShare(12)
	end)
end

-- ================================== fights ==================================
local function checkReel()
	check("the hardest fish is hard, not impossible", function()
		for _, difficulty in { 0.3, 0.9, 1.5 } do
			local state = ReelMath.autoplay({ seed = 1234 + difficulty * 100, difficulty = difficulty, duration = 60 })
			if not state.won then
				return false
			end
			if state.integrity <= 0 then
				return false
			end
		end
		return true
	end)
	check("a reel with no input loses", function()
		local state = ReelMath.new({ seed = 99, difficulty = 1.5, duration = 20 })
		while not state.done do
			ReelMath.step(state, false, 1 / 60)
		end
		return not state.won
	end)
	check("the fight cannot be won faster than the floor", function()
		local state = ReelMath.autoplay({ seed = 5, difficulty = 0.3, duration = 60 }, 1 / 240)
		return state.won and state.t >= Config.minReelSeconds
	end)
end

-- ================================ economy ===================================
local function checkLadders()
	check("rod power ascends", function()
		for index = 2, #Items.rods do
			if Items.rods[index].power <= Items.rods[index - 1].power then
				return false
			end
			if Items.rods[index].cost <= Items.rods[index - 1].cost then
				return false
			end
		end
		return true
	end)
	check("crate capacity ascends with boats", function()
		local last = -1
		for _, boat in Items.boats do
			local capacity = Items.crateCapacity(boat.id)
			if capacity < last then
				return false
			end
			last = capacity
		end
		return Items.crateCapacity("cutter") > Items.crateCapacity("rowboat")
	end)
end

-- ================================= quests ===================================
local function checkQuests()
	check("daily quests are deterministic", function()
		local function run()
			local list = Quests.roll(12345, "2026-10-15", 12, { "shallows", "kelp" })
			local labels = {}
			for _, quest in list do
				table.insert(labels, quest.label)
			end
			return table.concat(labels, "|")
		end
		return run() == run() and #Quests.roll(12345, "2026-10-15", 12, { "shallows" }) > 0
	end)
	check("progress clamps at target and pays a reward", function()
		local list = Quests.roll(777, "2026-10-15", 20, { "shallows", "kelp", "coral" })
		local quest = list[1]
		local event = {
			kind = "catch", speciesId = quest.kind == "zone" and FishCatalog.byZone[quest.zoneId][1].id or "any",
			zoneId = quest.zoneId or "shallows", rarity = "mythic", weightKg = 999,
			mutation = "rainbow", integrity = 1, weather = "rain",
		}
		for _ = 1, 50 do
			local next_ = Quests.apply(quest, event)
			if next_ then
				quest.progress = next_
			end
		end
		return quest.progress <= quest.target and quest.rewardCoins > 0
	end)
	check("the day key moves one day at a time", function()
		return Format.dayNumber() - Format.dayNumber(Format.dayKey(-1)) == 1
	end)
end

-- ================================= weather ==================================
local function checkWeather(services: any)
	local WeatherService = services.WeatherService
	check("every weather phase has a modifier", function()
		for _, phase in Config.weather.sequence do
			local modifier = Config.weather.modifier[phase]
			if not modifier or not modifier.label or modifier.bite <= 0 then
				return false
			end
		end
		return true
	end)
	check("the live phase is one of the sequence and luck is sane", function()
		local phase = WeatherService.phase()
		for _, known in Config.weather.sequence do
			if known == phase then
				return WeatherService.luckBonus() >= 0
			end
		end
		return false
	end)
end

-- ================================== run =====================================
function Smoke.run(services: any)
	task.spawn(function()
		--: The terrain is painted during WorldService.start; this waits until
		--: the paint has certainly happened before measuring it.
		task.wait(2)
		checkWorld(services)
		checkCatalog()
		checkRoll()
		checkReel()
		checkLadders()
		checkQuests()
		checkWeather(services)
		print(string.format("[SMOKE] done: %d passed, %d failed", passed, failed))
		Forge.Debug.count("smoke.passed", passed)
		Forge.Debug.count("smoke.failed", failed)
	end)
end

return Smoke
