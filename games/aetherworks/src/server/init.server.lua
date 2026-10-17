local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Forge = require(RS.Forge)
local C = require(RS.Shared.TycoonConfig)
local World = require(script.World)
local Tower = require(script.Tower)
local Rewards = require(script.Rewards)
local Dominion=require(script.Dominion)
local Progression=require(script.Progression)
local Discovery=require(script.Discovery)
local Analytics=require(script.Analytics)
local Habitat=require(script.Habitat)
local Net, Save, Tycoon, Balance = Forge.Net, Forge.Save, Forge.Tycoon, Forge.Economy.Balance
local Telemetry = Forge.Telemetry
local states = {}
local allocator = Tycoon.PlotAllocator.new(C.plotIds)
local startedAt = os.clock()
local surgeStart = 0
local community = 0
Players.CharacterAutoLoads = false
World.build()

Net.define(C.net)

local function surge()
    return os.clock()-surgeStart<40 and surgeStart>0
end
local function feedback(player,text,kind,position)
    Net.fire(player,"Feedback",{text=text,kind=kind or "info",position=position})
end
local function active(player)
    local state=states[player]
    if not state or Save.get(player)~=state.profile then return nil end
    return state
end
local function nearby(player,position,distance)
    local char=player.Character
    local root=char and char:FindFirstChild("HumanoidRootPart")
    local hum=char and char:FindFirstChildOfClass("Humanoid")
    return root and hum and hum.Health>0 and (root.Position-position).Magnitude<=distance
end
local function credit(profile,amount)
    if amount<=0 or amount~=amount then return end
    profile.coins=math.min(1e150,profile.coins+amount)
    profile.earned=math.min(1e150,profile.earned+amount)
end
local function spend(profile,amount)
    local wallet=Balance.new({currencies={coins={start=profile.coins}}})
    if not wallet:canAfford({coins=amount}) then return false end
    wallet:debit({coins=amount});profile.coins=wallet:get("coins");return true
end
local function contracts(player,state)
    local profile=state.profile
    local contract=C.contracts[profile.contract]
    while contract and (profile[contract.stat] or 0)>=contract.goal do
        credit(profile,contract.reward)
        profile.contract+=1
        feedback(player,"Contrato completo! +"..C.format(contract.reward),"contract")
        Telemetry.event("contract.completed",{contract=profile.contract-1})
        contract=C.contracts[profile.contract]
    end
end
local function sync(player)
    local state=active(player);if not state then return end
    local p=state.profile
    local contract=C.contracts[p.contract]
    local rate=C.rate(p.level,p.stars,p.research,p.machineLevels,p.legacy)*Discovery.multiplier(p)*Habitat.bonuses(p).production*Dominion.multiplier(player)*(if surge() then 2 else 1)*(if os.time()<(p.overdriveUntil or 0) then 3 else 1)
    Net.fire(player,"StateSync",{
        coins=math.floor(p.coins),bank=math.floor(p.bank),level=p.level,stars=p.stars,
        earned=math.floor(p.earned),rate=rate,rewards=Rewards.snapshot(p),plotId=state.plot.id,plotCFrame=state.plot.cf,collectorPosition=state.plot.bank.Position,
        legacy=p.legacy,towerResearch=p.towerResearch,armyOrder=p.armyOrder,
        discovery=Discovery.snapshot(p),habitat=Habitat.snapshot(p),armyLoadout=p.armyLoadout,armyRoute=p.armyRoute,armyPriority=p.armyPriority,
        machineLevels=p.machineLevels,dominion=Dominion.inspect(player),armyLevel=p.armyLevel,armyTactic=p.armyTactic,weaponMastery=p.weaponMastery,armorMastery=p.armorMastery,
        cores=p.cores,perks=p.perks,overdriveReadyAt=p.overdriveReadyAt,overdriveRemaining=math.max(0,p.overdriveUntil-os.time()),serverTime=os.time(),
        weapon=p.weapon,armor=p.armor,relics=p.relics,research=p.research,towerWins=p.towerWins,bestWave=p.bestWave,tower=Tower.inspect(player),
        nextUpgrade=p.level+1,contract=p.contract,contractProgress=if contract then math.min(p[contract.stat] or 0,contract.goal) else 0,
        surge=surge(),surgeRemaining=if surge() then math.max(0,40-(os.clock()-surgeStart)) else 0,
        surgeIn=math.max(0,240-(os.clock()-startedAt)%240),community=community,
        dailyReady=p.lastDailyDay~=math.floor(os.time()/86400),persistent=Save.status(player).persistent,
    })
    player:SetAttribute("Coins",math.floor(p.coins));player:SetAttribute("FactoryLevel",p.level)
    player:SetAttribute("PetFloors",p.habitat.floors);player:SetAttribute("PetCapacity",Habitat.snapshot(p).capacity)
    player:SetAttribute("PetProductionMultiplier",Habitat.bonuses(p).production);player:SetAttribute("PetManualMultiplier",Habitat.bonuses(p).manual)
    player:SetAttribute("Bank",math.floor(p.bank));player:SetAttribute("IncomePerSecond",rate)
    state.plot.bankLabel.Text="¤ "..C.format(p.bank)
