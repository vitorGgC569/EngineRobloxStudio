-- Server-owned NPC competition. Armies only attack other armies, never visitors.
local RS=game:GetService("ReplicatedStorage")
local Players=game:GetService("Players")
local RunService=game:GetService("RunService")
local Tags=game:GetService("CollectionService")
local Physics=game:GetService("PhysicsService")
local Debris=game:GetService("Debris")
local Forge=require(RS.Forge)
local C=require(RS.Shared.TycoonConfig)
local World=require(script.Parent.World)
local Art=require(RS.Shared.Art)
local Discovery=require(script.Parent.Discovery)
local Dominion={};local armies={};local ctx
local control={owner=nil,contender=nil,progress=0,contested=false}
local relays={left={progress=0},right={progress=0}}
local round={ends=os.clock()+600,scores={}}
local V=Vector3.new

-- Pure transition, also exercised by Studio tests: contested/empty ground pays no bonus.
function Dominion.stepControl(state,present,dt)
    local candidate,count=nil,0
    for id,n in present do if n>0 then candidate=id;count+=1 end end
    state.contested=count>1
    if state.owner and (present[state.owner] or 0)<=0 then state.owner=nil end
    if count~=1 then state.contender=nil;state.progress=0;return end
    if state.owner==candidate then state.contender=nil;state.progress=0;return end
    if state.contender~=candidate then state.contender=candidate;state.progress=0 end
    state.progress+=dt
    if state.progress>=C.world.captureSeconds then state.owner=candidate;state.contender=nil;state.progress=0 end
end
function Dominion.multiplier(player)
    local s=ctx and ctx.active(player)
    return if s and control.owner==s.plot.id and not control.contested then 1.5 else 1
end
function Dominion.inspect(player)
    local s=ctx and ctx.active(player);local a=armies[player];local count=0
    if a then for _,unit in a.units do if Forge.Combat.isAlive(unit.model) then count+=1 end end end
    return {owner=control.owner,contender=control.contender,progress=control.progress/C.world.captureSeconds,contested=control.contested,
        multiplier=Dominion.multiplier(player),troops=count,level=if s then s.profile.armyLevel else 0,tactic=if s then s.profile.armyTactic else "balanced",
        relays={left=relays.left.owner,right=relays.right.owner},scores=round.scores,roundSeconds=math.max(0,math.ceil(round.ends-os.clock()))}
end
local function remove(unit)
    if unit.nav then unit.nav:stop() end
    if unit.model.Parent then unit.model:Destroy() end
end
local function reset(player)
    local a=armies[player];if not a then return end
    for _,unit in a.units do remove(unit) end
    armies[player]=nil
    if control.owner==a.plot.id then control.owner=nil end
    if control.contender==a.plot.id then control.contender=nil;control.progress=0 end
end
local function spawn(a,slot)
    local stats=C.armyStats(a.profile.armyLevel,a.profile.armyTactic,a.profile.legacy)
    local role=(a.profile.armyLoadout or {})[tostring(slot)] or C.defaultArmy[slot];local spec=C.soldierRoles[role]
    local model=Forge.Rig.build({name=a.plot.id.." · "..spec.name,
        shape=if role=="Shield" then "hulk" else "biped",scale=if role=="Shield" then .96 else .88,body=C.colors.ink,accent=a.plot.factionColor,
        eyes=a.plot.factionColor,glow=false,weapon=if role=="Gunner" then "staff" elseif role=="Shield" then "axe" else "greatsword",collide=true})
    model:SetAttribute("ArmyOwner",a.plot.id);model:SetAttribute("ArmyRole",role);model:SetAttribute("ArmySlot",slot);model.Parent=World.root
    Art.armor(model,role,a.plot.factionColor,if role=="Shield" then .96 else .88)
    model:PivotTo(a.plot.cf*CFrame.new(63+((slot-1)%2)*5,5,-26+math.floor((slot-1)/2)*6))
    local hum=model:FindFirstChildOfClass("Humanoid");hum.MaxHealth=stats.health*spec.health;hum.Health=hum.MaxHealth;hum.WalkSpeed=stats.speed
    for _,part in model:GetDescendants() do if part:IsA("BasePart") then part.CollisionGroup="AetherTroops";pcall(function() part:SetNetworkOwner(nil) end) end end
    Tags:AddTag(model,"AetherSoldier")
    local angle=(table.find(C.plotIds,a.plot.id)-1)*math.pi/2+slot*.3
    local unit={model=model,role=role,slot=slot,target=nil,damage=stats.damage,attackAt=0,born=os.clock()}
    local approach=World.hubCF.Position+V(math.sin(angle)*13,2,math.cos(angle)*13)
    unit.nav=Forge.Nav.follow(model,{target=function()
        if a.profile.armyOrder=="regroup" then return a.plot.cf*V(63+((slot-1)%2)*5,3,-26+math.floor((slot-1)/2)*6) end
        if unit.target and Forge.Combat.isAlive(unit.target.model) then return unit.target.model end
        local route=a.profile.armyRoute or "center"
        if route~="center" then return World.hubCF*V(if route=="left" then -64 else 64,2,-24+slot*2) end
        return approach
    end,standoff=if spec.reach>10 then spec.reach*.6 else 3,parameters={AgentRadius=1.8,AgentHeight=5,AgentCanJump=true}})
    a.units[slot]=unit
