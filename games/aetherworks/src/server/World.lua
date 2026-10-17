local RS = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")
local Build = require(game:GetService("ServerScriptService").WorldKit.Build)
local C = require(RS.Shared.TycoonConfig)
local Art = require(RS.Shared.Art)
local HabitatWorld=require(script.Parent.HabitatWorld)
local P = C.colors
local World = {plots={}}
local V = Vector3.new
local function folder(parent,name)
    local m=Instance.new("Model");m.Name=name;m.Parent=parent;return m
end
local function part(parent,name,size,cf,color,material,collide)
    local p=Build.part(parent,name,size,cf.Position,{color=color,material=material or Enum.Material.SmoothPlastic}, {canCollide=collide~=false})
    p.CFrame=cf;p.CanCollide=collide~=false;p.CanTouch=false;p.CastShadow=true
    return p
end
local function cylinder(parent,name,diameter,height,cf,color,material)
    local p=Build.cylinder(parent,name,V(diameter,height,diameter),cf.Position,{color=color,material=material or Enum.Material.Metal})
    p.CFrame=cf*CFrame.Angles(0,0,math.pi/2);p.CanTouch=false;return p
end
local function ball(parent,name,size,cf,color,transparency)
    local p=part(parent,name,size,cf,color,nil,false)
    local mesh=Instance.new("SpecialMesh");mesh.MeshType=Enum.MeshType.Sphere;mesh.Parent=p
    p.Transparency=transparency or 0;return p
end
local function beam(parent,a,b,width,color)
    return part(parent,"Brace",V(width,width,(b-a).Magnitude),CFrame.lookAt((a+b)/2,b),color,Enum.Material.Metal)
end
local function crystal(parent,cf,scale,color)
    local tier=1
    for index,entry in C.crystals do if entry.color==color then tier=index end end
    return Art.crystal(parent,cf,scale,tier)
end
local function lamp(parent,cf)
    cylinder(parent,"LampPost",0.5,7,cf*CFrame.new(0,3.5,0),P.ink)
    cylinder(parent,"LampCap",2.2,0.3,cf*CFrame.new(0,7.4,0),P.copper)
    local core=ball(parent,"Lantern",V(1.6,1.8,1.6),cf*CFrame.new(0,6.9,0),P.gold)
    core.Material=Enum.Material.Neon
    local l=Instance.new("PointLight");l.Color=P.gold;l.Range=13;l.Brightness=0.7;l.Parent=core
end
local function sign(parent,cf,title,subtitle,width)
    local p=part(parent,"Sign",V(width or 12,4,0.5),cf,P.ink,Enum.Material.SmoothPlastic,false)
    local gui=Instance.new("SurfaceGui");gui.Face=Enum.NormalId.Front;gui.CanvasSize=Vector2.new(700,200);gui.LightInfluence=0;gui.Parent=p
    local t=Instance.new("TextLabel");t.BackgroundTransparency=1;t.Size=UDim2.fromScale(1,.6);t.Text=title;t.Font=Enum.Font.GothamBold;t.TextScaled=true;t.TextColor3=P.cream;t.Parent=gui
    local s=t:Clone();s.Position=UDim2.fromScale(0,.64);s.Size=UDim2.fromScale(1,.25);s.Text=subtitle or "";s.TextColor3=P.mint;s.Font=Enum.Font.GothamMedium;s.Parent=gui
    t.Name="Title";s.Name="Subtitle"
    local back=gui:Clone();back.Face=Enum.NormalId.Back;back.Parent=p
    t:GetPropertyChangedSignal("Text"):Connect(function() back.Title.Text=t.Text end)
    s:GetPropertyChangedSignal("Text"):Connect(function() back.Subtitle.Text=s.Text end)
    return t,s
