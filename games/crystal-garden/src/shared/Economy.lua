--!strict
-- Pure authoritative arithmetic. The client never supplies a price or reward.
local Economy = {}
local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end
local function find(entries, id)
    for _, entry in ipairs(entries) do
        if entry.id == id then return entry end
    end
    return nil
end
function Economy.new(_config)
    return {coins = 30, selected = "quartz", unlocked = {quartz = true},
        upgrades = {backpack = 0, soil = 0}, bag = {}, collection = {},
        harvested = 0, sold = 0, beds = {}, goalIndex = 1}
end
function Economy.capacity(profile, config)
    return config.capacityBase + profile.upgrades.backpack * config.capacityStep
end
function Economy.upgradeCost(profile, id, config)
    local prices = config.upgrades[id]
    if not prices then return nil end
    return prices[(profile.upgrades[id] or 0) + 1]
end
function Economy.plant(profile, speciesId, now, mutationId, config)
    local species = find(config.species, speciesId)
    local mutation = find(config.mutations, mutationId)
    if not species or not mutation or not finite(now) then return nil, "Semente inválida." end
    if not profile.unlocked[speciesId] then return nil, "Desbloqueie esta espécie na loja." end
    if not finite(profile.coins) or profile.coins < species.cost then return nil, "Moedas insuficientes. Venda seus cristais!" end
    profile.coins -= species.cost
    local duration = species.growSeconds * (1 - math.min(config.maxSoilReduction, profile.upgrades.soil * 0.1))
    return {speciesId = speciesId, plantedAt = now, readyAt = now + duration,
        mutation = mutationId, value = math.floor(species.value * mutation.multiplier), harvested = false}
end
function Economy.harvest(profile, plant, now, config)
    if type(plant) ~= "table" or plant.harvested then return false, "Cristal já colhido." end
    local species = find(config.species, plant.speciesId)
    local mutation = find(config.mutations, plant.mutation)
    if not species or not mutation or not finite(now) or not finite(plant.readyAt) then return false, "Cristal inválido." end
    if now < plant.readyAt then return false, "Ainda está crescendo." end
    if #profile.bag >= Economy.capacity(profile, config) then return false, "Mochila cheia! Venda no mercado." end
    plant.harvested = true
    -- Recompute reward from definitions; no stale saved or client-provided value.
    table.insert(profile.bag, {speciesId = species.id, mutation = mutation.id,
        value = math.floor(species.value * mutation.multiplier)})
    profile.collection[species.id] = (profile.collection[species.id] or 0) + 1
    profile.harvested += 1
    return true, nil
end
function Economy.sell(profile, config)
    local total = 0
    for _, item in ipairs(profile.bag) do
        local species = find(config.species, item.speciesId)
        local mutation = find(config.mutations, item.mutation)
        if species and mutation then total += math.floor(species.value * mutation.multiplier) end
    end
    profile.bag = {}
    profile.coins += total
    profile.sold += total
    return total
end
function Economy.unlock(profile, id, config)
    local species = find(config.species, id)
    if not species then return false, "Espécie inválida." end
    if profile.unlocked[id] then return false, "Espécie já desbloqueada." end
    if not finite(profile.coins) or profile.coins < species.unlockCost then return false, "Moedas insuficientes." end
    profile.coins -= species.unlockCost
    profile.unlocked[id] = true
    profile.selected = id
    return true, nil
end
function Economy.upgrade(profile, id, config)
    local cost = Economy.upgradeCost(profile, id, config)
    if not cost then return false, "Melhoria máxima ou inválida." end
    if not finite(profile.coins) or profile.coins < cost then return false, "Moedas insuficientes." end
    profile.coins -= cost
    profile.upgrades[id] += 1
    return true, nil
end
-- Refuse malformed saved state rather than overwriting it with a fresh garden.
function Economy.validate(profile, config)
    local function integer(n) return finite(n) and n >= 0 and n % 1 == 0 end
    if type(profile) ~= "table" or not integer(profile.coins) or not integer(profile.harvested)
        or not integer(profile.sold) or not integer(profile.goalIndex) or profile.goalIndex < 1 then return false end
    for _, field in ipairs({"unlocked", "upgrades", "bag", "beds", "collection"}) do
        if type(profile[field]) ~= "table" then return false end
    end
    for id, prices in pairs(config.upgrades) do
        if not integer(profile.upgrades[id]) or profile.upgrades[id] > #prices then return false end
    end
    if not find(config.species, profile.selected) or not profile.unlocked[profile.selected] then return false end
    if #profile.bag > Economy.capacity(profile, config) then return false end
    for id, unlocked in pairs(profile.unlocked) do
        if not find(config.species, id) or type(unlocked) ~= "boolean" then return false end
    end
    for id, count in pairs(profile.collection) do
        if not find(config.species, id) or not integer(count) then return false end
    end
    local bagEntries = 0
    for index, item in pairs(profile.bag) do
        bagEntries += 1
        if not integer(index) or index < 1 or index > #profile.bag then return false end
        if type(item) ~= "table" then return false end
        local species, mutation = find(config.species, item.speciesId), find(config.mutations, item.mutation)
        if not species or not mutation then return false end
        item.value = math.floor(species.value * mutation.multiplier)
    end
    if bagEntries ~= #profile.bag then return false end
    for slot, plant in pairs(profile.beds) do
        local number = tonumber(slot)
        if not number or number % 1 ~= 0 or number < 1 or number > config.bedCount
            or type(slot) ~= "string" or slot ~= tostring(number) or type(plant) ~= "table" then return false end
        local species, mutation = find(config.species, plant.speciesId), find(config.mutations, plant.mutation)
        if not species or not mutation or not finite(plant.readyAt) or not finite(plant.plantedAt)
            or plant.readyAt < plant.plantedAt or plant.harvested ~= false then return false end
        plant.value = math.floor(species.value * mutation.multiplier)
    end
    return true
end
return Economy
