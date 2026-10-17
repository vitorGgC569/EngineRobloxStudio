-- The factory funds expeditions; relics fund permanent industrial research.
-- Every target, price, reward and hit is resolved by the server.
local RS=game:GetService("ReplicatedStorage")
local Players=game:GetService("Players")
local RunService=game:GetService("RunService")
local CollectionService=game:GetService("CollectionService")
local Debris=game:GetService("Debris")
local Forge=require(RS.Forge)
local C=require(RS.Shared.TycoonConfig)
local Art=require(RS.Shared.Art)
local Discovery=require(script.Parent.Discovery)
local Analytics=require(script.Parent.Analytics)
local World=require(script.Parent.World)
local Patterns=require(script.Parent.TowerPatterns)
local Net,Combat,Nav=Forge.Net,Forge.Combat,Forge.Nav
local V=Vector3.new
local Tower={};local runs={};local guests={};local ctx;local shoot
local function lookup(player)return runs[player] or guests[player]end
local function nearestRoot(run,origin)
    local best,distance=nil,math.huge
    for member in run.members do
        local char=member.Character;local r=char and char:FindFirstChild("HumanoidRootPart")
        if r and Combat.isAlive(char) and (r.Position-origin).Magnitude<distance then best=r;distance=(r.Position-origin).Magnitude end
    end
    return best
end

local function root(player)
    local char=player.Character
    return char and Combat.isAlive(char) and char:FindFirstChild("HumanoidRootPart")
end
local function atHub(player)
    local r=root(player)
    return r and (r.Position-World.hubCF.Position).Magnitude<C.world.hubSize*.75
end
local function removeEnemy(enemy)
    enemy.nav:stop();Combat.clearIFrames(enemy.model)
    if enemy.model.Parent then enemy.model:Destroy() end
end
function Tower.leave(player,quiet)
    local run=lookup(player);if not run then return end
    local s=ctx.active(player)
    if not quiet and root(player) and s and (run.cacheCoins or 0)>0 then
        ctx.credit(s.profile,run.cacheCoins);s.profile.relics+=run.cacheRelics or 0
        ctx.feedback(player,"EXTRAÇÃO · +"..C.format(run.cacheCoins).." coroas e "..(run.cacheRelics or 0).." relíquias do saque de risco.","contract")
    end
    if guests[player] then
        guests[player]=nil;run.members[player]=nil;run.cooldowns[player]=nil;run.targets[player]=nil
        if player.Character then Combat.clearIFrames(player.Character)end
        if root(player)then player.Character.Humanoid.WalkSpeed=21;player.Character:PivotTo(World.arrivalCF);Tower.equip(player)end
        ctx.sync(player);return
    end
    local party={};for member in run.members do if member~=player then table.insert(party,member)end end
    for _,member in party do Tower.leave(member,false)end
    runs[player]=nil
    for _,enemy in run.enemies do removeEnemy(enemy) end
    run.model:Destroy()
    if player.Character then Combat.clearIFrames(player.Character) end
    if root(player) then
        player.Character.Humanoid.WalkSpeed=21
        player.Character:PivotTo(World.arrivalCF)
        Tower.equip(player)
    end
    if not quiet then ctx.feedback(player,"Expedição encerrada. Sua fábrica continua produzindo.") end
    ctx.sync(player)
end
function Tower.inspect(player)
    local run=lookup(player)
    if not run then return {active=false} end
    local partySize=0;for _ in run.members do partySize+=1 end
    local alive=0;local bossHealth,bossMax=0,0
    for _,enemy in run.enemies do
        if Combat.isAlive(enemy.model) then
            alive+=1
            if enemy.boss then bossHealth,bossMax=Combat.getHealth(enemy.model) end
        end
    end
    return {active=true,heroic=run.heroic,wave=run.wave,enemies=alive,bossHealth=bossHealth,bossMax=bossMax,modifier=(run.modifier or C.waveModifiers[1]).name,coins=run.coins,relics=run.relics,elapsed=math.floor(os.clock()-run.started),nextWave=run.nextWave~=nil,
        choice=run.nextWave~=nil and run.wave>0 and not run.chosen,choiceSeconds=math.max(0,math.ceil((run.nextWave or 0)-os.clock())),focus=run.focus,risk=run.risk,cacheCoins=run.cacheCoins,cacheRelics=run.cacheRelics,targetId=run.targets[player],coop=run.coop,partySize=partySize,ownerId=run.player.UserId}
