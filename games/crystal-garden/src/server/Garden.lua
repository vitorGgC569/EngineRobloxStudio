--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Config = require(ReplicatedStorage.Shared.Config)
local Economy = require(ReplicatedStorage.Shared.Economy)
local Save = require(ReplicatedStorage.GameKit.Save)
local World = require(script.Parent.World)
local Garden = {}
local sessions = {}
local world, store, stateRemote, toastRemote
local weatherIndex = 1
local weatherEnd = 0
local rng = Random.new(Config.seed)
local started = false
local goals = {
    {text = "Colha seu primeiro cristal", field = "harvested", target = 1, reward = 15},
    {text = "Venda cristais no mercado", field = "sold", target = 14, reward = 25},
    {text = "Colha 10 cristais", field = "harvested", target = 10, reward = 60},
    {text = "Venda 500 moedas em cristais", field = "sold", target = 500, reward = 120},
    {text = "Colha 50 cristais", field = "harvested", target = 50, reward = 250},
    {text = "Venda 5.000 moedas em cristais", field = "sold", target = 5000, reward = 800},
}
local function clock() return workspace:GetServerTimeNow() end
local function weather()
    local entry = Config.weathers[weatherIndex]
    return {id = entry.id, name = entry.name, multiplier = entry.multiplier, endsAt = weatherEnd}
end
local function toast(player, message, kind)
    if player.Parent then toastRemote:FireClient(player, message, kind or "info") end
end
local function near(player, position, distance)
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    return root ~= nil and humanoid ~= nil and humanoid.Health > 0 and (root.Position - position).Magnitude <= distance
end
local function allow(session, minimum)
    local now = os.clock()
    if now - session.lastAction < minimum then return false end
    session.lastAction = now
    return true
end
local function checkGoals(player, profile)
    local goal = goals[profile.goalIndex]
    while goal and profile[goal.field] >= goal.target do
        profile.coins += goal.reward
        profile.goalIndex += 1
        toast(player, "Objetivo concluído! +" .. goal.reward .. " moedas", "success")
        goal = goals[profile.goalIndex]
    end
