--!nonstrict
-- Dependency resolution only; all scenarios use tables/math and fresh profiles.
-- Studio: require(ServerScriptService.Server.tests.Economy)()
-- Luau CLI: require this module from a runner and invoke its returned function.
local Config, Economy
if script then
    local shared = game:GetService("ReplicatedStorage"):FindFirstChild("Shared")
    assert(shared, "ReplicatedStorage.Shared is missing")
    Config = require(shared.Config)
    Economy = require(shared.Economy)
else
    Config = require("../../shared/Config")
    Economy = require("../../shared/Economy")
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, child in pairs(value) do
        result[key] = copy(child)
    end
    return result
end

local function equal(actual, expected, path)
    path = path or "state"
    assert(type(actual) == type(expected), path .. ": type changed")
    if type(expected) ~= "table" then
        assert(actual == expected or (actual ~= actual and expected ~= expected), path .. ": value changed")
        return
    end
    for key, child in pairs(expected) do
        equal(actual[key], child, path .. "." .. tostring(key))
    end
    for key in pairs(actual) do
        assert(expected[key] ~= nil, path .. ": unexpected key " .. tostring(key))
    end
end

local function rejected(profile, expectedResult, operation, plant)
    local before = copy(profile)
    local plantBefore = copy(plant)
    local result = operation()
    assert(result == expectedResult, "operation must reject")
    equal(profile, before, "profile after rejection")
    if plant then
        equal(plant, plantBefore, "plant after rejection")
    end
end

local function funded()
    local profile = Economy.new(Config)
    profile.coins = 1000000
    return profile
end

local function planted(profile, speciesId, now, mutation)
    local plant, reason = Economy.plant(profile, speciesId or "quartz", now or 100, mutation or "normal", Config)
    assert(type(plant) == "table", "plant failed: " .. tostring(reason))
    return plant
end