end
function Tower.equip(player)
    local s=ctx.active(player);local r=root(player);if not s or not r then return end
    local p=s.profile;local hum=player.Character.Humanoid
    local oldMax=hum.MaxHealth;hum.MaxHealth=C.armorHealth(p)
    hum.Health=math.min(hum.MaxHealth,hum.Health+math.max(0,hum.MaxHealth-oldMax))
    Art.tool(player.Character,math.clamp(p.weapon or 1,1,5),not lookup(player))
end
local function spawnEnemy(run,boss,index)
    local role=if boss then "boss" elseif run.wave>=6 and index==2 then "mender" elseif run.wave>=4 and index==3 then "warden" elseif (run.wave+index)%3==0 then "conduit" elseif index%3==0 then "brute" else "scout"
    local elite=not boss and run.wave>=8 and index==1
    local stats=C.waveStats(run.wave,run.heroic)
    local growth=stats.health*run.modifier.health*(if elite then 1.8 else 1)*(1+(run.risk or 0)*.2)*(if run.coop then 1.7 else 1)
    -- Humanoid properties use engine numeric storage, narrower than a Luau wallet.
    local hp=math.min(1e30,math.floor((if boss then 300 elseif role=="brute" or role=="warden" then 95 else 48)*growth))
    local model=Forge.Rig.build({name=(if elite then "Elite · " else "")..(if boss then "Soberano da Aurora" elseif role=="mender" then "Tecelão vital" elseif role=="warden" then "Bastião prismático" elseif role=="conduit" then "Condutor astral" elseif role=="brute" then "Guardião de cobre" else "Vigia de brisa"),
        shape=if boss or role=="brute" then "hulk" else "biped",scale=if boss then 2 elseif role=="brute" then 1.3 else 1.05,
        body=if boss then C.colors.ink elseif role=="brute" then C.colors.copper else C.colors.teal,
        accent=if role=="mender" then C.colors.mint elseif role=="warden" or elite then Color3.fromRGB(192,118,255) elseif boss then C.colors.gold elseif role=="conduit" then C.colors.crystal else C.colors.cream,
        eyes=C.colors.crystal,glow=true,spikes=boss,weapon=if boss then "greatsword" elseif role=="brute" then "axe" else "staff",collide=true})
    model:SetAttribute("EnemyRole",role);model:SetAttribute("Elite",elite);model:SetAttribute("TowerOwner",run.player.UserId);model:SetAttribute("AetherEnemy",true)
    model:SetAttribute("TargetId",run.wave*100+index)
    model.Parent=run.model
    Art.armor(model,role,if boss then C.colors.gold else C.colors.crystal,if boss then 2 elseif role=="brute" then 1.3 else 1.05)
    local a=index*2.1
    model:PivotTo(CFrame.new(run.center+V(math.sin(a)*22,6,math.cos(a)*22)))
    local hum=model:FindFirstChildOfClass("Humanoid");hum.MaxHealth=hp;hum.Health=hp;hum.WalkSpeed=math.min(18,(if boss or role=="brute" then 8 else 11)+run.wave*.15)*run.modifier.speed
    for _,p in model:GetDescendants() do if p:IsA("BasePart") then pcall(function() p:SetNetworkOwner(nil) end) end end
    CollectionService:AddTag(model,"AetherEnemy")
    local nav=Nav.follow(model,{target=function() local r=nearestRoot(run,model:GetPivot().Position);return if r then r.Parent else nil end,standoff=if role=="conduit" or role=="mender" then 17 else 4,parameters={AgentRadius=if boss then 3 else 2,AgentHeight=7,AgentCanJump=false}})
    table.insert(run.enemies,{model=model,nav=nav,boss=boss,role=role,elite=elite,attackIndex=0,nextHeal=os.clock()+6,nextAttack=os.clock()+2})
