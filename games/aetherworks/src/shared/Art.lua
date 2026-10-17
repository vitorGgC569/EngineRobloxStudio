-- Original modular art. Published MeshParts are cached once and cloned.
local RS=game:GetService("ReplicatedStorage")
local Run=game:GetService("RunService")
local Tags=game:GetService("CollectionService")
local C=require(script.Parent.TycoonConfig)
local IDs=require(script.Parent.PublishedArt)
local Art={};local P=C.colors;local V=Vector3.new
local templates
local function group(parent,name,cf)
    local m=Instance.new("Model");m.Name=name;m.WorldPivot=cf or CFrame.new();m.Parent=parent;return m
end
function Art.prepare()
    if templates then return end
    if Run:IsClient() then templates=RS:WaitForChild("AetherArtTemplates");return end
    templates=Instance.new("Folder");templates.Name="AetherArtTemplates"
    local Mesh=require(game:GetService("ServerScriptService").WorldKit.Mesh)
    local token={color=function()return P.cream end}
    for _,module in script.Parent.MeshKit:GetChildren() do
        local id=module.Name;local part
        if IDs[id] then
            local ok,result=pcall(function()return game:GetService("AssetService"):CreateMeshPartAsync(Content.fromUri(IDs[id]),{CollisionFidelity=Enum.CollisionFidelity.Box})end)
            if ok then part=result end
        end
        if not part then
            part=Mesh.build(require(module),token,{canCollide=false})
            warn("[Aetherworks Art] "..id.." using local mesh backend; published loading not validated")
        end
        assert(part,"Missing authored art: "..id)
        part.Name=id;part.Anchored=true;part.CanCollide=false;part.CanTouch=false;part.CanQuery=false
        part:SetAttribute("ArtAsset",id);part.Parent=templates
    end
    templates:SetAttribute("Ready",true);templates.Parent=RS
end
function Art.mesh(parent,name,asset,size,cf,color,material)
    Art.prepare();local source=templates:FindFirstChild(asset);assert(source,"Missing template "..asset)
    local p=source:Clone();p.Name=name;p.Size=size;p.CFrame=cf;p.Color=color or P.teal;p.Material=material or Enum.Material.Metal
    p.CastShadow=true;p.Parent=parent;return p
end
local function casing(parent,name,size,cf,color,material) return Art.mesh(parent,name,"casing",size,cf,color,material) end
local function ring(parent,name,diameter,depth,cf,color)
    return Art.mesh(parent,name,"collar",V(diameter,depth,diameter),cf,color or P.copper)
end
function Art.crystal(parent,cf,scale,tier,raw)
    tier=math.clamp(tier or 1,1,5);local color=C.crystals[tier]
    local m=group(parent,"Crystal",cf);m:SetAttribute("ArtCrystal",true);m:SetAttribute("CrystalScale",scale);m:SetAttribute("CrystalTier",tier)
    local core=Art.mesh(m,"Gem","crystal_"..(if raw then 1 else tier),V(2.4,4,2.4)*scale,cf*CFrame.new(0,2*scale,0),color.color,if tier==5 then Enum.Material.SmoothPlastic else Enum.Material.Glass)
    core.Transparency=if tier==5 then 0 else .14
    if tier>=4 and not raw then
        local orbit=group(m,"FacetOrbit",cf*CFrame.new(0,2*scale,0));orbit:SetAttribute("SpinSpeed",.45)
        for j=1,3 do
            local a=j*math.pi*2/3
            Art.mesh(orbit,"Satellite","crystal_"..tier,V(.35,.8,.35)*scale,cf*CFrame.new(math.cos(a)*1.7*scale,(2+.25*math.sin(a))*scale,math.sin(a)*1.7*scale)*CFrame.Angles(.2,a,.2),color.aura or color.color,Enum.Material.Neon)
        end
        Tags:AddTag(orbit,"AetherSpin")
    end
    if tier==5 then
        local aura=Instance.new("ParticleEmitter");aura.Name="VoidAura";aura.Texture="rbxasset://textures/particles/sparkles_main.dds";aura.Color=ColorSequence.new(color.aura)
        aura.Rate=4;aura.Lifetime=NumberRange.new(.8,1.3);aura.Speed=NumberRange.new(.4,1);aura.SpreadAngle=Vector2.new(180,180);aura.LightEmission=.6
        aura.Size=NumberSequence.new({NumberSequenceKeypoint.new(0,.2*scale),NumberSequenceKeypoint.new(.5,.9*scale),NumberSequenceKeypoint.new(1,0)});aura.Parent=core
        for j=1,3 do casing(m,"Fissure",V(.04,.8,.06)*scale,cf*CFrame.new(.45*scale,j*.75*scale,-.65*scale)*CFrame.Angles(0,0,.35*j),color.aura,Enum.Material.Neon) end
    end
    return m
