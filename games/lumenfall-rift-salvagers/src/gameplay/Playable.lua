--!strict
-- Expedition state: resource risk, boss gate, extraction defence and permanent upgrades.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Data = Forge.Data
local Save = Forge.Save
local Net = Forge.Net
local Debug = Forge.Debug

local Config = require(ReplicatedStorage.Shared.Config)

local Expedition = {}
local World = nil
local Gameplay = nil
local extractionActive = false
local bossAlive: Model? = nil

local function sync(player: Player)
    local profile=Save.get(player)
    local saveStatus=Save.status(player)
    local refined=profile and tonumber(profile.refined) or 0
    local power=profile and tonumber(profile.power) or 0
    local bestDepth=profile and tonumber(profile.bestDepth) or 0
    local joinCount=profile and tonumber(profile.joinCount) or 0
    player:SetAttribute("RefinedLumen",refined)
    player:SetAttribute("PowerUpgrade",power)
    player:SetAttribute("BestDepth",bestDepth)
    player:SetAttribute("ProfileJoinCount",joinCount)
    player:SetAttribute("ProfileOnboarded",profile~=nil and profile.onboarded==true)
    player:SetAttribute("SavePersistent",saveStatus.persistent==true)
    player:SetAttribute("SaveMemoryOnly",saveStatus.memoryOnly==true)
    Net.fire(player,"State",{
        carried=player:GetAttribute("CarriedLumen") or 0,
        refined=refined,
        power=power,
        bestDepth=bestDepth,
        bossDefeated=player:GetAttribute("BossDefeated")==true,
        objective=player:GetAttribute("Objective") or "",
    })
end

local function objective(player: Player, text: string)
    player:SetAttribute("Objective",text)
    Net.fire(player,"Objective",{text=text})
end

local function addCarried(player: Player, amount: number, reason: string)
    local current=tonumber(player:GetAttribute("CarriedLumen")) or 0
    local nextValue=math.max(0,current+amount)
    player:SetAttribute("CarriedLumen",nextValue)
    Net.fire(player,"Lumen",{amount=amount,total=nextValue,reason=reason})
    sync(player)
end

local function spawnInitialEnemies()
    for i,p in ipairs(World.enemySpawns.reach) do
        Gameplay.spawnEnemy(i==3 and "sentinel" or "skitter",p)
    end
    for i,p in ipairs(World.enemySpawns.foundry) do
        Gameplay.spawnEnemy(i%3==0 and "bulwark" or (i%2==0 and "sentinel" or "skitter"),p)
    end
    for i,p in ipairs(World.enemySpawns.crown) do
        Gameplay.spawnEnemy(i==1 and "warden" or "sentinel",p)
    end
end

local function connectNodes()
    for _,crystal in World.lumenNodes do
        local prompt=crystal:FindFirstChildOfClass("ProximityPrompt")
        if prompt then
            prompt.Triggered:Connect(function(player)
                if crystal:GetAttribute("Available")~=true then return end
                crystal:SetAttribute("Available",false)
                prompt.Enabled=false
                crystal.Transparency=0.82
                local value=tonumber(crystal:GetAttribute("LumenValue")) or 5
                addCarried(player,value,"harvest")
                objective(player,"Push deeper. Defeat the Hollow Engine, then extract.")
                task.delay(35,function()
                    if crystal.Parent then
                        crystal:SetAttribute("Available",true)
                        crystal.Transparency=0
                        prompt.Enabled=true
                    end
                end)
            end)
        end
    end
end

local function connectBoons()
    for _,entry in World.boonPrompts do
        local prompt=entry.prompt :: ProximityPrompt
        prompt.Triggered:Connect(function(player)
            if player:GetAttribute("RunBoon")~="" and player:GetAttribute("RunBoon")~=nil then
                Net.fire(player,"Notify",{text="A run boon is already locked in.",kind="warn"})
                return
            end
            local cost=tonumber(entry.cost) or 8
            local carried=tonumber(player:GetAttribute("CarriedLumen")) or 0
            if carried<cost then
                Net.fire(player,"Notify",{text=("Need %d unstable Lumen for this boon"):format(cost),kind="warn"})
                return
            end
            addCarried(player,-cost,"boon")
            local id=tostring(entry.id)
            player:SetAttribute("RunBoon",id)
            if id=="overcharge" then
                player:SetAttribute("RunPowerMultiplier",1.20)
                objective(player,"OVERCHARGE LOCKED. Push deeper and break the Hollow Engine.")
            elseif id=="phase-step" then
                player:SetAttribute("RunDashCooldownScale",0.72)
                objective(player,"PHASE STEP LOCKED. Push deeper and break the Hollow Engine.")
            end
            Net.fire(player,"Notify",{text="Temporary run boon unlocked: "..id,kind="good"})
            sync(player)
        end)
    end