end
local function island(parent,cf,width,depth)
    part(parent,"Foundation",V(width,3,depth),cf*CFrame.new(0,-1.5,0),P.cream,Enum.Material.Slate)
    part(parent,"Meadow",V(width-1,.45,depth-1),cf*CFrame.new(0,.05,0),P.grass,Enum.Material.Grass)
    part(parent,"CopperRim",V(width+1,.6,depth+1),cf*CFrame.new(0,-3.05,0),P.copper,Enum.Material.Metal)
    for layer=1,3 do
        local scale=1-layer*.18
        local rock=Art.mesh(parent,"FloatingStratum","rock",V(width*scale,12,depth*scale),cf*CFrame.new(0,-6-layer*4.5,0)*CFrame.Angles(0,layer*.63,0),P.rock:Lerp(P.ink,layer*.13),Enum.Material.Slate)
    end
    for side=-1,1,2 do
        for j=-2,2 do
            Art.mesh(parent,"CliffFace","rock",V(width*.24,9,9),cf*CFrame.new(j*width*.19,-3.6,side*(depth/2-2)),P.rock,Enum.Material.Slate)
        end
    end
    for _,x in {-1,1} do
        for _,z in {-1,1} do
            crystal(parent,cf*CFrame.new(x*width*.28,-14,z*depth*.26)*CFrame.Angles(math.pi,0,0),1.4,P.crystal)
        end
    end
end
local function tree(parent,cf,scale)
    cylinder(parent,"Trunk",.9*scale,4*scale,cf*CFrame.new(0,2*scale,0),P.copper,Enum.Material.Wood)
    for j=1,3 do
        ball(parent,"Canopy",V(6-j,3.5,6-j)*scale,cf*CFrame.new((j%2)*.5,3.4*scale+j*scale,0),P.grass:Lerp(P.mint,j*.12))
    end
end
local function conveyor(parent,cf,length)
    Art.casing(parent,"ConveyorBed",V(length,1.1,5.4),cf,P.ink)
    for _,z in {-3,3} do part(parent,"ConveyorRail",V(length,.45,.4),cf*CFrame.new(0,.7,z),P.copper,Enum.Material.Metal) end
    for x=-length/2+1,length/2-1,2 do
        part(parent,"BeltTread",V(.2,.1,4.9),cf*CFrame.new(x,.58,0),P.muted,Enum.Material.Metal,false)
    end
    for _,x in {-length/2+1,length/2-1} do
        Art.mesh(parent,"DriveRoller","vessel",V(1.3,5,1.3),cf*CFrame.new(x,0,0)*CFrame.Angles(math.pi/2,0,0),P.copper)
        local drive=Art.group(parent,"BeltDrive",cf*CFrame.new(x,0,-3.2)*CFrame.Angles(math.pi/2,0,0))
        Art.mesh(drive,"DriveGear","gear",V(2,.35,2),drive:GetPivot(),P.copper)
        drive:SetAttribute("SpinSpeed",1);CollectionService:AddTag(drive,"AetherSpin")
    end
    for _,x in {-length*.35,length*.35} do part(parent,"BeltFoot",V(1.1,2,4),cf*CFrame.new(x,-1,0),P.copper) end
end
local function machine(parent,cf,kind,index)
    local m=folder(parent,"Machine_"..index)
    if kind=="land" then
        island(m,cf,30,23);tree(m,cf*CFrame.new(8,0,6),1.2)
        sign(m,cf*CFrame.new(0,5,-8),"EXPANSÃO","MAIS ESPAÇO. MAIS POSSIBILIDADES.",18)
        return m
    elseif kind=="floor" then
        part(m,"Floor",V(30,1,22),cf*CFrame.new(0,10,0),P.cream,Enum.Material.Concrete)
        for _,x in {-13,13} do for _,z in {-9,9} do part(m,"Column",V(1.2,10,1.2),cf*CFrame.new(x,5,z),P.teal) end end
        part(m,"Rail",V(30,1,.4),cf*CFrame.new(0,13,11),P.copper)
        return m
    end
    m:Destroy()
    return Art.machine(parent,cf,kind,index)
end