end
local function collect(player)
    local s=active(player);if not s then return end
    if not nearby(player,s.plot.bank.Position,15) then feedback(player,"Aproxime-se do coletor na sua ilha.","error");return end
    local amount=math.floor(s.profile.bank)
    if amount<1 then feedback(player,"Seus cristais estão a caminho.");return end
    s.profile.bank-=amount;credit(s.profile,amount);s.profile.collections+=1
    contracts(player,s);feedback(player,"+"..C.format(amount).." coroas","collect",s.plot.bank.Position);sync(player)
end
local function mine(player)
    local s=active(player);if not s then return end
    if not nearby(player,s.plot.mine.Position,15) then feedback(player,"Extraia no veio de cristais da sua ilha.","error");return end
    local now=os.clock();if now-(s.lastMine or 0)<.75 then return end;s.lastMine=now;s.lastActive=now
    local reward=8+math.floor(C.rate(s.profile.level,s.profile.stars,s.profile.research,s.profile.machineLevels,s.profile.legacy)*.04)
    reward=math.floor(reward*Habitat.bonuses(s.profile).manual)
    credit(s.profile,reward);s.profile.mined+=1;community+=1
    Discovery.progress(s.profile,"mine",1)
    Analytics.step(player,2,"FirstCrystal")
    if community>=30 and not surge() then
        community=0;surgeStart=now
        Net.fireAll("Feedback",{text="AURORA ATIVA · produção em dobro por 40s!",kind="contract"})
    end
    contracts(player,s);feedback(player,"+"..C.format(reward),"mine",s.plot.mine.Position);sync(player)
end
local function buy(player,id)
    local s=active(player);if not s then return end
    s.lastActive=os.clock()
    local p=s.profile;local u=C.upgrades[p.level+1]
    if not u or u.id~=id then feedback(player,"Construa a próxima melhoria da sequência.","error");return end
    if p.stars<(u.rebirth or 0) then feedback(player,"Esta construção exige renascimento "..u.rebirth..".","error");return end
    local price=C.price(u,p.stars)
    local r=player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    local at=r and s.plot.cf:PointToObjectSpace(r.Position)
    if not at or math.abs(at.X)>55 or at.Z< -55 or at.Z>262 or at.Y< -5 or at.Y>135 then feedback(player,"Volte à sua ilha para construir.","error");return end
    if not spend(p,price) then feedback(player,"Faltam "..C.format(price-p.coins).." coroas.","error");return end
    p.level+=1
    if p.level==1 then Analytics.step(player,3,"FirstMachine")elseif p.level==5 then Analytics.step(player,4,"TowerUnlocked")end
    if u.autoCollect and p.bank>=1 then
        local delivery=math.floor(p.bank);p.bank-=delivery;credit(p,delivery);p.collections+=1
    end
    World.update(s.plot,p.level,player.DisplayName,p.stars);World.updateCrystals(s.plot,p.machineLevels)
    Discovery.discover(p);World.decorate(s.plot,p)
    contracts(player,s)
    feedback(player,u.name.." construída!","build",s.plot.cf*Vector3.new(u.x,(u.y or 0)+3,u.z))
    Telemetry.event("factory.upgraded",{level=p.level,upgrade=u.id})
    sync(player)