end

local function upgrade(player: Player)
    local profile=Save.get(player)
    if not profile then return end
    local level=tonumber(profile.power) or 0
    local cost=Config.economy.upgradeBase+level*12
    local refined=tonumber(profile.refined) or 0
    if refined<cost then
        Net.fire(player,"Notify",{text=("Need %d Refined Lumen"):format(cost),kind="warn"})
        return
    end
    profile.refined=refined-cost
    profile.power=level+1
    player:SetAttribute("PowerUpgrade",profile.power)
    Net.fire(player,"Notify",{text=("Forge tuned: power level %d"):format(profile.power),kind="good"})
    sync(player)
end

local function startBoss(player: Player)
    if bossAlive and bossAlive.Parent then
        objective(player,"The Hollow Engine is already awake.")
        return
    end
    player:SetAttribute("BossDefeated",false)
    objective(player,"BREAK THE HOLLOW ENGINE — strike during exposed-core windows.")
    player:SetAttribute("Checkpoint",World.bossCheckpoint)
    bossAlive=Gameplay.spawnBoss(World.bossPosition)
    local spawnedBoss=bossAlive
    spawnedBoss.AncestryChanged:Connect(function(_child,parent)
        if parent~=nil or bossAlive~=spawnedBoss then return end
        bossAlive=nil
        if player.Parent and player:GetAttribute("BossDefeated")~=true then
            World.bossPrompt.Enabled=true
            objective(player,"The Hollow Engine fell into the rift. Awaken it again.")
            Net.fireAll("Boss",{active=false,aborted=true})
        end
    end)
    World.bossPrompt.Enabled=false
    Net.fireAll("Boss",{active=true,name="THE HOLLOW ENGINE"})
end

local function spawnDefenceWave(round: number)
    local positions=World.enemySpawns.crown
    for i,p in ipairs(positions) do
        local id=if round>=3 and i==1 then "warden" elseif (round+i)%3==0 then "bulwark" elseif i%2==0 then "sentinel" else "skitter"
        Gameplay.spawnEnemy(id,p+Vector3.new((round-2)*4,0,round*3))
    end
end

local function beginExtraction(player: Player)
    if extractionActive then
        Net.fire(player,"Notify",{text="Beacon already charging",kind="warn"})
        return
    end
    if player:GetAttribute("BossDefeated")~=true then
        objective(player,"The Hollow Engine blocks the rift. Defeat it first.")
        return
    end
    extractionActive=true
    World.extractionPrompt.Enabled=false
    player:SetAttribute("ExtractionActive",true)
    objective(player,"HOLD THE BEACON — survive until the rift stabilizes.")

    task.spawn(function()
        local total=Config.economy.extractionSeconds
        for second=total,1,-1 do
            if not player.Parent then break end
            player:SetAttribute("ExtractionSeconds",second)
            Net.fire(player,"Extraction",{active=true,seconds=second,total=total})
            if second==total or second==math.floor(total*0.65) or second==math.floor(total*0.32) then
                local round=if second==total then 1 elseif second>total*0.4 then 2 else 3
                spawnDefenceWave(round)
            end
            task.wait(1)
        end
        if player.Parent and player.Character and player.Character:FindFirstChildOfClass("Humanoid")
            and (player.Character:FindFirstChildOfClass("Humanoid") :: Humanoid).Health>0 then
            local carried=tonumber(player:GetAttribute("CarriedLumen")) or 0
            local profile=Save.get(player)
            if profile then
                local receipt=("%d:%d:%d"):format(player.UserId,math.floor(os.clock()*1000),carried)
                if profile.lastExtraction~=receipt then
                    profile.lastExtraction=receipt
                    profile.refined=(tonumber(profile.refined) or 0)+carried+12
                    profile.bestDepth=math.max(tonumber(profile.bestDepth) or 0,3)
                end
            end
            player:SetAttribute("CarriedLumen",0)
            player:SetAttribute("Checkpoint",World.spawnPoint)
            player:SetAttribute("ExtractionActive",false)
            player:SetAttribute("ExtractionSeconds",0)
            objective(player,"EXTRACTED. Return to the forge or dive again.")
            Net.fire(player,"Extraction",{active=false,success=true,seconds=0,total=total})
            Net.fire(player,"Notify",{text="Extraction secured — Lumen refined",kind="good"})
            sync(player)
        end
        extractionActive=false
        if World.extractionPrompt then World.extractionPrompt.Enabled=true end
    end)