function World.build()
    Art.prepare()
    local root=folder(workspace,"Aetherworks");World.root=root
    local previews=Instance.new("Folder");previews.Name="AetherPreviews";previews.Parent=RS
    for index,u in C.upgrades do machine(previews,CFrame.new(),u.kind,index) end
    Lighting.ClockTime=16.1;Lighting.GeographicLatitude=18;Lighting.Brightness=2.2;Lighting.ExposureCompensation=-.08
    Lighting.Ambient=Color3.fromRGB(62,78,99);Lighting.OutdoorAmbient=Color3.fromRGB(105,123,139)
    Lighting.EnvironmentDiffuseScale=.55;Lighting.EnvironmentSpecularScale=.8;Lighting.GlobalShadows=true;Lighting.ShadowSoftness=.22
    local atmosphere=Instance.new("Atmosphere");atmosphere.Density=.22;atmosphere.Offset=.1;atmosphere.Color=Color3.fromRGB(201,227,226);atmosphere.Decay=Color3.fromRGB(226,185,133);atmosphere.Haze=1;atmosphere.Glare=.12;atmosphere.Parent=Lighting
    local bloom=Instance.new("BloomEffect");bloom.Intensity=.15;bloom.Size=24;bloom.Threshold=2;bloom.Parent=Lighting
    local grade=Instance.new("ColorCorrectionEffect");grade.Contrast=.12;grade.Saturation=.03;grade.TintColor=Color3.fromRGB(255,245,228);grade.Parent=Lighting
    local rays=Instance.new("SunRaysEffect");rays.Intensity=.05;rays.Spread=.78;rays.Parent=Lighting
    local hub=folder(root,"Skyport");local hubCF=CFrame.new(0,40,0)
    island(hub,hubCF,C.world.hubSize,C.world.hubSize)
    cylinder(hub,"Plaza",C.world.hubSize-20,.6,hubCF*CFrame.new(0,.55,0),P.cream,Enum.Material.Pavement)
    cylinder(hub,"Compass",56,.12,hubCF*CFrame.new(0,.91,0),P.teal)
    cylinder(hub,"CompassInset",53,.14,hubCF*CFrame.new(0,1,0),P.cream)
    local centerpiece=machine(hub,hubCF*CFrame.new(0,0,-57),"heart",0)
    centerpiece:SetAttribute("LandmarkId","aurora-tower");CollectionService:AddTag(centerpiece,"RQELandmark")
    local anchor=centerpiece:FindFirstChild("Reactor")
    if anchor then anchor:SetAttribute("LandmarkId","aurora-tower");CollectionService:AddTag(anchor,"RQELandmarkAnchor") end
    World.hubCF=hubCF
    World.shopPosition=hubCF*V(49,3,15)
    World.arrivalCF=hubCF*CFrame.new(49,5,31)
    local booth=Art.arsenal(hub,hubCF*CFrame.new(49,0,15))
    sign(hub,hubCF*CFrame.new(49,12.1,26),"ARSENAL","OFICINA DOS EXPLORADORES",22)
    local shopPrompt=Instance.new("ProximityPrompt");shopPrompt.ActionText="Abrir arsenal";shopPrompt.ObjectText="Equipamento para a Torre";shopPrompt.MaxActivationDistance=12;shopPrompt.RequiresLineOfSight=false;shopPrompt.Parent=booth;World.shopPrompt=shopPrompt
    local portal=part(hub,"TowerPortal",V(9,12,1),hubCF*CFrame.new(-32,7,-57),P.crystal,Enum.Material.Neon,false);portal.Transparency=.55
    Art.mesh(hub,"PortalFrame","arch",V(15,18,3),hubCF*CFrame.new(-32,9,-57),P.cream)
    for _,x in {-7,7} do
        Art.mesh(hub,"PortalConduit","pipe",V(2,12,1),hubCF*CFrame.new(-32+x,8,-56),P.copper)
        crystal(hub,hubCF*CFrame.new(-32+x,15,-57),.6,C.crystals[4].color)
    end
    sign(hub,hubCF*CFrame.new(-32,20.8,-54.9),"TORRE DA AURORA","ONDAS INFINITAS · CHEFES · RELÍQUIAS",23)
    local towerPrompt=Instance.new("ProximityPrompt");towerPrompt.ActionText="Desafiar a torre";towerPrompt.ObjectText="Use a renda da fábrica para se equipar";towerPrompt.MaxActivationDistance=12;towerPrompt.RequiresLineOfSight=false;towerPrompt.Parent=portal;World.towerPrompt=towerPrompt
    for j=0,7 do
        local a=j*math.pi/4
        local cf=hubCF*CFrame.new(math.sin(a)*(C.world.hubSize/2-9),0,math.cos(a)*(C.world.hubSize/2-9))
        if j%2==1 then tree(hub,cf,1.2) else lamp(hub,cf) end
    end
    World.controlRing=cylinder(hub,"DominionRing",C.world.captureRadius*2,.2,hubCF*CFrame.new(0,1.15,0),P.muted,Enum.Material.SmoothPlastic)
    World.controlRing.CanCollide=false;World.controlRing.Transparency=.6
    cylinder(hub,"BannerPole",.6,12,hubCF*CFrame.new(0,7,0),P.copper)
    World.controlBanner=part(hub,"DominionBanner",V(6,3,.25),hubCF*CFrame.new(2.8,11.5,0),P.muted,nil,false)
    World.controlLabel=sign(hub,hubCF*CFrame.new(0,16,0),"CENTRO NEUTRO","DOMINE COM SUAS TROPAS · PRODUÇÃO ×1,5",28)
    for _,x in {-1,1} do for _,z in {-1,1} do
        part(hub,"GardenWall",V(12,3,3),hubCF*CFrame.new(x*43,2,z*43)*CFrame.Angles(0,x*z*.4,0),P.cream,Enum.Material.Concrete)
        tree(hub,hubCF*CFrame.new(x*53,0,z*53),1.5)
    end end
    local random=Random.new(C.seed)
    local scenery=folder(root,"DistantIslands")
    for j=1,16 do
        local a=j*math.pi/8;local radius=random:NextNumber(760,940)
        local cf=CFrame.new(math.cos(a)*radius,random:NextNumber(8,68),math.sin(a)*radius)
        island(scenery,cf,random:NextNumber(20,45),random:NextNumber(22,43))
        tree(scenery,cf,random:NextNumber(1.3,2.5))
    end
    local clouds=folder(root,"CloudSea")
    for j=1,45 do
        local cf=CFrame.new(random:NextNumber(-660,660),random:NextNumber(-10,10),random:NextNumber(-660,660))
        ball(clouds,"Cloud",V(random:NextNumber(35,100),random:NextNumber(6,15),random:NextNumber(30,70)),cf,Color3.fromRGB(235,246,238),.12)
    end
    local d=C.world.plotDistance
    local positions={V(-d,40,0),V(d,40,0),V(0,40,-d),V(0,40,d)}
    for index,id in C.plotIds do
        local cf=CFrame.lookAt(positions[index],V(0,40,0));local model=folder(root,id);model:SetAttribute("PlotId",id)
        model:SetAttribute("VisualRegionProfile","skyport");CollectionService:AddTag(model,"RQEVisualRegion")
        island(model,cf,103,106)
        part(model,"Promenade",V(13,.3,98),cf*CFrame.new(0,.45,0),P.cream,Enum.Material.Pavement)
        part(model,"Crosswalk",V(97,.3,11),cf*CFrame.new(0,.48,-8),P.cream,Enum.Material.Pavement)
        conveyor(model,cf*CFrame.new(0,3.2,10),70)
        conveyor(model,cf*CFrame.new(0,3.2,29),70)
        -- A permanent open workshop gives the factory a silhouette before its
        -- first machine is bought. The roof leaves the player routes open.
        for _,x in {-35,35} do
            for _,z in {21,39} do part(model,"WorkshopColumn",V(1,16,1),cf*CFrame.new(x,8,z),P.teal,Enum.Material.Metal) end
            beam(model,cf*V(x,15,21),cf*V(x,20,30),.8,P.copper)
            beam(model,cf*V(x,20,30),cf*V(x,15,39),.8,P.copper)
        end
        for _,z in {22,26,30,34,38} do
            part(model,"SunshadeLouver",V(73,.55,1.5),cf*CFrame.new(0,20-math.abs(z-30)*.5,z),P.cream,Enum.Material.Wood)
        end
        sign(model,cf*CFrame.new(0,17,20),"AETHERWORKS","PEQUENAS IDEIAS. NOVOS HORIZONTES.",23)
        for _,x in {-49,49} do
            for z=-48,48,12 do
                if math.abs(z-(if x>0 then -14 else 18))>7 then part(model,"FencePost",V(.55,3,.55),cf*CFrame.new(x,1.8,z),P.copper,Enum.Material.Metal) end
            end
            local gap=if x>0 then -14 else 18
            for _,span in {{-50,gap-7},{gap+7,50}}do part(model,"SafetyRail",V(.4,.45,span[2]-span[1]),cf*CFrame.new(x,2.6,(span[1]+span[2])/2),P.cream)end
        end
        for _,z in {-49,49} do for _,x in {-29,29} do part(model,"EndRail",V(39,.6,.6),cf*CFrame.new(x,2.6,z),P.cream) end end
        for _,x in {-45,45} do for _,z in {-42,42} do lamp(model,cf*CFrame.new(x,0,z)) end end
        tree(model,cf*CFrame.new(-39,0,-38),1.2);tree(model,cf*CFrame.new(39,0,40),1.4)
        local mine=folder(model,"CrystalVein");cylinder(mine,"VeinBase",12,1,cf*CFrame.new(-25,1,-36),P.rock,Enum.Material.Slate)
        for j=1,5 do crystal(mine,cf*CFrame.new(-25+(j-3)*1.7,1,-36+(j%2)*2),.7+(j%3)*.18,P.crystal) end
        local mineAnchor=part(mine,"MineInteraction",V(1,1,1),cf*CFrame.new(-25,3,-31),P.mint,nil,false);mineAnchor.Transparency=1
        local bank=Art.collector(model,cf*CFrame.new(24,0,-43))
        local bankLabel=sign(model,cf*CFrame.new(24,10.7,-37.8),"COLETOR","ENTREGAS DA SUA FÁBRICA",13)
        sign(model,cf*CFrame.new(-25,7.5,-40),"VEIO DE AETHER","EXTRAIA SEUS PRIMEIROS CRISTAIS",14)
        for _,x in {-7,7} do part(model,"EntrancePost",V(1.2,12,1.2),cf*CFrame.new(x,6,-48),P.teal) end
        local ownerLabel=sign(model,cf*CFrame.new(0,11,-48),string.upper(id),"SUA PRÓXIMA GRANDE IDEIA",15)
        local pad=cylinder(model,"BuildPad",7,.35,cf*CFrame.new(0,.9,-19),P.mint,Enum.Material.Neon)
        local prompt=Instance.new("ProximityPrompt");prompt.ActionText="Construir";prompt.ObjectText="Extrator de brisa • 75";prompt.MaxActivationDistance=12;prompt.HoldDuration=.25;prompt.RequiresLineOfSight=false;prompt.Parent=pad
        local spawn=Instance.new("SpawnLocation");spawn.Name="Arrival";spawn.Size=V(6,.2,6);spawn.CFrame=cf*CFrame.new(0,.75,-37);spawn.Anchored=true;spawn.Transparency=1;spawn.CanCollide=false;spawn.Neutral=true;spawn.Duration=0;spawn.Parent=model
        local endpoint=cf*V(0,0,-53);local hubend=V(0,40,0)+(endpoint-V(0,40,0)).Unit*(C.world.hubSize/2-1)
        local middle=(endpoint+hubend)/2;local bridgeCF=CFrame.lookAt(middle,endpoint);local length=(endpoint-hubend).Magnitude
        part(root,"Skybridge",V(18,1,length+2),bridgeCF,P.copper,Enum.Material.WoodPlanks)
        for _,x in {-8.5,8.5} do
            part(root,"BridgeRail",V(.35,.4,length+2),bridgeCF*CFrame.new(x,2.5,0),P.cream)
            for z=-length/2,length/2,8 do part(root,"BridgePost",V(.4,3,.4),bridgeCF*CFrame.new(x,1.3,z),P.teal) end
        end
        World.plots[id]={id=id,model=model,cf=cf,spawn=spawn,mine=mineAnchor,bank=bank,bankLabel=bankLabel,ownerLabel=ownerLabel,pad=pad,prompt=prompt,machines=folder(model,"Machines"),built=0,vein=mine,factionColor=C.factions[index]}
        HabitatWorld.create(World.plots[id],{part=part,sign=sign,island=island},World)
        model:SetAttribute("FactionColor",C.factions[index])
        local annex=folder(model,"CommandAnnex");island(annex,cf*CFrame.new(75,0,-4),42,64)
        part(annex,"CommandWalk",V(34,.6,13),cf*CFrame.new(61,.6,-14),P.cream,Enum.Material.Pavement)
        Art.barracks(annex,cf*CFrame.new(77,0,-19))
        sign(annex,cf*CFrame.new(77,12,-6.5),"GUARNIÇÃO","G · COMPOSIÇÃO E ORDENS",21)
        local boostCF=cf*CFrame.new(77,0,18)
        Art.casing(annex,"BoostDais",V(14,.6,12),boostCF*CFrame.new(0,.5,0),P.cream)
        Art.mesh(annex,"BoostReactor","vessel",V(4,5,4),boostCF*CFrame.new(0,3.3,0),P.teal)
        Art.crystal(annex,boostCF*CFrame.new(0,6,0),.8,4)
        local boost=part(annex,"BoostConsole",V(3,2,2),boostCF*CFrame.new(-5,1.8,0),P.teal)
        sign(annex,boostCF*CFrame.new(0,10,0),"SOBRECARGA","×3 POR 30s · LEGADO R3",15)
        local boostPrompt=Instance.new("ProximityPrompt");boostPrompt.ActionText="Ativar sobrecarga";boostPrompt.ObjectText="Reator de legado";boostPrompt.MaxActivationDistance=10;boostPrompt.RequiresLineOfSight=false;boostPrompt.Parent=boost
        boostPrompt.Triggered:Connect(function(player)if World.onBoost then World.onBoost(player,World.plots[id],boost.Position)end end)

    end
    return World