end
local function nextWave(run)
    run.wave+=1;run.nextWave=nil;run.chosen=false;run.targets={}
    run.modifier=C.waveModifiers[(run.wave-1)%#C.waveModifiers+1];run.hazardAt=os.clock()+5
    for _,enemy in run.enemies do removeEnemy(enemy) end;run.enemies={}
    for member in run.members do
        local state=ctx.active(member)
        if state and member.Character then
            local profile=state.profile
            local healing=25+((profile.towerResearch or {}).vitality or 0)*3
            if profile.discovery and profile.discovery.specialization=="renewal" and profile.discovery.crafted.renewal then healing+=C.armorHealth(profile)*.08 end
            Combat.heal(member.Character,healing)
        end
    end
    if run.wave%5==0 then
        spawnEnemy(run,true,1)
        for i=2,math.min(4,1+math.floor(run.wave/5)) do spawnEnemy(run,false,i) end
    else for i=1,C.waveStats(run.wave,run.heroic).count do spawnEnemy(run,false,i) end end
    ctx.feedback(run.player,if run.wave%5==0 then "ONDA "..run.wave.." · O SOBERANO DA AURORA DESPERTOU!" else "ONDA "..run.wave.." · A energia da torre está crescendo.","contract")
    ctx.sync(run.player)
end
local function enter(player,heroic,coop)
    local s=ctx.active(player);if not s or lookup(player) then return end
    if not atHub(player) then ctx.feedback(player,"Viaje ao porto central para entrar na torre.","error");return end
    if s.profile.level<5 then ctx.feedback(player,"Construa a turbina celeste para liberar a torre.","error");return end
    if heroic and s.profile.stars<1 then ctx.feedback(player,"Expedições heroicas exigem o primeiro renascimento.","error");return end
    local fee=(if heroic then 12000 else 1500)+math.min(10,s.profile.towerWins)*500
    if not ctx.spend(s.profile,fee) then ctx.feedback(player,"A expedição custa "..C.format(fee).." coroas.","error");return end
    if coop then
        for _,party in runs do
            local count=0;for _ in party.members do count+=1 end
            if party.coop and party.wave==0 and party.nextWave and os.clock()<party.nextWave and count<2 then
                guests[player]=party;party.members[player]=true;party.cooldowns[player]={}
                player.Character:PivotTo(CFrame.new(party.center+V(6,6,22)));Tower.equip(player);Combat.heal(player.Character,10000)
                ctx.feedback(player,"Expedição em dupla · siga junto até a extração!","contract");ctx.sync(player);return
            end
        end
    end
    local slot=table.find(C.plotIds,s.plot.id) or 1
    local center=V(0,155+slot*100,0)
    local model=Instance.new("Model");model.Name="TowerExpedition_"..slot;model.Parent=World.root
    World.cylinder(model,"Arena",76,3,CFrame.new(center),C.colors.cream,Enum.Material.Slate)
    World.cylinder(model,"Ring",66,.15,CFrame.new(center+V(0,1.6,0)),C.colors.copper)
    World.cylinder(model,"BattleFloor",63,.17,CFrame.new(center+V(0,1.7,0)),C.colors.teal)
    for i=0,11 do
        local a=i*math.pi/6;local cf=CFrame.new(center)*CFrame.Angles(0,a,0)*CFrame.new(0,6,-36)
        local wall=Art.casing(model,"Balustrade",V(20,9,1),cf,C.colors.cream,Enum.Material.Concrete);wall.CanCollide=true
        Art.casing(model,"ParapetCap",V(20,.5,2),cf*CFrame.new(0,4.7,0),C.colors.copper)
        Art.mesh(model,"Pillar","girder",V(2,18,2),cf*CFrame.new(9,3,0),C.colors.teal)
        Art.mesh(model,"WallEmblem","gear",V(3,.25,3),cf*CFrame.new(0,1,.6)*CFrame.Angles(math.pi/2,0,0),C.colors.copper)
        Art.casing(model,"RadialInlay",V(.2,.04,18),CFrame.new(center)*CFrame.Angles(0,a,0)*CFrame.new(0,1.82,-20),C.colors.cream)
    end
    World.sign(model,CFrame.new(center+V(0,18,-37)),"TORRE DA AURORA","A SUA FÁBRICA FINANCIA ESTE HORIZONTE",35)
    local run={coins=0,relics=0,cacheCoins=0,cacheRelics=0,focus=0,risk=0,modifier=C.waveModifiers[1],player=player,heroic=heroic==true,model=model,center=center,wave=0,enemies={},started=os.clock(),difficulty=math.min(10,s.profile.towerWins)+(if heroic then 8 else 0),nextWave=os.clock()+4}
    run.coop=coop==true;run.members={[player]=true};run.cooldowns={[player]={}};run.targets={}
    if coop then run.nextWave=os.clock()+20 end
    runs[player]=run;player.Character:PivotTo(CFrame.new(center+V(0,6,22)))
    Analytics.step(player,5,"EnteredTower")
    Tower.equip(player);Combat.heal(player.Character,10000)
    ctx.feedback(player,if coop then "Dupla aberta por 20s. Outro explorador pode entrar pelo arsenal." else "A expedição começa em 4s. F disparar · Q esquivar.","contract");ctx.sync(player)
end
function Tower.start(callbacks)
    ctx=callbacks
    Net.on("TowerChoice",function(player,payload)
        local run=lookup(player);if not run or not run.nextWave or run.wave<1 or run.chosen or not C.towerChoices[payload.id] or os.clock()>=run.nextWave then return end
        run.chosen=true
        if payload.id=="focus" then run.focus+=1 elseif payload.id=="risk" then run.risk+=1
        elseif player.Character then Combat.heal(player.Character,C.armorHealth(ctx.active(player).profile)*.35) end
        ctx.active(player).lastActive=os.clock();ctx.sync(player)
    end)
    Net.on("TowerTarget",function(player,payload)
        local run=lookup(player);local r=root(player);if not run or not r then return end
        for _,enemy in run.enemies do
            if enemy.model:GetAttribute("TargetId")==payload.id and Combat.isAlive(enemy.model) and (enemy.model:GetPivot().Position-r.Position).Magnitude<=55 then run.targets[player]=payload.id;ctx.sync(player);return end
        end
    end)
    Net.on("Travel",function(player)
        local s=ctx.active(player);if not s or not root(player) then return end
        if lookup(player) then ctx.feedback(player,"Encerre a expedição para sair.","error");return end
        if os.clock()-(s.lastTravel or 0)<3 then return end;s.lastTravel=os.clock()
        player.Character:PivotTo(World.arrivalCF);Net.fire(player,"Feedback",{kind="shop",text="PORTO CENTRAL · prepare-se para a Torre da Aurora"})
    end)
    Net.on("Shop",function(player,payload)
        local s=ctx.active(player);if not s or not atHub(player) or lookup(player) then return end
        local p=s.profile;local item=payload.item
        if item=="research" then
            local price=(p.research+1)*2
            if p.relics<price then ctx.feedback(player,"Pesquisa requer "..price.." relíquias da torre.","error");return end
            p.relics-=price;p.research+=1;ctx.feedback(player,"PESQUISA CONCLUÍDA · +10% de produção permanente.","contract")
        elseif item=="weapon" or item=="armor" then
            local catalog=if item=="weapon" then C.weapons else C.armors
            local entry=catalog[p[item]+1]
            if not entry then
                local key=item.."Mastery";local mastery=p[key] or 0;local price=C.infinitePrice(if item=="weapon" then 650000 else 210000,mastery)
                local relics=3+math.floor(mastery/3)
                if p.relics<relics or p.coins<price then ctx.feedback(player,"Maestria custa "..C.format(price).." coroas + "..relics.." relíquias.","error");return end
                if not ctx.spend(p,price) then return end
                p.relics-=relics;p[key]=mastery+1;Tower.equip(player);ctx.feedback(player,"MAESTRIA "..p[key].." · equipamento fortalecido!","contract");ctx.sync(player);return
            end
            if p.stars<(entry.rebirth or 0) then ctx.feedback(player,"Este equipamento exige renascimento "..entry.rebirth..".","error");return end
            if not ctx.spend(p,entry.cost) then ctx.feedback(player,"Faltam "..C.format(entry.cost-p.coins).." coroas.","error");return end
            p[item]+=1;Tower.equip(player);ctx.feedback(player,entry.name.." equipado!","contract")
        else return end
        ctx.sync(player)
    end)
    Net.on("EnterCoop",function(player)enter(player,false,true)end)
    Net.on("EnterTower",function(player) enter(player,false) end);Net.on("EnterHeroic",function(player) enter(player,true) end);Net.on("LeaveTower",function(player) Tower.leave(player) end)
    World.towerPrompt.Triggered:Connect(function(player) enter(player,false) end)
    World.shopPrompt.Triggered:Connect(function(player) if atHub(player) then Net.fire(player,"Feedback",{kind="shop",text="Arsenal do Porto Central"}) end end)
    shoot=function(player,drone)
        local run=lookup(player);local s=ctx.active(player);local r=root(player)
        if not run or not s or not r then return end
        local cooldown=run.cooldowns[player];local key=if drone then "lastDrone" else "lastShot"
        if os.clock()-(cooldown[key] or 0)<(if drone then 1.4 else .38) then return end
        cooldown[key]=os.clock()
        local best,dist=nil,55
        for _,enemy in run.enemies do
            if Combat.isAlive(enemy.model) then
                local d=(enemy.model:GetPivot().Position-r.Position).Magnitude
                if d<dist then best=enemy;dist=d end
            end
        end
        for _,enemy in run.enemies do
            if not drone and run.targets[player] and enemy.model:GetAttribute("TargetId")==run.targets[player] and Combat.isAlive(enemy.model) then
                local d=(enemy.model:GetPivot().Position-r.Position).Magnitude;if d<=55 then best=enemy;dist=d;break end
            end
        end
        if not best then return end
        local to=best.model:GetPivot().Position
        local ignore={};for member in run.members do if member.Character then table.insert(ignore,member.Character)end end
        local params=RaycastParams.new();params.FilterType=Enum.RaycastFilterType.Exclude;params.FilterDescendantsInstances=ignore
        local hit=workspace:Raycast(r.Position,to-r.Position,params)
        if hit and not hit.Instance:IsDescendantOf(best.model) then return end
        s.lastActive=os.clock()
        local damage=C.weaponDamage(s.profile)*(1+(run.focus or 0)*.12)
        if best.boss and s.profile.discovery and s.profile.discovery.specialization=="focus" then damage*=1.2 end
        if best.role=="warden" then
            local cf=best.model:GetPivot();local delta=r.Position-cf.Position
            if delta.Magnitude>.01 and cf.LookVector:Dot(delta.Unit)>.35 then damage*=.35 end
        end
        if drone then damage=math.floor(8+damage*.3) end
        local result=Combat.damage(best.model,{amount=damage,source=player,kind="aether"})
        if result then Net.fire(player,"Feedback",{kind="shot",text="-"..result.dealt,position=to,from=r.Position+(if drone then V(2,3,0) else V(0,0,0))}) end
    end
    Net.on("Attack",function(player) shoot(player,false) end)
    Net.on("Dodge",function(player)
        local run=lookup(player);local r=root(player)
        if not run or not r or os.clock()-(run.cooldowns[player].lastDodge or 0)<C.dodgeCooldown(ctx.active(player).profile) then return end
        run.cooldowns[player].lastDodge=os.clock();ctx.active(player).lastActive=os.clock();local char=player.Character
        Combat.grantIFrames(char,.6);char.Humanoid.WalkSpeed=38
        Net.fire(player,"Feedback",{kind="dodge",text="ESQUIVA",position=r.Position})
        task.delay(.5,function() if char.Parent and player.Character==char then char.Humanoid.WalkSpeed=21 end end)
    end)
    Players.PlayerRemoving:Connect(function(player) Tower.leave(player,true) end)
    local tickAt=0
    RunService.Heartbeat:Connect(function()
        local now=os.clock();if now-tickAt<.12 then return end;tickAt=now
        for player,run in runs do
            local r=root(player)
            if not r or not ctx.active(player) or (r.Position-run.center).Magnitude>90 then Tower.leave(player);continue end
            for member in run.members do
                if member~=player then
                    local memberRoot=root(member)
                    if not memberRoot or not ctx.active(member) or (memberRoot.Position-run.center).Magnitude>90 then Tower.leave(member)end
                end
            end
            if run.nextWave then if now>=run.nextWave then nextWave(run) end;continue end
            local profile=ctx.active(player).profile
            for member in run.members do local state=ctx.active(member);if state and state.profile.perks.drone then shoot(member,true)end end
            if run.modifier.id=="storm" and now>=run.hazardAt then
                run.hazardAt=now+6
                local at=V(r.Position.X,run.center.Y+1.85,r.Position.Z)
                local mark=World.cylinder(run.model,"AstralStorm",18,.12,CFrame.new(at),Color3.fromRGB(196,99,255),Enum.Material.Neon)
                mark.CanCollide=false;mark.CanQuery=false;mark.Transparency=.55
                task.delay(1.7,function()
                    if mark.Parent then mark:Destroy() end
                    if runs[player]~=run then return end
                    for member in run.members do
                        local current=root(member)
                        if current and Vector2.new(current.Position.X-at.X,current.Position.Z-at.Z).Magnitude<9 then Forge.Combat.damage(member.Character,{amount=C.waveStats(run.wave,run.heroic).damage*1.4,kind="astral"}) end
                    end
                end)
            end
            local alive=0
            for _,enemy in run.enemies do
                if not Combat.isAlive(enemy.model) then
                    if enemy.model.Parent then removeEnemy(enemy) end
                    continue
                end
                alive+=1
                if enemy.role=="mender" and now>=enemy.nextHeal then
                    enemy.nextHeal=now+6
                    for _,ally in run.enemies do
                        if ally~=enemy and Forge.Combat.isAlive(ally.model) and (ally.model:GetPivot().Position-enemy.model:GetPivot().Position).Magnitude<24 then
                            Forge.Combat.heal(ally.model,ally.model.Humanoid.MaxHealth*.07)
                            Net.fire(player,"Feedback",{kind="heal",text="CURA",position=ally.model:GetPivot().Position})
                        end
                    end
                end
                r=nearestRoot(run,enemy.model:GetPivot().Position) or r
                local reach=if enemy.boss then 46 elseif enemy.role=="conduit" then 32 else 11
                if now>=enemy.nextAttack and (enemy.model:GetPivot().Position-r.Position).Magnitude<reach then
                    local enraged=enemy.boss and enemy.model.Humanoid.Health<enemy.model.Humanoid.MaxHealth*.4
                    enemy.nextAttack=now+(if enraged then 2.1 elseif enemy.elite then 2.3 else 3.2)
                    Patterns.attack(run,enemy,r,now,root,function(candidate) return runs[candidate.player]==candidate end)
                end
            end
            if alive==0 then
                local s=ctx.active(player)
                if s then
                    local p=s.profile;local boss=run.wave%5==0
                    local record=run.wave>p.bestWave
                    local relics=(if run.heroic then 2 else 1)+(if boss then 3 else 0)+math.floor(((p.towerResearch or {}).salvage or 0)/5)
                    if record and run.wave%10==0 then relics+=math.floor(run.wave/5);ctx.feedback(player,"NOVO RECORDE · marco "..run.wave.."! Bônus de relíquias.","contract") end
                    p.relics+=relics;p.bestWave=math.max(p.bestWave,run.wave)
                    Discovery.progress(p,"waves",1)
                    local reward=math.floor((250*run.wave^1.2+math.min(50000,C.rate(p.level,p.stars,p.research,p.machineLevels,p.legacy)*10))*(if run.heroic then 2 else 1)*run.modifier.reward)
                    ctx.credit(p,reward);run.coins+=reward;run.relics+=relics
                    if run.risk>0 then run.cacheCoins+=math.floor(reward*run.risk*.25);run.cacheRelics+=math.max(1,math.floor(relics*run.risk*.25)) end
                    for member in run.members do if member~=player then
                        local state=ctx.active(member)
                        if state then
                            local ally=state.profile;ctx.credit(ally,reward);ally.relics+=relics;ally.bestWave=math.max(ally.bestWave,run.wave);Discovery.progress(ally,"waves",1)
                            if boss then ally.towerWins+=1;Discovery.boss(ally,run.wave);if run.heroic or run.wave%10==0 then ally.cores+=1 end;World.decorate(state.plot,ally)end
                            ctx.sync(member)
                        end
                    end end
                    if boss then
                        p.towerWins+=1
                        Discovery.boss(p,run.wave);World.decorate(s.plot,p)
                        Analytics.step(player,6,"FirstBoss");Analytics.event(player,"TowerBossWave",run.wave)
                        if run.heroic or run.wave%10==0 then p.cores+=1 end
                        Forge.Telemetry.event("tower.boss.defeated",{wave=run.wave,heroic=run.heroic})
                    end
                    ctx.sync(player)
                end
                run.nextWave=now+8;run.chosen=false;ctx.feedback(player,"ONDA "..run.wave.." CONCLUÍDA · escolha uma melhoria ou extraia seu saque.","contract")
            end
        end
    end)
end
return Tower