end
local function push(player)
    local session = sessions[player]
    if not session or not session.profile.active then return end
    local data = session.profile.data
    local bagValue = 0
    for _, item in ipairs(data.bag) do bagValue += item.value end
    local beds = {}
    for slot = 1, Config.bedCount do
        local plant = data.beds[tostring(slot)]
        local entry = {slot = slot}
        if plant then
            for key, value in pairs(plant) do entry[key] = value end
        end
        table.insert(beds, entry)
    end
    local goal = goals[data.goalIndex]
    stateRemote:FireClient(player, {coins = data.coins, selected = data.selected,
        unlocked = data.unlocked, upgrades = data.upgrades, capacity = Economy.capacity(data, Config),
        bagCount = #data.bag, bagValue = bagValue, harvested = data.harvested, sold = data.sold,
        collection = data.collection, weather = weather(), plotId = session.plot.id, beds = beds,
        nextCosts = {backpack = Economy.upgradeCost(data, "backpack", Config), soil = Economy.upgradeCost(data, "soil", Config)},
        saveMode = session.saveMode,
        goal = if goal then {text = goal.text, progress = math.min(data[goal.field], goal.target), target = goal.target}
            else {text = "Colecione todas as 6 espécies!", progress = (function()
                local count = 0
                for _, species in ipairs(Config.species) do if (data.collection[species.id] or 0) > 0 then count += 1 end end
                return count
            end)(), target = #Config.species}})
    player:SetAttribute("Coins", data.coins)
    player:SetAttribute("BagCount", #data.bag)
    player:SetAttribute("Harvested", data.harvested)
    player:SetAttribute("PlotId", session.plot.id)
    player:SetAttribute("SelectedSpecies", data.selected)
    local leaderstats = player:FindFirstChild("leaderstats")
    if leaderstats then leaderstats.Moedas.Value = data.coins; leaderstats.Colheitas.Value = data.harvested end
end
local function mutation()
    local roll = rng:NextNumber()
    if roll < 0.025 then return "golden" end
    if weatherIndex == 3 and roll < 0.50 then return "aurora" end
    if weatherIndex == 2 and roll < 0.65 then return "dewy" end
    return "normal"
end
local function updateBed(session, slot)
    local plant = session.profile.data.beds[tostring(slot)]
    local bed = session.plot.beds[slot]
    World.setBed(session.plot, slot, plant, Config)
    local prompt = bed:FindFirstChild("GardenPrompt")
    if prompt then
        if not plant then prompt.ActionText = "Plantar"; prompt.ObjectText = "Canteiro " .. slot
        elseif clock() >= plant.readyAt then prompt.ActionText = "Colher"; prompt.ObjectText = "+" .. plant.value .. " moedas"
        else prompt.ActionText = "Crescendo · " .. math.ceil(plant.readyAt - clock()) .. "s"; prompt.ObjectText = "Cristal" end
    end
end
local function bedAction(player, plot, slot)
    local session = sessions[player]
    if not session or not session.profile.active then return end
    if session.plot ~= plot then toast(player, "Este jardim pertence a outro jogador."); return end
    if not near(player, plot.beds[slot].Position, Config.interactionDistance) or not allow(session, 0.15) then return end
    local data = session.profile.data
    local key = tostring(slot)
    local plant = data.beds[key]
    if plant then
        local ok, reason = Economy.harvest(data, plant, clock(), Config)
        if not ok then toast(player, reason, "warning"); return end
        data.beds[key] = nil
        toast(player, "Cristal colhido! Leve ao mercado.", "success")
    else
        local created, reason = Economy.plant(data, data.selected, clock(), mutation(), Config)
        if not created then toast(player, reason, "warning"); return end
        data.beds[key] = created
    end
    checkGoals(player, data)
    updateBed(session, slot)
    push(player)
end
local function sell(player)
    local session = sessions[player]
    if not session or not session.profile.active then return end
    if not near(player, world.market.Position, Config.interactionDistance + 4) then
        toast(player, "Vá até o mercado para vender.", "warning"); return
    end
    local amount = Economy.sell(session.profile.data, Config)
    if amount == 0 then toast(player, "Sua mochila está vazia."); return end
    toast(player, "Venda concluída! +" .. amount .. " moedas", "success")
    checkGoals(player, session.profile.data)
    push(player)
end
local function join(player)
    if sessions[player] then return end
    local plot
    for _, candidate in ipairs(world.plots) do
        if not candidate.owner then plot = candidate; break end
    end
    if not plot then player:Kick("Todos os jardins estão ocupados. Entre em outro servidor."); return end
    plot.owner = player
    local profile = store:load(player)
    if not profile then
        plot.owner = nil
        player:Kick("Não foi possível carregar seu jardim com segurança. Tente novamente.")
        return
    end
    if not player.Parent then plot.owner = nil; store:release(player); return end
    if not Economy.validate(profile.data, Config) then
        plot.owner = nil
        -- No reset/save of a damaged profile: preserve the original for recovery.
        profile.active = false
        player:Kick("Seu jardim precisa de recuperação. O progresso foi preservado; procure o suporte.")
        return
    end
    local stats = store:statistics()
    local session = {plot = plot, profile = profile, lastAction = -10,
        saveMode = if stats.persistent then "cloud" else "session"}
    sessions[player] = session
    World.setOwner(plot, player)
    local board = Instance.new("Folder"); board.Name = "leaderstats"; board.Parent = player
    for _, name in ipairs({"Moedas", "Colheitas"}) do
        local stat = Instance.new("IntValue"); stat.Name = name; stat.Parent = board
    end
    local function placeCharacter(character)
        local root = character:WaitForChild("HumanoidRootPart", 10)
        if root and sessions[player] then
            character:PivotTo(plot.spawn)
            local humanoid = character:FindFirstChildOfClass("Humanoid")
            if humanoid then humanoid.WalkSpeed = 20 end
        end
    end
    session.characterConnection = player.CharacterAdded:Connect(placeCharacter)
    if player.Character then task.spawn(placeCharacter, player.Character) end
    for slot = 1, Config.bedCount do updateBed(session, slot) end
    push(player)
end
function Garden.start()
    assert(not started, "Garden already started")
    started = true
    world = World.build(Config)
    local net = Instance.new("Folder"); net.Name = "GardenNet"; net.Parent = ReplicatedStorage
    local action = Instance.new("RemoteEvent"); action.Name = "Action"; action.Parent = net
    stateRemote = Instance.new("RemoteEvent"); stateRemote.Name = "State"; stateRemote.Parent = net
    toastRemote = Instance.new("RemoteEvent"); toastRemote.Name = "Toast"; toastRemote.Parent = net
    store = Save.store("CrystalGarden_v1", Economy.new(Config))
    weatherEnd = clock() + Config.weatherSeconds
    for _, plot in ipairs(world.plots) do
        for slot, bed in ipairs(plot.beds) do
            local prompt = bed:FindFirstChild("GardenPrompt") or Instance.new("ProximityPrompt")
            prompt.Name = "GardenPrompt"; prompt.ActionText = "Plantar"; prompt.ObjectText = "Canteiro " .. slot
            prompt.RequiresLineOfSight = false; prompt.MaxActivationDistance = 8
            prompt.HoldDuration = 0.15; prompt.Exclusivity = Enum.ProximityPromptExclusivity.OneGlobally
            prompt.Parent = bed
            prompt.Triggered:Connect(function(player) bedAction(player, plot, slot) end)
        end
    end
    local marketPrompt = world.market:FindFirstChild("SellPrompt") or Instance.new("ProximityPrompt")
    marketPrompt.Name = "SellPrompt"; marketPrompt.ActionText = "Vender mochila"; marketPrompt.ObjectText = "Mercado de cristais"
    marketPrompt.MaxActivationDistance = 12; marketPrompt.RequiresLineOfSight = false
    marketPrompt.KeyboardKeyCode = Enum.KeyCode.F; marketPrompt.Parent = world.market
    marketPrompt.Triggered:Connect(function(player)
        local session = sessions[player]
        if session and allow(session, 0.15) then sell(player) end
    end)
    action.OnServerEvent:Connect(function(player, verb, id)
        if type(verb) ~= "string" or #verb > 24 or (id ~= nil and (type(id) ~= "string" or #id > 32)) then return end
        local session = sessions[player]
        if not session or not session.profile.active or not allow(session, 0.12) then return end
        local data = session.profile.data
        if verb == "sync" then push(player); return
        elseif verb == "sell" then sell(player); return
        elseif verb == "select" then
            if not id or not data.unlocked[id] then return end
            data.selected = id
        elseif verb == "unlock" or verb == "upgrade" then
            local ok, reason
            if verb == "unlock" then ok, reason = Economy.unlock(data, id, Config)
            else ok, reason = Economy.upgrade(data, id, Config) end
            if not ok then toast(player, reason, "warning"); return end
            toast(player, if verb == "unlock" then "Nova espécie desbloqueada!" else "Melhoria comprada!", "success")
        elseif verb == "harvestAll" then
            if not near(player, session.plot.origin, 32) then toast(player, "Volte ao seu jardim.", "warning"); return end
            local count = 0
            for slot = 1, Config.bedCount do
                local plant = data.beds[tostring(slot)]
                if plant and near(player, session.plot.beds[slot].Position, Config.interactionDistance) then
                    local ok = Economy.harvest(data, plant, clock(), Config)
                    if ok then data.beds[tostring(slot)] = nil; count += 1; updateBed(session, slot) end
                end
            end
            if count == 0 then toast(player, "Aproxime-se dos cristais prontos; confira sua mochila.", "warning")
            else toast(player, count .. " cristais colhidos!", "success") end
        else return end
        checkGoals(player, data)
        push(player)
    end)
    Players.PlayerAdded:Connect(function(player) task.spawn(join, player) end)
    Players.PlayerRemoving:Connect(function(player)
        local session = sessions[player]
        if not session then return end
        sessions[player] = nil
        if session.characterConnection then session.characterConnection:Disconnect() end
        session.plot.owner = nil
        World.setOwner(session.plot, nil)
        for slot = 1, Config.bedCount do World.setBed(session.plot, slot, nil, Config) end
    end)
    for _, player in ipairs(Players:GetPlayers()) do task.spawn(join, player) end
    task.spawn(function()
        while started do
            task.wait(1)
            if clock() >= weatherEnd then
                weatherIndex = weatherIndex % #Config.weathers + 1
                weatherEnd = clock() + Config.weatherSeconds
                if World.setWeather then World.setWeather(weather()) end
                for player in pairs(sessions) do toast(player, "O clima mudou: " .. weather().name, "info") end
            end
            for player, session in pairs(sessions) do
                if not session.profile.active then
                    player:Kick("A conexão com seu jardim foi interrompida. Entre novamente para proteger seu progresso.")
                else
                    for slot = 1, Config.bedCount do updateBed(session, slot) end
                    push(player)
                end
            end
        end
    end)
    workspace:SetAttribute("GardenReady", true)
    workspace:SetAttribute("GardenProduct", "crystal-garden")
end
return Garden