end

World.updateHabitat=HabitatWorld.update

local function factoryFloor(plot,index,height)
    local model=folder(plot.machines,"Machine_"..index);local cf=plot.cf
    part(model,"UpperFloor",V(76,1.4,52),cf*CFrame.new(0,height,90),P.cream,Enum.Material.Concrete)
    part(model,"FloorRunner",V(10,.15,50),cf*CFrame.new(0,height+.8,90),P.teal,Enum.Material.Metal)
    for _,x in {-36,36} do
        for _,z in {66,114} do
            Art.mesh(model,"Column","girder",V(2,height,2),cf*CFrame.new(x,height/2,z),P.teal)
            Art.casing(model,"ColumnFoot",V(4,.8,4),cf*CFrame.new(x,.8,z),P.copper)
        end
        Art.mesh(model,"FloorTruss","girder",V(2,48,1.5),cf*CFrame.new(x,height-1,90)*CFrame.Angles(math.pi/2,0,0),P.teal)
        part(model,"Guardrail",V(.5,3,42),cf*CFrame.new(x,height+2,86),P.copper)
    end
    for _,z in {65,115} do part(model,"Guardrail",V(74,3,.5),cf*CFrame.new(0,height+2,z),P.copper) end
    local side=if (height/25)%2==1 then 43 else -43
    for step=1,25 do
        part(model,"Stair",V(9,1.1,2.1),cf*CFrame.new(side,height-25+step,61+step*2),P.cream,Enum.Material.Concrete)
    end
    for _,z in {63,113} do
        part(model,"Landing",V(14,1.4,5),cf*CFrame.new(side*.86,if z==63 then height-25 else height,z),P.cream)
    end
    -- Visible elevator pads supplement the real stairs for touch controls.
    for _,entry in {{height-25,height},{height,height-25}} do
        local from,to=entry[1],entry[2]
        local pad=cylinder(model,"Lift",6,.3,cf*CFrame.new(29,from+1.1,69),P.mint,Enum.Material.Neon)
        local prompt=Instance.new("ProximityPrompt");prompt.ActionText=if to>from then "Subir andar" else "Descer andar";prompt.ObjectText="Elevador da fábrica";prompt.MaxActivationDistance=9;prompt.RequiresLineOfSight=false;prompt.Parent=pad
        prompt.Triggered:Connect(function(player)
            if World.onElevator then World.onElevator(player,plot,pad.Position,cf*CFrame.new(29,to+5,69)) end
        end)
    end
