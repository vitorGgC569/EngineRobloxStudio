--!strict
-- Combat and enemy simulation for Lumenfall. Forge supplies mechanisms; these are game rules.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Data = Forge.Data
local Rig = Forge.Rig
local Anim = Forge.Anim
local Actor = Forge.Actor
local Combat = Forge.Combat
local Net = Forge.Net
local Debug = Forge.Debug

local Config = require(ReplicatedStorage.Shared.Config)

local Gameplay = {}
local started = false
local playerState: { [Player]: any } = {}
local onEnemyKilled: ((Model, any, string) -> ())? = nil

local function stateFor(player: Player)
    local state = playerState[player]
    if not state then
        state = {
            combo=0, lastAttack=0, chargeStart=0, lastDash=0, lastUtility=0,
            sprinting=false,
        }
        playerState[player]=state
    end
    return state
end

local function targetRoot(model: Model): BasePart?
    return model:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function playerAttack(player: Player, direction: Vector3, heavyMultiplier: number?)
    local character=player.Character
    local root=character and targetRoot(character)
    if not (character and root and Combat.isAlive(character)) then return end
    local state=stateFor(player)
    local now=os.clock()
    local cooldown=heavyMultiplier and 0.85 or 0.42
    if now-state.lastAttack < cooldown then return end
    if now-state.lastAttack > 1.05 then state.combo=0 end
    state.combo=(state.combo%3)+1
    state.lastAttack=now

    local power=tonumber(player:GetAttribute("PowerUpgrade")) or 0
    local runPower=tonumber(player:GetAttribute("RunPowerMultiplier")) or 1
    local amount=22*(1+power*0.12)*runPower
    local range=9.5
    local angle=110
    if heavyMultiplier then
        amount=36*heavyMultiplier*runPower
        range=11
        angle=145
    elseif state.combo==3 then
        amount=34*runPower
        angle=165
    end

    local hits=Combat.arc(root.Position,direction,{
        range=range, angle=angle, ignore={character}, limit=7,
        filter=function(model)
            return Players:GetPlayerFromCharacter(model)==nil and model:GetAttribute("EnemyId")~=nil
        end,
    })
    for _,target in hits do
        local ctx=Combat.damage(target,{
            amount=amount,source=player,direction=direction,from=root.Position,
            kind=heavyMultiplier and "heavy" or "melee",
        })
        if ctx then
            player:SetAttribute("CombatHitCount",(tonumber(player:GetAttribute("CombatHitCount")) or 0)+1)
            player:SetAttribute("CombatDamageDealt",(tonumber(player:GetAttribute("CombatDamageDealt")) or 0)+(ctx.dealt or 0))
            player:SetAttribute("LastCombatTarget",tostring(target:GetAttribute("EnemyId") or target.Name))
            -- Bosses must stay inside their authored arena. Normal enemies keep
            -- hit-react knockback, but pushing the Hollow Engine off the island
            -- turns a successful attack into an aborted encounter.
            if target:GetAttribute("Boss")~=true then
                Forge.Feel.knockback(target,direction,heavyMultiplier and 34 or 20)
            end
            Net.fire(player,"HitConfirm",{amount=ctx.dealt,heavy=heavyMultiplier~=nil})
        end
    end
end