end
function Art.recrystal(model,tier)
    local list={}
    for _,v in model:GetDescendants() do if v:IsA("Model") and v:GetAttribute("ArtCrystal") then table.insert(list,v) end end
    for _,v in list do
        if v:GetAttribute("CrystalTier")~=tier then
            local replacement=Art.crystal(v.Parent,v:GetPivot(),v:GetAttribute("CrystalScale") or 1,tier)
            replacement.Name=v.Name;v:Destroy()
        end
    end
end
local function gauge(m,cf)
    ring(m,"GaugeRim",1.7,.2,cf*CFrame.Angles(math.pi/2,0,0),P.copper)
    casing(m,"Dial",V(1.3,1.3,.1),cf,P.cream,Enum.Material.SmoothPlastic)
    casing(m,"Needle",V(.09,.65,.1),cf*CFrame.new(.13,.1,-.12)*CFrame.Angles(0,0,-.5),P.ink)
    for j=0,4 do casing(m,"GaugeTick",V(.08,.17,.09),cf*CFrame.Angles(0,0,(-2+j)*.55)*CFrame.new(0,.47,-.1),P.ink) end
end
local function bolts(m,cf,w,h)
    for _,x in {-1,1} do for _,y in {-1,1} do casing(m,"Bolt",V(.2,.2,.16),cf*CFrame.new(x*w/2,y*h/2,0),P.copper) end end