end
Net.on("MachineUpgrade",function(player,payload)
    local s=active(player);if not s then return end
    local p=s.profile;local index
    for i,u in C.upgrades do if u.id==payload.id then index=i;break end end
    if not index or index>p.level or not C.isMachine(C.upgrades[index]) then feedback(player,"Selecione uma máquina já construída.","error");return end
    if payload.count~=1 and payload.count~=10 then return end
    local r=player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    local at=r and s.plot.cf:PointToObjectSpace(r.Position)
    if not at or math.abs(at.X)>55 or at.Z< -55 or at.Z>262 or at.Y< -5 or at.Y>135 then feedback(player,"Melhore as máquinas dentro da sua ilha.","error");return end
    local u=C.upgrades[index];local price=C.machinePrice(u,p.machineLevels,p.stars,payload.count)
    if not spend(p,price) then feedback(player,"Faltam "..C.format(price-p.coins).." coroas para a melhoria.","error");return end
    p.machineLevels[u.id]=(p.machineLevels[u.id] or 0)+payload.count
    World.updateCrystals(s.plot,p.machineLevels)
    Discovery.discover(p);World.decorate(s.plot,p)
    local rank=C.machineLevel(p.machineLevels,u.id);local tier=C.crystal(rank)
    feedback(player,u.name.." · nível "..rank.." · "..tier.name,"build",s.plot.cf*Vector3.new(u.x,(u.y or 0)+4,u.z));sync(player)
end)
local function home(player)
    if Tower.inspect(player).active then feedback(player,"Use SAIR DA TORRE para encerrar a expedição.","error");return end
    local s=active(player);if not s then return end
    if os.clock()-(s.lastHome or 0)<3 then return end;s.lastHome=os.clock()
    if player.Character then player.Character:PivotTo(s.plot.cf*CFrame.new(0,4,-34)*CFrame.Angles(0,math.pi,0)) end
end
Net.on("Ready",function(player) sync(player) end)
Net.on("Buy",function(player,payload) buy(player,payload.id) end)
Net.on("Collect",collect);Net.on("Mine",mine);Net.on("Home",home)
Net.on("Legacy",function(player,payload)
    local s=active(player);if not s then return end
    local p=s.profile;local perk=C.perks[payload.perk]
    if not perk or p.perks[payload.perk] then return end
    if p.stars<perk.rebirth then feedback(player,"Desbloqueia no renascimento "..perk.rebirth..".","error");return end
    if p.cores<perk.cores then feedback(player,"Você precisa de "..perk.cores.." núcleos de renascimento.","error");return end
    p.cores-=perk.cores;p.perks[payload.perk]=true
    feedback(player,perk.name.." desbloqueado para sempre!","contract");sync(player)
end)
local function overdrive(player)
    local s=active(player);if not s then return end
    local p=s.profile
    if not p.perks.overdrive or os.time()<p.overdriveReadyAt then return end
    p.overdriveUntil=os.time()+30;p.overdriveReadyAt=os.time()+180
    feedback(player,"SOBRECARGA · produção triplicada por 30s!","contract");sync(player)