return function()
    local cases = {}
    local configBefore = copy(Config)
    local function test(name, run)
        table.insert(cases, {name = name, run = run})
    end

    test("new profile matches TEAM contract and owns independent tables", function()
        local first = Economy.new(Config)
        equal(first, {
            coins = 30, selected = "quartz", unlocked = {quartz = true},
            upgrades = {backpack = 0, soil = 0}, bag = {}, collection = {}, harvested = 0, sold = 0,
            beds = {}, goalIndex = 1,
        })
        local second = Economy.new(Config)
        first.unlocked.amethyst = true
        first.upgrades.backpack = 1
        first.bag[1] = {speciesId = "quartz", value = 14}
        first.collection.quartz = 1
        first.beds["1"] = {speciesId = "quartz"}
        first.goalIndex = 2
        assert(second.unlocked.amethyst == nil and second.upgrades.backpack == 0)
        assert(#second.bag == 0 and next(second.collection) == nil)
        assert(next(second.beds) == nil and second.goalIndex == 1)
    end)

    test("capacity follows backpack levels", function()
        local profile = Economy.new(Config)
        for level = 0, #Config.upgrades.backpack do
            profile.upgrades.backpack = level
            assert(Economy.capacity(profile, Config) == Config.capacityBase + Config.capacityStep * level)
        end
    end)

    for _, species in ipairs(Config.species) do
        test(species.id .. ": insufficient planting funds do not mutate", function()
            local profile = Economy.new(Config)
            profile.unlocked[species.id] = true
            profile.coins = species.cost - 1
            rejected(profile, nil, function()
                return Economy.plant(profile, species.id, 100, "normal", Config)
            end)
        end)
        test(species.id .. ": exact planting funds pay once and use configured growth/value", function()
            local profile = Economy.new(Config)
            profile.unlocked[species.id] = true
            profile.coins = species.cost
            local before = copy(profile)
            local plant = planted(profile, species.id)
            before.coins = 0
            equal(profile, before)
            assert(plant.speciesId == species.id and plant.plantedAt == 100)
            assert(plant.readyAt == 100 + species.growSeconds and plant.value == species.value)
            assert(not plant.harvested)
        end)
        if species.id ~= "quartz" then
            test(species.id .. ": locked species cannot be planted despite funds", function()
                local profile = funded()
                rejected(profile, nil, function()
                    return Economy.plant(profile, species.id, 100, "normal", Config)
                end)
            end)
            test(species.id .. ": unlock rejects low funds, charges exact cost, cannot charge twice", function()
                local profile = Economy.new(Config)
                profile.coins = species.unlockCost - 1
                rejected(profile, false, function()
                    return Economy.unlock(profile, species.id, Config)
                end)
                profile.coins = species.unlockCost
                local before = copy(profile)
                assert(Economy.unlock(profile, species.id, Config) == true)
                before.coins = 0
                before.unlocked[species.id] = true
                before.selected = species.id
                equal(profile, before)
                rejected(profile, false, function()
                    return Economy.unlock(profile, species.id, Config)
                end)
                profile.coins = species.cost
                planted(profile, species.id)
                assert(profile.coins == 0)
            end)
        end
    end

    test("starter unlock cannot be purchased again", function()
        local profile = funded()
        rejected(profile, false, function()
            return Economy.unlock(profile, "quartz", Config)
        end)
    end)

    test("unknown species and upgrade ids reject without mutation", function()
        local profile = funded()
        rejected(profile, nil, function()
            return Economy.plant(profile, "unknown-species", 100, "normal", Config)
        end)
        rejected(profile, false, function()
            return Economy.unlock(profile, "unknown-species", Config)
        end)
        rejected(profile, false, function()
            return Economy.upgrade(profile, "unknown-upgrade", Config)
        end)
        local before = copy(profile)
        assert(Economy.upgradeCost(profile, "unknown-upgrade", Config) == nil)
        equal(profile, before)
    end)

    test("unknown mutation rejects before spending", function()
        local profile = funded()
        rejected(profile, nil, function()
            return Economy.plant(profile, "quartz", 100, "unknown-mutation", Config)
        end)
    end)

    test("zero and negative funds reject purchases without mutation", function()
        for _, coins in ipairs({0, -1}) do
            local profile = Economy.new(Config)
            profile.coins = coins
            rejected(profile, nil, function()
                return Economy.plant(profile, "quartz", 100, "normal", Config)
            end)
            rejected(profile, false, function()
                return Economy.unlock(profile, "amethyst", Config)
            end)
            rejected(profile, false, function()
                return Economy.upgrade(profile, "backpack", Config)
            end)
        end
    end)

    test("nonfinite balances reject planting, unlock and upgrade without mutation", function()
        for _, coins in ipairs({0 / 0, math.huge, -math.huge}) do
            local profile = Economy.new(Config)
            profile.coins = coins
            rejected(profile, nil, function()
                return Economy.plant(profile, "quartz", 100, "normal", Config)
            end)
            rejected(profile, false, function()
                return Economy.unlock(profile, "amethyst", Config)
            end)
            rejected(profile, false, function()
                return Economy.upgrade(profile, "backpack", Config)
            end)
        end
    end)

    test("nonfinite planting and harvesting timestamps reject without mutation", function()
        for _, now in ipairs({0 / 0, math.huge, -math.huge}) do
            local profile = funded()
            rejected(profile, nil, function()
                return Economy.plant(profile, "quartz", now, "normal", Config)
            end)
            local plant = planted(profile)
            rejected(profile, false, function()
                return Economy.harvest(profile, plant, now, Config)
            end, plant)
        end
    end)

    test("harvest rejects unknown species/mutation and NaN readyAt", function()
        for _, field in ipairs({"speciesId", "mutation", "readyAt"}) do
            local profile = funded()
            local plant = planted(profile)
            plant[field] = if field == "readyAt" then 0 / 0 else "unknown-id"
            rejected(profile, false, function()
                return Economy.harvest(profile, plant, 1000, Config)
            end, plant)
        end
    end)

    test("growth rejects before readyAt and accepts exactly readyAt", function()
        local profile = funded()
        local plant = planted(profile)
        rejected(profile, false, function()
            return Economy.harvest(profile, plant, plant.readyAt - 0.001, Config)
        end, plant)
        local coins = profile.coins
        assert(Economy.harvest(profile, plant, plant.readyAt, Config) == true)
        assert(plant.harvested == true and #profile.bag == 1)
        assert(profile.harvested == 1 and profile.collection.quartz == 1)
        assert(profile.coins == coins, "harvest grants inventory, not sale coins")
        assert(profile.bag[1].speciesId == "quartz" and profile.bag[1].value == plant.value)
    end)

    test("duplicate harvest rejects before and after selling", function()
        local profile = funded()
        local plant = planted(profile)
        assert(Economy.harvest(profile, plant, plant.readyAt + 1, Config) == true)
        rejected(profile, false, function()
            return Economy.harvest(profile, plant, plant.readyAt + 2, Config)
        end, plant)
        assert(Economy.sell(profile, Config) == plant.value)
        rejected(profile, false, function()
            return Economy.harvest(profile, plant, plant.readyAt + 3, Config)
        end, plant)
        assert(Economy.sell(profile, Config) == 0)
    end)

    for _, mutation in ipairs(Config.mutations) do
        test(mutation.id .. ": server mutation determines value once", function()
            local profile = funded()
            local plant = planted(profile, "quartz", 100, mutation.id)
            local expected = Config.species[1].value * mutation.multiplier
            assert(plant.value == expected)
            assert(plant.mutation == mutation.id)
            assert(Economy.harvest(profile, plant, plant.readyAt, Config) == true)
            local coins = profile.coins
            assert(Economy.sell(profile, Config) == expected)
            assert(profile.coins == coins + expected)
        end)
    end

    test("full capacity rejects atomically; selling allows retry of the same plant", function()
        local profile = funded()
        local capacity = Economy.capacity(profile, Config)
        local total = 0
        for _ = 1, capacity do
            local plant = planted(profile)
            assert(Economy.harvest(profile, plant, plant.readyAt, Config) == true)
            total += plant.value
        end
        local pending = planted(profile)
        rejected(profile, false, function()
            return Economy.harvest(profile, pending, pending.readyAt, Config)
        end, pending)
        assert(#profile.bag == capacity and not pending.harvested)
        assert(Economy.sell(profile, Config) == total)
        assert(Economy.harvest(profile, pending, pending.readyAt, Config) == true)
        assert(#profile.bag == 1 and profile.harvested == capacity + 1)
    end)

    test("backpack upgrade opens capacity for an already ready plant", function()
        local profile = funded()
        for _ = 1, Economy.capacity(profile, Config) do
            local plant = planted(profile)
            assert(Economy.harvest(profile, plant, plant.readyAt, Config) == true)
        end
        local pending = planted(profile)
        rejected(profile, false, function()
            return Economy.harvest(profile, pending, pending.readyAt, Config)
        end, pending)
        assert(Economy.upgrade(profile, "backpack", Config) == true)
        assert(Economy.harvest(profile, pending, pending.readyAt, Config) == true)
        assert(#profile.bag == Config.capacityBase + 1)
    end)

    for _, id in ipairs({"backpack", "soil"}) do
        test(id .. ": every upgrade price, exact funds and maximum level", function()
            local profile = Economy.new(Config)
            for level, price in ipairs(Config.upgrades[id]) do
                assert(Economy.upgradeCost(profile, id, Config) == price)
                profile.coins = price - 1
                rejected(profile, false, function()
                    return Economy.upgrade(profile, id, Config)
                end)
                profile.coins = price
                local before = copy(profile)
                assert(Economy.upgrade(profile, id, Config) == true)
                before.coins = 0
                before.upgrades[id] = level
                equal(profile, before)
            end
            profile.coins = 1000000
            assert(Economy.upgradeCost(profile, id, Config) == nil)
            rejected(profile, false, function()
                return Economy.upgrade(profile, id, Config)
            end)
            assert(profile.upgrades[id] == #Config.upgrades[id])
        end)
    end

    test("soil improves future growth within configured reduction and preserves existing plant", function()
        local profile = funded()
        local original = planted(profile)
        local before = copy(original)
        local previous = original.readyAt - original.plantedAt
        for _ = 1, #Config.upgrades.soil do
            assert(Economy.upgrade(profile, "soil", Config) == true)
            local plant = planted(profile)
            local duration = plant.readyAt - plant.plantedAt
            assert(duration < previous and duration > 0)
            assert(duration + 0.000001 >= Config.species[1].growSeconds * (1 - Config.maxSoilReduction))
            previous = duration
            equal(original, before)
        end
    end)

    test("sell totals mixed inventory, drains bag, preserves collection, cannot duplicate coins", function()
        local profile = funded()
        assert(Economy.unlock(profile, "amethyst", Config) == true)
        local quartz = planted(profile, "quartz", 100, "golden")
        local amethyst = planted(profile, "amethyst")
        assert(Economy.harvest(profile, quartz, quartz.readyAt, Config) == true)
        assert(Economy.harvest(profile, amethyst, amethyst.readyAt, Config) == true)
        local before = copy(profile)
        local value = quartz.value + amethyst.value
        assert(Economy.sell(profile, Config) == value)
        assert(profile.coins == before.coins + value and #profile.bag == 0)
        assert(profile.harvested == before.harvested)
        equal(profile.collection, before.collection)
        equal(profile.unlocked, before.unlocked)
        equal(profile.upgrades, before.upgrades)
        assert(profile.sold == before.sold + value, "sold counts sale coins in Garden goals")
        local soldBefore = copy(profile)
        for _ = 1, 3 do
            assert(Economy.sell(profile, Config) == 0)
            equal(profile, soldBefore)
        end
    end)

    test("empty bag sale returns zero and preserves fresh profile", function()
        local profile = Economy.new(Config)
        local before = copy(profile)
        assert(Economy.sell(profile, Config) == 0)
        equal(profile, before)
    end)

    test("harvest and sell ignore inflated cached values", function()
        local profile = funded()
        local plant = planted(profile, "quartz", 100, "golden")
        plant.value = 1000000000
        assert(Economy.harvest(profile, plant, plant.readyAt, Config) == true)
        local expected = math.floor(Config.species[1].value * Config.mutations[4].multiplier)
        assert(profile.bag[1].value == expected)
        profile.bag[1].value = 0 / 0
        local before = profile.coins
        assert(Economy.sell(profile, Config) == expected)
        assert(profile.coins == before + expected and #profile.bag == 0)
        assert(Economy.sell(profile, Config) == 0 and profile.coins == before + expected)
    end)

    test("sell refuses rewards for unknown inventory species/mutation", function()
        local profile = Economy.new(Config)
        profile.bag = {
            {speciesId = "unknown-species", mutation = "normal", value = 1000000000},
            {speciesId = "quartz", mutation = "unknown-mutation", value = 1000000000},
            {speciesId = "quartz", mutation = "normal", value = 1000000000},
        }
        assert(Economy.sell(profile, Config) == Config.species[1].value)
        assert(profile.coins == 30 + Config.species[1].value and #profile.bag == 0)
        assert(profile.sold == Config.species[1].value)
        assert(Economy.sell(profile, Config) == 0)
    end)

    local failures, results = {}, {}
    for _, case in ipairs(cases) do
        local ok, err = pcall(case.run)
        table.insert(results, {name = case.name, passed = ok, detail = if ok then nil else tostring(err)})
        if not ok then
            table.insert(failures, case.name .. ": " .. tostring(err))
        end
    end
    local configOk, configError = pcall(equal, Config, configBefore, "Config")
    if not configOk then
        table.insert(failures, "tests must not mutate Config: " .. tostring(configError))
    end
    assert(#failures == 0, "Economy suite failures:\n" .. table.concat(failures, "\n"))
    return {passed = #cases, failed = 0, results = results}
end