end
function Art.machine(parent,cf,kind,index)
    local m=group(parent,"Machine_"..index,cf);m:SetAttribute("UpgradeIndex",index);m:SetAttribute("MachineKind",kind)
    local base=casing(m,"Chassis",V(12,1,10),cf*CFrame.new(0,.7,0),P.cream,Enum.Material.Concrete);base.CanCollide=true
    casing(m,"CopperSkirt",V(11.5,.2,9.5),cf*CFrame.new(0,1.25,0),P.copper)
    for _,x in {-4.5,4.5} do for _,z in {-3.5,3.5} do casing(m,"Foot",V(1.6,.5,1.8),cf*CFrame.new(x,.2,z),P.ink) end end
    if kind=="drill" then
        Art.mesh(m,"CastGantry","arch",V(9,10,3),cf*CFrame.new(0,6.4,1),P.teal)
        casing(m,"MotorHousing",V(6,2.3,4.4),cf*CFrame.new(0,12.2,1),P.teal)
        casing(m,"MotorPlate",V(5.2,1.5,.16),cf*CFrame.new(0,12.2,-1.25),P.cream);bolts(m,cf*CFrame.new(0,12.2,-1.4),4.6,1)
        local drill=group(m,"RotatingDrill",cf*CFrame.new(0,6,0));drill:SetAttribute("SpinSpeed",1.4)
        Art.mesh(drill,"Auger","auger",V(3.1,7,3.1),cf*CFrame.new(0,6,0),P.cream);Tags:AddTag(drill,"AetherSpin")
        for _,x in {-3.3,3.3} do
            casing(m,"HydraulicRod",V(.3,7,.3),cf*CFrame.new(x,6.5,-.8),P.cream)
            casing(m,"PistonSleeve",V(.7,3.7,.7),cf*CFrame.new(x,8.6,-.8),P.copper)
        end
        Art.mesh(m,"CoolantLoop","pipe",V(2.5,4,1),cf*CFrame.new(4.1,7.5,1),P.copper)
        Art.crystal(m,cf*CFrame.new(0,1.5,0),.45,1,true);gauge(m,cf*CFrame.new(-2.4,10,-1.7))
    elseif kind=="polisher" then
        Art.mesh(m,"WorkArch","arch",V(10,7,4.6),cf*CFrame.new(0,5.1,0),P.cream,Enum.Material.SmoothPlastic)
        for _,x in {-3,3} do
            casing(m,"Arm",V(.65,2.2,.65),cf*CFrame.new(x,5,0)*CFrame.Angles(0,0,x*.15),P.teal)
            local disc=group(m,"CuttingDisc",cf*CFrame.new(x*.68,4.5,0)*CFrame.Angles(0,0,math.pi/2));disc:SetAttribute("SpinSpeed",3)
            Art.mesh(disc,"DiamondWheel","gear",V(2,.18,2),disc:GetPivot(),P.copper);Tags:AddTag(disc,"AetherSpin")
        end
        casing(m,"ControlConsole",V(2.3,1.5,2),cf*CFrame.new(4,2.1,-2.8)*CFrame.Angles(.25,0,0),P.teal)
        casing(m,"Display",V(1.65,.7,.08),cf*CFrame.new(4,2.4,-3.8),P.mint,Enum.Material.Neon)
        ring(m,"Emitter",2.7,.25,cf*CFrame.new(0,7.6,0),P.teal)
        Art.crystal(m,cf*CFrame.new(0,2,0),.5,2)
    elseif kind=="furnace" or kind=="tank" then
        Art.mesh(m,"PressureVessel","vessel",V(7,10,7),cf*CFrame.new(0,6.5,0),if kind=="furnace" then P.copper else P.teal)
        for _,y in {2.4,9.6} do ring(m,"PressureBand",7.3,.45,cf*CFrame.new(0,y,0),P.ink) end
        ring(m,"FurnaceDoor",4,.55,cf*CFrame.new(0,5,-3.6)*CFrame.Angles(math.pi/2,0,0),P.ink)
        casing(m,"CoreWindow",V(2.8,2.8,.12),cf*CFrame.new(0,5,-3.8),if kind=="furnace" then P.gold else P.crystal,Enum.Material.Neon)
        ring(m,"DoorRim",3.2,.22,cf*CFrame.new(0,5,-3.92)*CFrame.Angles(math.pi/2,0,0),P.cream)
        gauge(m,cf*CFrame.new(2,8.2,-3));Art.mesh(m,"PressurePipe","pipe",V(2.4,5,1),cf*CFrame.new(4,6,0),P.copper)
        casing(m,"Exhaust",V(2,5,2),cf*CFrame.new(1.8,13,1),P.ink);ring(m,"ExhaustLip",2.6,.4,cf*CFrame.new(1.8,15.5,1),P.copper)
        local steam=Instance.new("ParticleEmitter");steam.Texture="rbxasset://textures/particles/smoke_main.dds";steam.Rate=2;steam.Speed=NumberRange.new(1,2);steam.Lifetime=NumberRange.new(1,2);steam.Transparency=NumberSequence.new(.8,1);steam.Size=NumberSequence.new(1,3);steam.Parent=m.Exhaust
    else
        -- Family-specific landmark silhouettes share the same mechanical language.
        if kind=="garden" then
            casing(m,"CultivationBed",V(10,2,7),cf*CFrame.new(0,2.1,0),P.copper)
            casing(m,"DarkSoil",V(9,.2,6),cf*CFrame.new(0,3.2,0),P.ink,Enum.Material.Ground)
            for j=1,5 do Art.crystal(m,cf*CFrame.new((j-3)*1.7,3.3,(j%2)*2-1),.4+j*.04,1) end
        elseif kind=="turbine" then
            Art.mesh(m,"Mast","girder",V(2,15,1.5),cf*CFrame.new(0,8.5,0),P.cream)
            local rotor=group(m,"WindRotor",cf*CFrame.new(0,17,0));rotor:SetAttribute("SpinAxis","Z")
            for j=0,3 do casing(rotor,"SweptBlade",V(1.6,8,.45),cf*CFrame.new(0,17,0)*CFrame.Angles(0,0,j*math.pi/2)*CFrame.new(1,4.3,-.5)*CFrame.Angles(0,0,-.24),P.cream) end
            ring(rotor,"Hub",2,.5,cf*CFrame.new(0,17,-.6)*CFrame.Angles(math.pi/2,0,0),P.copper);Tags:AddTag(rotor,"AetherSpin")
        elseif kind=="dispatch" then
            casing(m,"Office",V(8,7,7),cf*CFrame.new(0,5,0),P.cream)
            casing(m,"Canopy",V(10,.6,9),cf*CFrame.new(0,8.8,0)*CFrame.Angles(.12,0,0),P.teal)
            casing(m,"Door",V(2,4.8,.2),cf*CFrame.new(-1.8,4,-3.6),P.copper)
            casing(m,"ServiceWindow",V(3.2,2.5,.15),cf*CFrame.new(1.6,5,-3.7),P.ink)
            for j=1,3 do casing(m,"Parcel",V(1.6,1.3,1.6),cf*CFrame.new(4.5,1.9+(j%2)*1.3,(j-2)*1.7),P.copper,Enum.Material.WoodPlanks) end
        elseif kind=="airship" then
            Art.mesh(m,"Envelope","vessel",V(13,22,11),cf*CFrame.new(0,19,0)*CFrame.Angles(math.pi/2,0,0),P.cream,Enum.Material.Fabric)
            casing(m,"Gondola",V(6,3,12),cf*CFrame.new(0,9,0),P.copper)
            for _,x in {-3,3} do Art.mesh(m,"Cable","girder",V(.2,8,.2),cf*CFrame.new(x,13,0),P.ink) end
        else
            local h=if kind=="heart" then 25 elseif kind=="beacon" then 18 else 13
            Art.mesh(m,"Reactor","vessel",V(6,h,6),cf*CFrame.new(0,h/2+1.5,0),P.teal)
            for j=1,3 do ring(m,"Coil",8,.6,cf*CFrame.new(0,2+j*h/4,0),P.copper) end
            if kind=="observatory" then
                Art.mesh(m,"Dome","vessel",V(10,7,10),cf*CFrame.new(0,h+2,0),P.cream)
                Art.mesh(m,"Telescope","vessel",V(3,9,3),cf*CFrame.new(0,h+5,-4)*CFrame.Angles(math.pi/3,0,0),P.ink)
            else Art.crystal(m,cf*CFrame.new(0,h+1,0),1.2,if kind=="heart" then 4 else 1) end
        end
    end
    Art.evolve(m,1)
    return m