end
Net.on("Overdrive",overdrive)
World.onBoost=function(player,plot,position)
    local s=active(player);if not s or s.plot~=plot or not nearby(player,position,12)then return end
    if not s.profile.perks.overdrive then feedback(player,"Desbloqueie Sobrecarga no Legado, após renascimento 3.","error");return end
    if os.time()<s.profile.overdriveReadyAt then feedback(player,"Reator recarregando: "..(s.profile.overdriveReadyAt-os.time()).."s.");return end
    overdrive(player)
end
Net.on("Rebirth",function(player)
    local s=active(player);if not s then return end
    local p=s.profile
    if Tower.inspect(player).active then feedback(player,"Encerre a expedição antes de renascer.","error");return end
    local cost=C.prestigePrice(p.stars)
    if p.level<C.requiredLevel(p.stars) or p.coins<cost then feedback(player,"Complete "..C.requiredLevel(p.stars).." construções e junte "..C.format(cost).." coroas.","error");return end
    p.machineLevels={};p.cores+=1+p.stars;p.stars+=1;p.level=0;p.coins=C.startingCoins;p.bank=0;p.mined=0;p.collections=0;p.contract=1
    World.update(s.plot,0,player.DisplayName,p.stars);World.updateCrystals(s.plot,{});s.lastHome=nil;home(player)
    feedback(player,"NOVO HORIZONTE · +20% de produção permanente!","contract")
    Telemetry.event("factory.prestige",{stars=p.stars});Analytics.event(player,"Rebirth",p.stars);sync(player)
end)

Dominion.start({active=active,credit=credit,spend=spend,feedback=feedback,sync=sync})
Tower.start({active=active,credit=credit,spend=spend,feedback=feedback,sync=sync})
Rewards.start({active=active,credit=credit,feedback=feedback,sync=sync})
Progression.start({active=active,feedback=feedback,sync=sync,equip=Tower.equip,towerActive=function(player) return Tower.inspect(player).active end})
Discovery.start({active=active,feedback=feedback,sync=sync,equip=Tower.equip,decorate=World.decorate,towerActive=function(player) return Tower.inspect(player).active end})
Habitat.start({active=active,nearby=nearby,feedback=feedback,sync=sync,render=World.updateHabitat,towerActive=function(player)return Tower.inspect(player).active end})
World.onHabitat=function(player,plot,position)
    local s=active(player);if not s or s.plot~=plot or not nearby(player,position,14)then return end
    sync(player);Net.fire(player,"OpenHabitat",{})
end
World.onHabitatLift=function(player,plot,position,target)
    local s=active(player);if not s or s.plot~=plot or not nearby(player,position,9)then return end
    if target<1 or target*2>Habitat.snapshot(s.profile).capacity then return end
    player.Character:PivotTo(plot.habitatCF*CFrame.new(11,(target-1)*12+4,2))
end
World.onElevator=function(player,plot,from,destination)
    local s=active(player)
    if not s or s.plot~=plot or not nearby(player,from,11) then return end
    local y=plot.cf:PointToObjectSpace(destination.Position).Y
    local top=0
    for index=1,s.profile.level do local u=C.upgrades[index];if u.kind=="floor" then top=math.max(top,u.y) end end
    if y>top+6 then return end
    player.Character:PivotTo(destination)
end
for _,plot in World.plots do
    plot.prompt.Triggered:Connect(function(player)
        local s=active(player)
        if not s or s.plot~=plot then feedback(player,"Essa fábrica pertence a outro explorador.","error");return end
        if not nearby(player,plot.pad.Position,14) then return end
        local u=C.upgrades[s.profile.level+1];if u then buy(player,u.id) end
    end)
    for _,entry in {{plot.mine,"Extrair cristal",mine},{plot.bank,"Recolher coroas",collect}} do
        local prompt=Instance.new("ProximityPrompt");prompt.ActionText=entry[2];prompt.ObjectText=if entry[1]==plot.mine then "Veio de aether" else "Produção da ilha"
        prompt.MaxActivationDistance=12;prompt.HoldDuration=.12;prompt.RequiresLineOfSight=false;prompt.Parent=entry[1]
        prompt.Triggered:Connect(function(player)
            local s=active(player);if s and s.plot==plot then entry[3](player) end
        end)
    end
    World.update(plot,0,nil)