end
function Dominion.start(callbacks)
    ctx=callbacks
    for id,relay in relays do
        relay.position=World.hubCF*V(if id=="left" then -64 else 64,1.5,-18)
        relay.marker=Art.ring(World.root,"EnergyRelay",20,.25,CFrame.new(relay.position),C.colors.muted)
        relay.label=World.sign(World.root,CFrame.new(relay.position+V(0,7,-10)),"RELÉ DE ENERGIA","CURA PARA TROPAS ALIADAS",14)
        Art.crystal(World.root,CFrame.new(relay.position),.8,2)
    end
    Forge.Net.on("ArmyLoadout",function(player,payload)
        local s=ctx.active(player);if not s or payload.slot%1~=0 or payload.slot<1 or payload.slot>6 or not C.soldierRoles[payload.role] then return end
        s.profile.armyLoadout=s.profile.armyLoadout or {};s.profile.armyLoadout[tostring(payload.slot)]=payload.role
        ctx.feedback(player,"Composição atualizada. Será aplicada aos próximos reforços.");ctx.sync(player)
    end)
    for _,field in {{"ArmyRoute","armyRoute",C.armyRoutes},{"ArmyPriority","armyPriority",C.armyPriorities}} do
        Forge.Net.on(field[1],function(player,payload)
            local s=ctx.active(player);if not s or not field[3][payload.id] then return end
            s.profile[field[2]]=payload.id;s.lastActive=os.clock();ctx.sync(player)
        end)
    end
    pcall(function() Physics:RegisterCollisionGroup("AetherTroops") end)
    Physics:CollisionGroupSetCollidable("AetherTroops","AetherTroops",false)
    Forge.Net.on("ArmyOrder",function(player,payload)
        local s=ctx.active(player);if not s or not C.armyOrders[payload.id] then return end
        if os.clock()-(s.lastOrder or -10)<5 then return end
        s.lastOrder=os.clock();s.lastActive=os.clock();s.profile.armyOrder=payload.id
        ctx.feedback(player,"ORDEM · "..C.armyOrders[payload.id]);ctx.sync(player)
    end)
    Forge.Net.on("ArmyUpgrade",function(player)
        local s=ctx.active(player);if not s then return end
        local p=s.profile
        if p.level<3 then ctx.feedback(player,"Construa as três primeiras máquinas para abrir a guarnição.","error");return end
        local price=C.infinitePrice(1200,p.armyLevel)
        if not ctx.spend(p,price) then ctx.feedback(player,"Treinar a guarnição custa "..C.format(price).." coroas.","error");return end
        p.armyLevel+=1
        -- Keep deployed health percentage: training cannot repeatedly heal an army in combat.
        local a=armies[player];local stats=C.armyStats(p.armyLevel,p.armyTactic,p.legacy)
        if a then for _,unit in a.units do
            local hum=unit.model:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health>0 then local ratio=hum.Health/hum.MaxHealth;hum.MaxHealth=stats.health*C.soldierRoles[unit.role].health;hum.Health=hum.MaxHealth*ratio;unit.damage=stats.damage end
        end end
        ctx.feedback(player,"GUARNIÇÃO NÍVEL "..p.armyLevel.." · reforços em marcha!","contract");ctx.sync(player)
    end)
    Forge.Net.on("ArmyTactic",function(player,payload)
        local s=ctx.active(player);if not s or not C.tactics[payload.id] then return end
        if os.clock()-(s.lastTactic or -60)<20 then ctx.feedback(player,"Aguarde 20s entre ordens táticas.","error");return end
        s.lastTactic=os.clock();s.profile.armyTactic=payload.id
        local a=armies[player];if a then for _,unit in a.units do
            local stats=C.armyStats(s.profile.armyLevel,payload.id,s.profile.legacy);local hum=unit.model:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health>0 then local ratio=hum.Health/hum.MaxHealth;hum.MaxHealth=stats.health*C.soldierRoles[unit.role].health;hum.Health=hum.MaxHealth*ratio;hum.WalkSpeed=stats.speed;unit.damage=stats.damage end
        end end
        ctx.feedback(player,"Formação: "..C.tactics[payload.id].name..".");ctx.sync(player)
    end)
    Players.PlayerRemoving:Connect(reset)
    local elapsed=0
    RunService.Heartbeat:Connect(function(dt)
        elapsed+=dt;if elapsed<.25 then return end;dt=math.min(elapsed,1);elapsed=0
        local now=os.clock();local present={};local all={}
        for _,player in Players:GetPlayers() do
            local s=ctx.active(player)
            if not s then reset(player);continue end
            if s.profile.armyLevel<=0 then continue end
            local a=armies[player]
            if not a then a={plot=s.plot,profile=s.profile,units={},respawns={}};armies[player]=a end
            local stats=C.armyStats(s.profile.armyLevel,s.profile.armyTactic,s.profile.legacy)
            for slot=1,stats.count do
                local unit=a.units[slot]
                if unit and not Forge.Combat.isAlive(unit.model) then remove(unit);a.units[slot]=nil;a.respawns[slot]=now+stats.respawn;unit=nil end
                if not unit and now>=(a.respawns[slot] or now) then spawn(a,slot);unit=a.units[slot] end
                if unit then
                    local hum=unit.model:FindFirstChildOfClass("Humanoid")
                    local maximum=stats.health*C.soldierRoles[unit.role].health
                    if hum and hum.MaxHealth~=maximum then local fraction=hum.Health/hum.MaxHealth;hum.MaxHealth=maximum;hum.Health=maximum*fraction end
                    unit.damage=stats.damage
                    local at=unit.model:GetPivot().Position
                    if s.profile.armyOrder=="regroup" and (at-s.plot.cf*V(67,0,-20)).Magnitude<24 and now-(unit.lastDamaged or -10)>6 then Forge.Combat.heal(unit.model,maximum*.035*dt) end
                    if at.Y<25 or (now-unit.born>240 and (at-World.hubCF.Position).Magnitude>100) then remove(unit);a.units[slot]=nil;a.respawns[slot]=now+stats.respawn;continue end
                    table.insert(all,{unit=unit,army=a,position=at})
                    if (V(at.X,40,at.Z)-World.hubCF.Position).Magnitude<=C.world.captureRadius then present[a.plot.id]=(present[a.plot.id] or 0)+1 end
                end
            end
        end
        -- Troops overlap by design. Their bodies (and peaceful visitors) must
        -- not shield the chosen target; solid scenery still blocks attacks.
        local attackIgnore={}
        for _,entry in all do table.insert(attackIgnore,entry.unit.model) end
        for _,player in Players:GetPlayers() do if player.Character then table.insert(attackIgnore,player.Character) end end
        for _,entry in all do
            local unit=entry.unit;local order=entry.army.profile.armyOrder
            local nearest,distance=nil,if order=="hold" then 32 elseif order=="regroup" then 15 else 65
            local bestScore=math.huge;local priority=entry.army.profile.armyPriority
            for _,other in all do
                if other.army~=entry.army and Forge.Combat.isAlive(other.unit.model) then
                    local d=(entry.position-other.position).Magnitude
                    local score=d
                    if priority=="support" and other.unit.role=="Support" then score-=60
                    elseif priority=="weak" then local hp,max=Forge.Combat.getHealth(other.unit.model);score=(hp/math.max(1,max))*40+d*.2 end
                    local reach=if order=="hold" then 32 elseif order=="regroup" then 15 else 65
                    if d<reach and score<bestScore then nearest=other.unit;distance=d;bestScore=score end
                end
            end
            unit.target=if order=="regroup" then nil else nearest
            if unit.role=="Support" and now>=(unit.healAt or 0) then
                unit.healAt=now+4
                for _,ally in all do if ally.army==entry.army and (ally.position-entry.position).Magnitude<22 then Forge.Combat.heal(ally.unit.model,unit.damage*1.5) end end
            end
            local spec=C.soldierRoles[unit.role]
            if nearest and now>=unit.attackAt and distance<spec.reach then
                unit.attackAt=now+1.3
                local target=nearest.model:GetPivot().Position
                if not Forge.Combat.canSee(entry.position,nearest.model,attackIgnore) then continue end
                local damage=unit.damage*spec.damage*(if spec.counters==nearest.role then 1.5 else 1)
                Forge.Combat.damage(nearest.model,{amount=damage,source=unit.model,kind="troop"})
                if not Forge.Combat.isAlive(nearest.model) then round.scores[entry.army.plot.id]=(round.scores[entry.army.plot.id] or 0)+5 end
                nearest.lastDamaged=now
                local beam=World.part(World.root,"ArmyPulse",V(.12,.12,math.max(.1,distance)),CFrame.lookAt((entry.position+target)/2,target),entry.army.plot.factionColor,Enum.Material.Neon,false)
                beam.CanQuery=false;Debris:AddItem(beam,.12)
            end
        end
        local previous=control.owner
        Dominion.stepControl(control,present,dt)
        if control.owner and not control.contested then
            round.scores[control.owner]=(round.scores[control.owner] or 0)+dt
            for player,a in armies do if a.plot.id==control.owner then Discovery.progress(a.profile,"dominion",dt) end end
        end
        for id,relay in relays do
            local nearby={}
            for _,entry in all do if (entry.position-relay.position).Magnitude<16 then nearby[entry.army.plot.id]=(nearby[entry.army.plot.id] or 0)+1 end end
            Dominion.stepControl(relay,nearby,dt)
            relay.marker.Color=if relay.owner then C.factions[table.find(C.plotIds,relay.owner)] else C.colors.muted
            relay.label.Text=if relay.contested then "RELÉ EM DISPUTA" elseif relay.owner then relay.owner.." · RELÉ ATIVO" else "RELÉ NEUTRO"
            if relay.owner and not relay.contested then
                for _,entry in all do if entry.army.plot.id==relay.owner and (entry.position-relay.position).Magnitude<20 then Forge.Combat.heal(entry.unit.model,entry.unit.model.Humanoid.MaxHealth*.02*dt) end end
            end
        end
        if now>=round.ends then
            local leader,score=nil,0;local tied=false
            for id,value in round.scores do if value>score then leader=id;score=value;tied=false elseif value==score then tied=true end end
            if leader and not tied then
                for player,a in armies do if a.plot.id==leader then local d=Discovery.prepare(a.profile);d.honor+=5;ctx.feedback(player,"CAMPEÃO DA RODADA · +5 honra cosmética!","contract");World.decorate(a.plot,a.profile) end end
            end
            round={ends=now+600,scores={}}
        end
        local color=if control.owner then C.factions[table.find(C.plotIds,control.owner)] else C.colors.muted
        World.controlBanner.Color=color;World.controlRing.Color=if control.contested then C.colors.gold else color
        World.controlLabel.Text=if control.contested then "CENTRO EM DISPUTA" elseif control.owner then string.upper(control.owner).." · DOMÍNIO ×1,5" elseif control.contender then string.upper(control.contender).." · "..math.floor(control.progress/C.world.captureSeconds*100).."%" else "CENTRO NEUTRO"
        if control.owner and control.owner~=previous then Forge.Net.fireAll("Feedback",{kind="contract",text=control.owner.." dominou o centro! Produção ×1,5 enquanto mantiver o controle."}) end
    end)
end
return Dominion