end
function Art.evolve(m,tier)
    if m:GetAttribute("ArtTier")==tier then return end
    m:SetAttribute("ArtTier",tier);local old=m:FindFirstChild("Evolution");if old then old:Destroy() end
    local cf=m:GetPivot();local trim=group(m,"Evolution",cf)
    if tier>=2 then for _,x in {-1,1} do casing(trim,"AuxiliaryMotor",V(1.5,2.4,2),cf*CFrame.new(x*5,2.8,2.8),P.teal) end end
    if tier>=3 then
        for _,x in {-1,1} do Art.mesh(trim,"CoolingLoop","pipe",V(2,4,.7),cf*CFrame.new(x*5.1,5,2.5),P.copper) end
    end
    if tier>=4 then ring(trim,"MagneticRing",10,.35,cf*CFrame.new(0,3.4,0),C.crystals[tier].color) end
    if tier>=5 then
        Art.crystal(trim,cf*CFrame.new(4,4,-3),.5,5)
        casing(trim,"VoidPanel",V(3,1.2,.25),cf*CFrame.new(0,1.6,-5.05),P.ink)
    end
    Art.recrystal(m,tier)
end
function Art.tool(character,rank,mining)
    local hand=character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm");if not hand then return end
    local old=hand:FindFirstChild("AetherTool");if old then old:Destroy() end
    local m=group(hand,"AetherTool",hand.CFrame)
    local color=C.crystals[math.clamp(rank,1,5)].color
    Art.mesh(m,"Gauntlet","gauntlet",V(1.2,1.2,1.7),hand.CFrame*CFrame.new(0,-.1,-.45),P.teal)
    Art.mesh(m,"Focus","crystal_"..math.clamp(rank,1,5),V(.45,.8,.45),hand.CFrame*CFrame.new(0,.3,-1),color,Enum.Material.Glass)
    if mining then Art.mesh(m,"Cutter","pickaxe",V(2.6,.65,.55),hand.CFrame*CFrame.new(0,-.3,-1.2),P.copper) end
    for _,part in m:GetDescendants() do if part:IsA("BasePart") then
        part.Anchored=false;part.Massless=true
        local weld=Instance.new("WeldConstraint");weld.Part0=hand;weld.Part1=part;weld.Parent=part
    end end