end

Save.configure({store=C.saveStore,version=1,autosaveInterval=45,template={coins=C.startingCoins,bank=0,level=0,stars=0,earned=0,mined=0,collections=0,contract=1,lastAt=0,lastDaily=0,weapon=1,armor=1,relics=0,research=0,towerWins=0,cores=0,perks={},overdriveUntil=0,overdriveReadyAt=0,totalPlaySeconds=0,dayPlaySeconds=0,playDay=-1,timeClaims={},daysPlayed=0,lastVisitDay=-1,lastDailyDay=-1,dailyClaims=0,bestWave=0,machineLevels={},armyLevel=0,armyTactic="balanced",armyOrder="advance",legacy={},towerResearch={},visitClaims={},dailyStreak=0,bestStreak=0,weaponMastery=0,armorMastery=0}})
Save.onFailed:Connect(function(player,reason)
    warn("[Aetherworks] save refused: "..tostring(reason))
    if not Save.get(player) and player.Parent then player:Kick("Não foi possível abrir seu progresso com segurança. Tente entrar novamente.") end
end)
Save.onSaving:Connect(function(_,profile) profile.lastAt=os.time() end)
Save.start()
Save.observe(function(player,profile)
    if states[player] then return end
    -- Native Studio integration fixture, never a client command or a live
    -- experience option. Lets visual QA inspect the completed construction.
    if RunService:IsStudio() and not Save.status(player).persistent then
        local ok,args=pcall(function() return game:GetService("StudioTestService"):GetTestArgs() end)
        if ok and type(args)=="table" and type(args.data)=="table" and args.data.game=="aetherworks" and (args.data.profileMode=="completed-factory" or args.data.profileMode=="battle-lab") then
            profile.level=#C.upgrades;profile.coins=20000000;profile.contract=#C.contracts+1;profile.stars=5;profile.cores=30
            if args.data.profileMode=="battle-lab" then
                profile.armyLevel=if player.UserId%2==0 then 4 else 5
                profile.weapon=#C.weapons;profile.armor=#C.armors;profile.relics=50
                profile.machineLevels={extractor=74,polisher=34,furnace=14,garden=4}
            end
        end
    end
    local id=allocator:assign(tostring(player.UserId))
    if not id then player:Kick("As quatro ilhas estão ocupadas. Entre em outro servidor.");return end
    local plot=World.plots[id]
    states[player]={profile=profile,plot=plot,lastActive=os.clock()}
    Habitat.prepare(profile)
    Discovery.discover(profile)
    Analytics.step(player,1,"JoinedIsland")
    profile.armyLoadout=profile.armyLoadout or {};profile.armyRoute=profile.armyRoute or "center";profile.armyPriority=profile.armyPriority or "nearest"
    if profile.lastDaily>0 and profile.dailyClaims==0 then profile.lastDailyDay=math.floor(profile.lastDaily/86400);profile.dailyClaims=1 end
    Rewards.step(profile,0)
    local away=math.clamp(os.time()-(profile.lastAt or os.time()),0,C.offlineLimit(profile))
    local offline=if profile.lastAt>0 then math.floor(C.rate(profile.level,profile.stars,profile.research,profile.machineLevels,profile.legacy)*Discovery.multiplier(profile)*Habitat.bonuses(profile).production*away*.2) else 0
    profile.bank+=offline;profile.lastAt=os.time()
    World.update(plot,profile.level,player.DisplayName,profile.stars);World.updateCrystals(plot,profile.machineLevels)
    World.decorate(plot,profile);World.updateHabitat(plot,profile)
    player.RespawnLocation=plot.spawn
    player:SetAttribute("PlotId",id)
    local function spawnCharacter(char)
        local humanoid=char:WaitForChild("Humanoid");humanoid.WalkSpeed=21;humanoid.JumpPower=48
        char:WaitForChild("HumanoidRootPart");Tower.equip(player);char:PivotTo(plot.cf*CFrame.new(0,4,-34)*CFrame.Angles(0,math.pi,0))
        humanoid.Died:Once(function()
            task.delay(3,function()
                if player.Parent and active(player) and player.Character==char then player:LoadCharacter() end
            end)
        end)
    end
    player.CharacterAdded:Connect(spawnCharacter)
    player:LoadCharacter()
    sync(player)
    if offline>0 then task.delay(5,function() if player.Parent then feedback(player,"Sua ilha trabalhou enquanto você estava fora. +"..C.format(offline).." no coletor.","collect") end end) end
    Telemetry.event("factory.joined",{level=profile.level})
end)
Players.PlayerRemoving:Connect(function(player)
    local s=states[player]
    if s then s.profile.lastAt=os.time();World.update(s.plot,0,nil);World.updateCrystals(s.plot,{});World.updateHabitat(s.plot,{habitat={floors=0,owned={},slots={}}}) end
    states[player]=nil;allocator:release(tostring(player.UserId))
end)