local function installPlayerHandlers()
    Net.on("Attack",function(player,payload)
        local dir=payload.dir
        if typeof(dir)~="Vector3" then return end
        playerAttack(player,dir,nil)
    end)

    Net.on("HeavyStart",function(player,_payload)
        stateFor(player).chargeStart=os.clock()
    end)

    Net.on("HeavyRelease",function(player,payload)
        local state=stateFor(player)
        if state.chargeStart<=0 then return end
        local held=math.clamp(os.clock()-state.chargeStart,0,1.5)
        state.chargeStart=0
        if held<0.2 then return end
        local dir=payload.dir
        if typeof(dir)~="Vector3" then return end
        playerAttack(player,dir,0.65+held/1.5*1.15)
    end)

    Net.on("Dodge",function(player,_payload)
        local character=player.Character
        if not (character and Combat.isAlive(character)) then return end
        local state=stateFor(player)
        local now=os.clock()
        local cooldown=Config.player.dashCooldown*(tonumber(player:GetAttribute("RunDashCooldownScale")) or 1)
        if now-state.lastDash<cooldown then return end
        state.lastDash=now
        Combat.grantIFrames(character,Config.player.dashIFrames)
        Net.fire(player,"Cooldown",{id="dash",seconds=cooldown})
    end)

    Net.on("Utility",function(player,payload)
        local character=player.Character
        local root=character and targetRoot(character)
        if not (character and root and Combat.isAlive(character)) then return end
        local state=stateFor(player)
        local now=os.clock()
        if now-state.lastUtility<Config.player.utilityCooldown then return end
        local direction=payload.dir
        if typeof(direction)~="Vector3" then return end
        state.lastUtility=now
        Combat.projectile({
            origin=root.Position+Vector3.new(0,1.5,0)+direction*2,
            direction=direction,speed=150,gravity=0,life=3.5,radius=1,
            ignore={character},
            filter=function(model)
                return Players:GetPlayerFromCharacter(model)==nil and model:GetAttribute("EnemyId")~=nil
            end,
            onHit=function(model,position,_normal)
                local power=tonumber(player:GetAttribute("PowerUpgrade")) or 0
                local runPower=tonumber(player:GetAttribute("RunPowerMultiplier")) or 1
                local ctx=Combat.damage(model,{amount=38*(1+power*0.12)*runPower,source=player,position=position,direction=direction,kind="utility"})
                if ctx then
                    player:SetAttribute("CombatHitCount",(tonumber(player:GetAttribute("CombatHitCount")) or 0)+1)
                    player:SetAttribute("CombatDamageDealt",(tonumber(player:GetAttribute("CombatDamageDealt")) or 0)+(ctx.dealt or 0))
                    player:SetAttribute("LastCombatTarget",tostring(model:GetAttribute("EnemyId") or model.Name))
                end
                player:SetAttribute("UtilityLastOutcome",ctx and "damage" or "no-damage")
                player:SetAttribute("UtilityLastHit",model and model:GetFullName() or "")
                player:SetAttribute("UtilityLastDealt",ctx and ctx.dealt or 0)
            end,
            visual={color=Config.palette.lumenCool,size=Vector3.new(0.7,0.7,2.8),trail=true},
        })
        Net.fire(player,"Cooldown",{id="utility",seconds=Config.player.utilityCooldown})
    end)

    Net.on("SetSprint",function(player,payload)
        local character=player.Character
        local humanoid=character and character:FindFirstChildOfClass("Humanoid")
        if not humanoid then return end
        local on=payload.on==true
        stateFor(player).sprinting=on
        humanoid.WalkSpeed=on and Config.player.sprintSpeed or Config.player.walkSpeed
    end)
end

local function damagePlayer(model: Model, amount: number, source: Model, direction: Vector3)
    local ctx=Combat.damage(model,{
        amount=amount,source=source,direction=direction,from=source:GetPivot().Position,kind="enemy",
    })
    if ctx then
        local player=Players:GetPlayerFromCharacter(model)
        if player then Net.fire(player,"PlayerHit",{amount=ctx.dealt}) end
    end
end

local function telegraph(position: Vector3, radius: number, color: Color3, seconds: number): Part
    local ring=Instance.new("Part")
    ring.Name="Telegraph"
    ring.Shape=Enum.PartType.Cylinder
    ring.Size=Vector3.new(0.25,radius*2,radius*2)
    ring.CFrame=CFrame.new(position)*CFrame.Angles(0,0,math.rad(90))
    ring.Color=color
    ring.Material=Enum.Material.Neon
    ring.Transparency=0.25
    ring.Anchored=true
    ring.CanCollide=false
    ring.CanQuery=false
    ring.Parent=Workspace:FindFirstChild("Effects") or Workspace
    task.delay(seconds,function() if ring.Parent then ring:Destroy() end end)
    return ring
end