end
function Art.collector(parent,cf)
    local m=group(parent,"DeliveryStation",cf)
    local body=casing(m,"VaultBody",V(12,6.5,9),cf*CFrame.new(0,3.6,0),P.teal);body.CanCollide=true
    casing(m,"Foundation",V(14,.7,11),cf*CFrame.new(0,.4,0),P.cream,Enum.Material.Concrete)
    casing(m,"VaultFace",V(10,5,.3),cf*CFrame.new(0,3.6,4.65),P.cream)
    ring(m,"SafeDoor",4.4,.3,cf*CFrame.new(-2,3.6,4.95)*CFrame.Angles(math.pi/2,0,0),P.copper)
    casing(m,"LockHub",V(1.1,1.1,.6),cf*CFrame.new(-2,3.6,5.1),P.ink)
    for j=0,2 do casing(m,"LockSpoke",V(.17,2.5,.17),cf*CFrame.new(-2,3.6,5.5)*CFrame.Angles(0,0,j*math.pi/3),P.copper)end
    casing(m,"PayoutTray",V(4,.6,2),cf*CFrame.new(3,1.6,5.6),P.copper)
    casing(m,"DeliverySlot",V(3.2,.65,.3),cf*CFrame.new(3,2.4,4.92),P.ink)
    for j=1,3 do Art.mesh(m,"CrownStack","vessel",V(.8,.14,.8),cf*CFrame.new(2+j*.48,2,5.6),P.gold)end
    casing(m,"HopperBase",V(6,.7,5),cf*CFrame.new(0,7.4,-1),P.copper)
    Art.mesh(m,"SortingHopper","arch",V(6,3,4),cf*CFrame.new(0,8.7,-1),P.cream)
    Art.crystal(m,cf*CFrame.new(0,7.8,-1),.45,1)
    Art.mesh(m,"ReturnPipe","pipe",V(2,5,1),cf*CFrame.new(6,4.5,-2),P.copper)
    gauge(m,cf*CFrame.new(4,5,4.9)*CFrame.Angles(0,math.pi,0))
    local anchor=Instance.new("Part");anchor.Name="Collector";anchor.Size=V(1,1,1);anchor.CFrame=cf*CFrame.new(0,2.5,6);anchor.Anchored=true;anchor.CanCollide=false;anchor.CanTouch=false;anchor.Transparency=1;anchor.Parent=parent
    return anchor,m
end
function Art.barracks(parent,cf)
    local m=group(parent,"GarrisonWorkshop",cf)
    casing(m,"BarracksFloor",V(24,.8,22),cf*CFrame.new(0,.8,0),P.cream)
    for _,x in {-10,10}do
        Art.mesh(m,"GarrisonColumn","girder",V(1.5,12,1.5),cf*CFrame.new(x,7,-8),P.teal)
        Art.mesh(m,"GarrisonColumn","girder",V(1.5,12,1.5),cf*CFrame.new(x,7,8),P.teal)
    end
    casing(m,"WorkshopCanopy",V(26,.8,24),cf*CFrame.new(0,13,0)*CFrame.Angles(0,0,.08),P.teal)
    casing(m,"BackWall",V(.7,8,20),cf*CFrame.new(10,5,0),P.cream)
    for j=-1,1 do
        Art.mesh(m,"TrainingRack","arch",V(4,5,2),cf*CFrame.new(6,3.5,j*6)*CFrame.Angles(0,math.pi/2,0),P.copper)
        Art.mesh(m,"ReserveWeapon","pickaxe",V(3,.7,.5),cf*CFrame.new(5,4,j*6)*CFrame.Angles(0,math.pi/2,.3),P.cream)
    end
    casing(m,"BriefingTable",V(5,2.6,7),cf*CFrame.new(0,2,-1),P.teal)
    casing(m,"TacticalMap",V(4.5,.1,6.5),cf*CFrame.new(0,3.35,-1),P.cream)
    for j=1,4 do Art.crystal(m,cf*CFrame.new((j%2)*2-1,3.5,math.floor((j-1)/2)*3-2),.13,j)end
    return m
