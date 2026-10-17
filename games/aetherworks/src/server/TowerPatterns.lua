local RS=game:GetService("ReplicatedStorage")
local Forge=require(RS.Forge)
local C=require(RS.Shared.TycoonConfig)
local World=require(script.Parent.World)
local Patterns={}
local V=Vector3.new
-- Every attack telegraphs its actual server hit area. No client hit reports.
function Patterns.attack(run,enemy,target,now,getRoot,isCurrent)
    local pos=target.Position;local y=run.center.Y+1.85
    local origin=enemy.model:GetPivot().Position
    local at=V(pos.X,y,pos.Z)
    local shape=if enemy.boss then (if enemy.attackIndex%2==0 then "ring" else "cross") elseif enemy.role=="conduit" then "beam" else "circle"
    enemy.attackIndex+=1
    local radius=if enemy.role=="brute" then 8 else 5
    local cf=CFrame.new(at);local marks={};local color=Color3.fromRGB(244,103,81)
    local function add(part) part.CanCollide=false;part.CanTouch=false;part.CanQuery=false;part.Transparency=.5;table.insert(marks,part) end
    if shape=="beam" then
        local start=V(origin.X,y,origin.Z);local direction=at-start
        if direction.Magnitude<.01 then direction=V(0,0,1) end
        cf=CFrame.lookAt(start+direction.Unit*18,start+direction.Unit*36)
        add(World.part(run.model,"BeamWarning",V(6,.15,36),cf,color,Enum.Material.Neon,false))
    elseif shape=="cross" then
        at=V(origin.X,y,origin.Z);cf=CFrame.new(at)*CFrame.Angles(0,enemy.attackIndex*.6,0)
        add(World.part(run.model,"CrossWarning",V(9,.15,62),cf,color,Enum.Material.Neon,false))
        add(World.part(run.model,"CrossWarning",V(62,.15,9),cf,color,Enum.Material.Neon,false))
    elseif shape=="ring" then
        at=V(origin.X,y,origin.Z)
        for i=0,23 do
            local a=i*math.pi/12
            add(World.part(run.model,"RingWarning",V(5,.15,9),CFrame.new(at)*CFrame.Angles(0,a,0)*CFrame.new(0,0,-20),color,Enum.Material.Neon,false))
        end
    else add(World.cylinder(run.model,"AttackWarning",radius*2,.12,cf,color,Enum.Material.Neon)) end
    local delay=if enemy.boss then 1.35 elseif enemy.elite then .9 else 1.1
    task.delay(delay,function()
        for _,mark in marks do if mark.Parent then mark:Destroy() end end
        if not isCurrent(run) or not Forge.Combat.isAlive(enemy.model) then return end
        for member in run.members or {[run.player]=true} do
        local current=getRoot(member);if not current then continue end
        local relative=cf:PointToObjectSpace(current.Position)
        local distance=Vector2.new(current.Position.X-at.X,current.Position.Z-at.Z).Magnitude
        local hit=if shape=="beam" then math.abs(relative.X)<=3 and math.abs(relative.Z)<=18
            elseif shape=="cross" then (math.abs(relative.X)<=4.5 and math.abs(relative.Z)<=31) or (math.abs(relative.Z)<=4.5 and math.abs(relative.X)<=31)
            elseif shape=="ring" then distance>=15.5 and distance<=24.5 else distance<radius
        if hit then
            local damage=C.waveStats(run.wave,run.heroic).damage*(if enemy.boss then 2.3 elseif enemy.elite then 1.3 else 1)
            Forge.Combat.damage(member.Character,{amount=damage,source=enemy.model,kind=shape})
        end
        end
    end)
end
return Patterns