local lastTick=os.clock();local lastCycle=-1
RunService.Heartbeat:Connect(function()
    local now=os.clock();if now-lastTick<1 then return end
    local dt=math.min(now-lastTick,5);lastTick=now
    local cycle=math.floor((now-startedAt)/240)
    if cycle>lastCycle then
        if lastCycle>=0 then surgeStart=now;Net.fireAll("Feedback",{text="A aurora chegou! Produção em dobro.",kind="contract"}) end
        lastCycle=cycle
    end
    for player,s in states do
        if not active(player) then continue end
        local p=s.profile
        local char=player.Character;local r=char and char:FindFirstChild("HumanoidRootPart");local hum=char and char:FindFirstChildOfClass("Humanoid")
        if r and hum and hum.Health>0 then
            if not s.lastPosition or (r.Position-s.lastPosition).Magnitude>2 then s.lastActive=now;s.lastPosition=r.Position end
        end
        Rewards.step(p,dt,now-(s.lastActive or now)<=C.activityGrace)
        local income=C.rate(p.level,p.stars,p.research,p.machineLevels,p.legacy)*Discovery.multiplier(p)*Habitat.bonuses(p).production*dt*Dominion.multiplier(player)*(if surge() then 2 else 1)*(if os.time()<p.overdriveUntil then 3 else 1)
        if p.level>=9 or p.perks.magnet then
            credit(p,income)
            if income>0 and now-(s.lastDelivery or now-30)>=30 then
                s.lastDelivery=now;p.collections+=1;contracts(player,s)
            end
        else p.bank=math.min(1e150,p.bank+income) end
        sync(player)
    end
end)
if RunService:IsStudio() then
    Forge.Debug.expose()
    task.defer(function() Forge.Testing.runAndPublish(script.tests) end)
end
Forge.Debug.probe("aetherworks",function()
    local report={players={},plots={},surge=surge()}
    for player,s in states do report.players[player.Name]={plot=s.plot.id,level=s.profile.level,coins=s.profile.coins,bank=s.profile.bank,rate=C.rate(s.profile.level,s.profile.stars,s.profile.research,s.profile.machineLevels,s.profile.legacy)} end
    for id,plot in World.plots do report.plots[id]={built=plot.built,owner=allocator:ownerOf(id)} end
    return report
end)
workspace:SetAttribute("RQE_READY",true)
workspace:SetAttribute("GameReady",true)
print("[Aetherworks] Ready: four islands, 32 constructions, infinite machine levels, crystal rarities, central domination and infinite tower, server-owned economy")