end
function Art.arsenal(parent,cf)
    local m=group(parent,"ArsenalWorkshop",cf)
    local floor=casing(m,"WorkshopFoundation",V(27,1,23),cf*CFrame.new(0,.4,0),P.cream,Enum.Material.Concrete);floor.CanCollide=true
    casing(m,"InlaidFloor",V(24,.12,20),cf*CFrame.new(0,.96,0),P.teal)
    for _,x in {-12,12} do
        for _,z in {-9,9} do Art.mesh(m,"CastColumn","girder",V(1.5,13,1.5),cf*CFrame.new(x,7,z),P.teal) end
        casing(m,"Cornice",V(2,1.4,23),cf*CFrame.new(x,13.2,0),P.cream)
        local wall=casing(m,"SideWall",V(.7,8,18),cf*CFrame.new(x,5,0),P.cream);wall.CanCollide=true
        casing(m,"CopperMolding",V(.8,.3,18),cf*CFrame.new(x,2.4,0),P.copper)
    end
    local back=casing(m,"RearWall",V(23,10,.7),cf*CFrame.new(0,6,-9),P.teal);back.CanCollide=true
    casing(m,"GabledCanopy",V(28,1.1,14),cf*CFrame.new(0,14,-4.3)*CFrame.Angles(.13,0,0),P.cream)
    casing(m,"CopperAwning",V(28,.45,12),cf*CFrame.new(0,13.8,6.8)*CFrame.Angles(-.14,0,0),P.copper)
    for x=-12,12,3 do casing(m,"AwningSeam",V(.18,.15,12),cf*CFrame.new(x,14.15,6.8)*CFrame.Angles(-.14,0,0),P.ink) end
    local counter=casing(m,"ArsenalCounter",V(17,3.6,4),cf*CFrame.new(0,2.8,1),P.teal);counter.CanCollide=true
    casing(m,"Countertop",V(18,.5,5),cf*CFrame.new(0,4.8,1),P.cream)
    for x=-6,6,4 do
        casing(m,"PanelInset",V(3.5,2.3,.15),cf*CFrame.new(x,2.8,3.1),P.copper)
        bolts(m,cf*CFrame.new(x,2.8,3.21),2.8,1.7)
        local stand=cf*CFrame.new(x,5.1,1)
        ring(m,"EquipmentStand",2.7,.25,stand,P.copper)
        Art.mesh(m,"DisplayGauntlet","gauntlet",V(1.5,2.5,1.2),stand*CFrame.new(0,1.4,0)*CFrame.Angles(-.4,.35,0),P.cream)
        Art.crystal(m,stand*CFrame.new(.5,2.1,0),.22,math.clamp(3+math.floor(x/4),1,5))
    end
    for _,x in {-8,8} do
        casing(m,"WeaponRack",V(4.3,6,.7),cf*CFrame.new(x,6.7,-8.5),P.ink)
        for _,side in {-1,1} do Art.mesh(m,"RackWeapon","pickaxe",V(3.2,.7,.6),cf*CFrame.new(x,6.5+side*1.5,-8)*CFrame.Angles(0,0,side*.3),P.copper) end
    end
    Art.mesh(m,"WorkshopEmblem","gear",V(5,.35,5),cf*CFrame.new(0,10,-8.3)*CFrame.Angles(math.pi/2,0,0),P.copper)
    Art.crystal(m,cf*CFrame.new(0,8,-7.9),.5,3)
    Art.mesh(m,"Ventilation","pipe",V(2,8,2),cf*CFrame.new(13,9,-6),P.copper)
    for _,x in {-10,10} do
        local light=casing(m,"TaskLight",V(1.8,.3,1.8),cf*CFrame.new(x,12.5,7),P.gold,Enum.Material.Neon)
        local point=Instance.new("PointLight");point.Color=P.gold;point.Brightness=.7;point.Range=14;point.Parent=light
    end
    return counter,m