local function enemyAttack(self)
    local model=self.model
    local root=targetRoot(model)
    local targetModel=self.target
    local targetPart=targetModel and targetRoot(targetModel)
    if not (root and targetModel and targetPart and Combat.isAlive(model) and Combat.isAlive(targetModel)) then return end

    local def=self.data.def
    local direction=(targetPart.Position-root.Position)
    if direction.Magnitude<0.1 then return end
    direction=direction.Unit

    if def.kind=="ranged" then
        telegraph(root.Position+Vector3.new(0,0.2,0),5,Config.palette.lumenCool,0.55)
        task.delay(0.55,function()
            if not (model.Parent and targetModel.Parent and Combat.isAlive(model)) then return end
            local currentRoot=targetRoot(model)
            local currentTarget=targetRoot(targetModel)
            if not (currentRoot and currentTarget) then return end
            local shot=(currentTarget.Position-currentRoot.Position).Unit
            Combat.projectile({
                origin=currentRoot.Position+Vector3.new(0,2,0),direction=shot,speed=105,gravity=0,life=3,radius=1,
                ignore={model},
                filter=function(hit) return Players:GetPlayerFromCharacter(hit)~=nil end,
                onHit=function(hit,_position,_normal) damagePlayer(hit,def.damage,model,shot) end,
                visual={color=Config.palette.lumenCool,size=Vector3.new(0.8,0.8,3.2),trail=true},
            })
        end)
    else
        local windup=def.profile=="heavy" and 0.75 or 0.30
        telegraph(root.Position+direction*(def.reach*0.5),def.reach,Config.palette.danger,windup)
        task.delay(windup,function()
            if not (model.Parent and Combat.isAlive(model)) then return end
            local r=targetRoot(model)
            if not r then return end
            local hits=Combat.arc(r.Position,r.CFrame.LookVector,{
                range=def.reach+2,angle=130,ignore={model},
                filter=function(hit) return Players:GetPlayerFromCharacter(hit)~=nil end,
            })
            for _,hit in hits do damagePlayer(hit,def.damage,model,r.CFrame.LookVector) end
        end)
    end
end

local function defineBrain()
    Actor.defineBrain("lumen_enemy",{
        initial="idle",
        states={
            idle={
                enter=function(self) self:setSpeed(self.data.def.speed*0.45) end,
                update=function(self)
                    if self:leashed() then
                        self.target=nil
                        self:moveTo(self.home)
                    else
                        self:wander(15)
                    end
                end,
                transitions={{
                    to="chase",
                    when=function(self)
                        if self:leashed() then self.target=nil; return false end
                        self.target=self:nearestPlayer(self.data.def.aggro,true)
                        return self.target~=nil
                    end,
                }},
            },
            chase={
                enter=function(self) self:setSpeed(self.data.def.speed) end,
                update=function(self)
                    if self.target then
                        -- Reject an out-of-arena boss target before Nav receives
                        -- a route that can lead the rig off a floating island.
                        if self.data.id=="hollow_engine" and self.leash then
                            local targetPos=self.target:GetPivot().Position
                            local offset=targetPos-self.home
                            local flat=Vector3.new(offset.X,0,offset.Z)
                            if flat.Magnitude>self.leash*0.85 then
                                self.target=nil
                                self:moveTo(self.home)
                                return
                            end
                        end
                        self:pursue(self.target)
                        self:face(self.target)
                    end
                end,
                transitions={
                    {to="idle",when=function(self)
                        return self:leashed()
                    end},
                    {to="strike",when=function(self)
                        return self.target~=nil and self:flatDistanceTo(self.target)<=self.data.def.reach
                            and self:ready("attack",self.data.def.attackEvery)
                    end},
                    {to="idle",when=function(self)
                        return self.target==nil or not self.target.Parent or self:flatDistanceTo(self.target)>self.data.def.aggro*1.5
                    end},
                },
            },
            strike={
                enter=function(self)
                    self:stop()
                    if self.target then self:face(self.target,true) end
                    enemyAttack(self)
                end,
                transitions={{to="chase",when=function(self) return self:stateTime()>1.15 end}},
            },
        },
    })
end

function Gameplay.spawnEnemy(id: string, position: Vector3): Model
    local def=Data.expect("enemy",id)
    local spec=table.clone(def.rig)
    spec.name=def.name
    local model=Rig.build(spec)
    local humanoid=model:FindFirstChildOfClass("Humanoid") :: Humanoid
    humanoid.MaxHealth,humanoid.Health,humanoid.WalkSpeed=def.health,def.health,def.speed
    model:SetAttribute("Armor",def.armor)
    model:SetAttribute("EnemyId",id)
    if id=="hollow_engine" then
        model:SetAttribute("Boss",true)
        model:SetAttribute("BossPhase",1)
        model:SetAttribute("Vulnerable",false)
    end
    model:PivotTo(CFrame.new(position))
    model.Parent=Workspace:FindFirstChild("Actors") or Workspace

    local animator=Anim.new(model)
    animator:setProfile(Anim.profiles[def.profile])
    Anim.bind(animator,"heartbeat")
    local scale=def.rig.scale or 1
    Actor.spawn(model,"lumen_enemy",{
        home=position,leash=(id=="hollow_engine" and 34 or 110),tag="enemy",animator=animator,data={def=def,id=id},navigate=id~="hollow_engine",
        standoff=def.kind=="ranged" and 22 or def.reach*0.65,
        agentParameters={AgentRadius=2.2*scale*(def.rig.bulky and 1.35 or 1),AgentHeight=5*scale,AgentCanJump=id~="hollow_engine",WaypointSpacing=4},
    })
    return model