end

local function attachPlayer(player: Player)
    player:SetAttribute("CarriedLumen",0)
    player:SetAttribute("BossDefeated",false)
    player:SetAttribute("ExtractionActive",false)
    player:SetAttribute("CombatHitCount",0)
    player:SetAttribute("CombatDamageDealt",0)
    player:SetAttribute("LastCombatTarget","")
    player:SetAttribute("RunBoon","")
    player:SetAttribute("RunPowerMultiplier",1)
    player:SetAttribute("RunDashCooldownScale",1)
    objective(player,"Cross the rift bridges. Harvest Lumen and reach Storm Crown.")
    local profile=Save.get(player)
    if profile then
        profile.joinCount=(tonumber(profile.joinCount) or 0)+1
        if profile.onboarded~=true then
            profile.onboarded=true
            Net.fire(player,"Notify",{text="Harvest gold Lumen. Dodge telegraphs. Orange core = boss vulnerable.",kind="info"})
        end
    end
    sync(player)
end

function Expedition.start(worldModule, gameplayModule)
    World,Gameplay=worldModule,gameplayModule
    connectNodes()
    connectBoons()
    spawnInitialEnemies()

    if World.upgradePrompt then World.upgradePrompt.Triggered:Connect(upgrade) end
    if World.bossPrompt then World.bossPrompt.Triggered:Connect(startBoss) end
    if World.extractionPrompt then World.extractionPrompt.Triggered:Connect(beginExtraction) end

    Gameplay.onEnemyKilled(function(_model,source,id)
        if typeof(source)=="Instance" and source:IsA("Player") then
            local def=Data.get("enemy",id)
            addCarried(source,def and def.reward or 3,"enemy")
            if id=="hollow_engine" then
                source:SetAttribute("BossDefeated",true)
                objective(source,"CORE SHATTERED. Activate the extraction beacon.")
                Net.fireAll("Boss",{active=false,defeated=true})
                if World.bossPrompt then World.bossPrompt.Enabled=true end
                bossAlive=nil
            end
        end
    end)

    Save.observe(function(player,_profile)
        attachPlayer(player)
    end)

    Players.PlayerRemoving:Connect(function(player)
        local profile=Save.get(player)
        if profile then
            profile.bestDepth=math.max(tonumber(profile.bestDepth) or 0,tonumber(player:GetAttribute("Depth")) or 0)
        end
    end)

    Debug.probe("lumenfall.state",function()
        local alive=0
        local actors=workspace:FindFirstChild("Actors")
        if actors then
            for _,child in actors:GetChildren() do
                if child:IsA("Model") and child:GetAttribute("EnemyId")~=nil then alive+=1 end
            end
        end
        return {enemies=alive,extractionActive=extractionActive,bossAlive=bossAlive~=nil and bossAlive.Parent~=nil}
    end)
end

function Expedition.onDeath(player: Player)
    local carried=tonumber(player:GetAttribute("CarriedLumen")) or 0
    local kept=math.floor(carried*Config.economy.failureKeepRatio)
    player:SetAttribute("CarriedLumen",kept)
    player:SetAttribute("ExtractionActive",false)
    objective(player,("Rift collapse. %d unstable Lumen recovered."):format(kept))
    sync(player)
end

return Expedition