end
function Art.armor(model,role,color,scale)
    scale=scale or 1
    local torso=model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso")
    local head=model:FindFirstChild("Head");if not torso or not head then return end
    local function attach(parent,name,asset,size,offset,tint)
        local p=Art.mesh(parent,name,asset,size*scale,parent.CFrame*offset,tint)
        p.Anchored=false;p.Massless=true
        local weld=Instance.new("WeldConstraint");weld.Part0=parent;weld.Part1=p;weld.Parent=p
        return p
    end
    attach(torso,"Breastplate","casing",V(1.8,1.7,.4),CFrame.new(0,0,-.55*scale),P.teal)
    attach(head,"CastHelmet","casing",V(2,1.05,1.6),CFrame.new(0,.35*scale,0),P.ink)
    attach(head,"Visor","casing",V(1.4,.25,.2),CFrame.new(0,.35*scale,-.84*scale),color).Material=Enum.Material.Neon
    attach(torso,"EnergyCell","crystal_3",V(.55,.9,.4),CFrame.new(0,.15*scale,-.8*scale),color).Material=Enum.Material.Glass
    for _,side in {-1,1} do
        attach(torso,"Pauldron","casing",V(.8,.5,1),CFrame.new(side*1.15*scale,.8*scale,0),P.copper)
    end
    if role=="Shield" or role=="warden" then
        local arm=model:FindFirstChild("Left Arm") or model:FindFirstChild("LeftHand")
        if arm then attach(arm,"TowerShield","arch",V(2.4,3.3,.55),CFrame.new(0,0,-.7*scale),P.cream) end
    elseif role=="Support" or role=="mender" then
        attach(torso,"RestorationTank","vessel",V(1.2,2,1),CFrame.new(0,0,1*scale),color)
    elseif role=="Siege" or role=="boss" then
        attach(torso,"SiegeReactor","vessel",V(2.3,2.8,1.5),CFrame.new(0,0,1*scale),P.copper)
    end
end
function Art.pet(parent,cf,id,level)
    local pet=require(script.Parent.PetConfig).byId[id];assert(pet,"Unknown pet")
    local m=group(parent,"Pet_"..id,cf);local tint=C.crystals[pet.tier];local fur=tint.color
    local trim=tint.aura or P.cream;local species=pet.species
    casing(m,"Body",V(2.7,2.2,3.1),cf*CFrame.new(0,1.55,0),fur,Enum.Material.SmoothPlastic)
    casing(m,"Head",V(2.8,2.3,2.2),cf*CFrame.new(0,2.9,1.05),fur,Enum.Material.SmoothPlastic)
    casing(m,"Muzzle",V(1.6,.8,.55),cf*CFrame.new(0,2.4,2.14),P.cream)
    casing(m,"Nose",V(.35,.28,.25),cf*CFrame.new(0,2.63,2.49),P.ink)
    for _,side in {-1,1}do
        casing(m,"Eye",V(.42,.55,.15),cf*CFrame.new(side*.73,3.13,2.19),P.ink)
        casing(m,"EyeGlint",V(.12,.16,.08),cf*CFrame.new(side*.69,3.26,2.29),P.text,Enum.Material.Neon)
        for _,z in {-1,.9}do casing(m,"Paw",V(.85,.55,1.05),cf*CFrame.new(side*.95,.5,z),P.cream)end
        local earHeight=if species=="rabbit" then 2.8 elseif species=="mole" then .55 else 1.4
        Art.mesh(m,"Ear","crystal_1",V(.8,earHeight,.65),cf*CFrame.new(side*.88,4+earHeight*.3,.8)*CFrame.Angles(0,0,-side*.15),fur,Enum.Material.SmoothPlastic)
        if species=="owl" or species=="dragon"then
            for feather=1,3 do Art.mesh(m,"WingFeather","crystal_2",V(.75,2.6-feather*.3,.6),cf*CFrame.new(side*(1.5+feather*.4),2.3-feather*.2,-.3)*CFrame.Angles(0,0,-side*.6),trim)end
        end
    end
    if species=="fox" or species=="dragon"then
        Art.mesh(m,"CurledTail","pipe",V(1.3,2.6,1.3),cf*CFrame.new(.7,1.8,-2)*CFrame.Angles(.4,.3,.4),fur)
        Art.mesh(m,"TailTip","crystal_2",V(1,1.4,1),cf*CFrame.new(1,3,-2),trim)
    end
    Art.crystal(m,cf*CFrame.new(0,1.4,1.7),.16+math.min(level or 1,5)*.015,pet.tier)
    return m
end
Art.casing=casing;Art.ring=ring;Art.group=group
return Art