end

local function startBossPhases(model: Model)
    task.spawn(function()
        local humanoid=model:FindFirstChildOfClass("Humanoid")
        if not humanoid then return end
        while model.Parent and humanoid.Health>0 do
            local fraction=humanoid.Health/humanoid.MaxHealth
            local phase=if fraction>0.66 then 1 elseif fraction>0.33 then 2 else 3
            model:SetAttribute("BossPhase",phase)
            local root=targetRoot(model)
            if root then
                -- Slam is deliberately readable: warning, hit, then weak-point window.
                model:SetAttribute("Vulnerable",false)
                telegraph(root.Position,18+phase*3,Config.palette.danger,1.25)
                task.wait(1.25)
                if not model.Parent then break end
                for _,target in Combat.sphere(root.Position,18+phase*3,{ignore={model}}) do
                    if Players:GetPlayerFromCharacter(target) then
                        damagePlayer(target,22+phase*8,model,Vector3.new(0,1,0))
                    end
                end
                model:SetAttribute("Vulnerable",true)
                Net.fireAll("BossWindow",{phase=phase,seconds=4})
                task.wait(4)
                model:SetAttribute("Vulnerable",false)
                if phase>=2 then
                    local p=root.Position
                    Gameplay.spawnEnemy("skitter",p+Vector3.new(16,4,8))
                    Gameplay.spawnEnemy(phase==3 and "sentinel" or "skitter",p+Vector3.new(-16,4,-8))
                end
            end
            task.wait(math.max(2.5,6-phase))
        end
    end)
end

function Gameplay.onEnemyKilled(callback: (Model, any, string) -> ())
    onEnemyKilled=callback
end

function Gameplay.start()
    if started then return end
    started=true

    Combat.addModifier("lumen.boss-window",80,function(ctx)
        if ctx.target:GetAttribute("Boss")==true and ctx.target:GetAttribute("Vulnerable")~=true then
            ctx.amount*=0.12
        end
    end)
    Combat.addModifier("lumen.armor",100,function(ctx)
        local armor=ctx.target:GetAttribute("Armor") or 0
        if armor>0 then ctx.amount*=100/(100+armor) end
    end)
    Combat.addModifier("lumen.round",900,function(ctx) ctx.amount=math.max(1,math.floor(ctx.amount+0.5)) end)

    defineBrain()
    Anim.registerAll(require(ReplicatedStorage.Forge.Anim.Presets))
    installPlayerHandlers()

    Combat.killed:Connect(function(model,source)
        local id=model:GetAttribute("EnemyId")
        if not id then return end
        if onEnemyKilled then onEnemyKilled(model,source,tostring(id)) end
        local actor=Actor.get(model)
        if actor then actor:play("die") end
        task.delay(2,function() if model.Parent then model:Destroy() end end)
    end)

    Players.PlayerRemoving:Connect(function(player) playerState[player]=nil end)
    Debug.info("Lumenfall combat online")
end

function Gameplay.spawnBoss(position: Vector3): Model
    local boss=Gameplay.spawnEnemy("hollow_engine",position)
    local root=targetRoot(boss)
    if root then
        pcall(function() root:SetNetworkOwner(nil) end)
    end

    local guard
    guard=RunService.Heartbeat:Connect(function()
        if not boss.Parent then
            guard:Disconnect()
            return
        end
        local currentRoot=targetRoot(boss)
        if not currentRoot then return end
        local offset=currentRoot.Position-position
        local flat=Vector2.new(offset.X,offset.Z).Magnitude
        if currentRoot.Position.Y<position.Y-8 or flat>38 then
            boss:PivotTo(CFrame.new(position))
            currentRoot.AssemblyLinearVelocity=Vector3.zero
            currentRoot.AssemblyAngularVelocity=Vector3.zero
        end
    end)

    startBossPhases(boss)
    return boss
end

return Gameplay