end

function World.update(plot,level,owner,stars)
    stars=stars or 0
    if level<plot.built then plot.machines:ClearAllChildren();plot.built=0 end
    for index=plot.built+1,level do
        local u=C.upgrades[index]
        if u.kind=="land" then
            local expansion=folder(plot.machines,"Machine_"..index)
            island(expansion,plot.cf*CFrame.new(0,0,u.z),103,70)
            part(expansion,"ExpansionWalk",V(14,.5,70),plot.cf*CFrame.new(0,.4,u.z),P.cream,Enum.Material.Pavement)
            for _,x in {-49,49} do part(expansion,"OuterRail",V(.5,3,68),plot.cf*CFrame.new(x,2,u.z),P.copper) end
            for _,x in {-29,29} do part(expansion,"OuterRail",V(39,3,.5),plot.cf*CFrame.new(x,2,u.z+33),P.copper) end
            sign(expansion,plot.cf*CFrame.new(35,7,u.z+30),"HORIZONTES","A SUA INDÚSTRIA CRESCE AQUI",22)
        elseif u.kind=="floor" then factoryFloor(plot,index,u.y)
        else machine(plot.machines,plot.cf*CFrame.new(u.x,u.y or 0,u.z),u.kind,index) end
    end
    plot.built=level;plot.model:SetAttribute("Level",level);plot.model:SetAttribute("Owner",owner or "")
    plot.ownerLabel.Text=if owner then string.upper(owner) else string.upper(plot.id)
    local nextUpgrade=C.upgrades[level+1]
    plot.prompt.Enabled=owner~=nil and nextUpgrade~=nil
    plot.pad.Transparency=if nextUpgrade and owner then .1 else .9
    if nextUpgrade then
        plot.prompt.ObjectText=if stars<(nextUpgrade.rebirth or 0) then "Renascimento "..nextUpgrade.rebirth.." necessário" else nextUpgrade.name.." • "..C.format(C.price(nextUpgrade,stars))
    end
end
-- Only production crystals change rarity; architecture keeps its palette.
function World.crystalStyle(model,rank)
    local _,index=C.crystal(rank)
    model:SetAttribute("CrystalTier",index);model:SetAttribute("MachineRank",rank)
    if model:GetAttribute("MachineKind") then Art.evolve(model,index) else Art.recrystal(model,index) end
end
function World.updateCrystals(plot,levels)
    local best=1
    for index=1,plot.built do
        local u=C.upgrades[index];local rank=C.machineLevel(levels,u.id)
        if C.isMachine(u) then
            best=math.max(best,rank);local model=plot.machines:FindFirstChild("Machine_"..index)
            if model then World.crystalStyle(model,rank) end
        end
    end
    -- The mine shares the best rarity unlocked; moving production uses each machine's own tier.
    if plot.vein then World.crystalStyle(plot.vein,best) end
    local _,tier=C.crystal(best);plot.model:SetAttribute("CrystalTier",tier)
end
function World.decorate(plot,p)
    local d=p.discovery or {};local tier=if d.decoration=="astral" then 4 elseif d.decoration=="champion" then 3 else 1
    local rank=math.floor((p.bestWave or 0)/5);local stamp=tier..":"..rank
    if plot.decorStamp==stamp then return end;plot.decorStamp=stamp
    local old=plot.model:FindFirstChild("HallOfDiscoveries");if old then old:Destroy() end
    local m=Art.group(plot.model,"HallOfDiscoveries",plot.cf)
    for _,x in {-46,46} do
        local cf=plot.cf*CFrame.new(x,1,-4)
        Art.casing(m,"DisplayPedestal",V(3,2.5,3),cf*CFrame.new(0,1.25,0),P.cream)
        Art.ring(m,"DisplayRim",3.3,.25,cf*CFrame.new(0,2.6,0),P.copper)
        Art.crystal(m,cf*CFrame.new(0,2.8,0),.7,tier)
    end
    if rank>0 then
        local cf=plot.cf*CFrame.new(37,0,-17)
        Art.casing(m,"TrophyPlinth",V(4,3,4),cf*CFrame.new(0,1.5,0),P.ink)
        Art.mesh(m,"VictoryCog","gear",V(4,.5,4),cf*CFrame.new(0,5,0)*CFrame.Angles(math.pi/2,0,0),P.gold)
        Art.crystal(m,cf*CFrame.new(0,4,0),.5,math.min(5,rank))
        sign(m,cf*CFrame.new(0,2,-2.1),"ONDA "..p.bestWave,"RECORDE DA TORRE",5)
    end
end
World.part=part;World.cylinder=cylinder;World.ball=ball;World.sign=sign
return World
