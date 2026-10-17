--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Mark = Forge.Mark
local Config = require(ReplicatedStorage.Shared.Config)

local World = {}
World.spawnPoint = Vector3.new(0,48,12)
World.enemySpawns = {} :: { [string]: { Vector3 } }
World.lumenNodes = {} :: { BasePart }
World.boonPrompts = {} :: { any }
World.extractionPrompt = nil :: ProximityPrompt?
World.bossPrompt = nil :: ProximityPrompt?
World.upgradePrompt = nil :: ProximityPrompt?
World.bossPosition = Vector3.new(0,72,-610)
World.bossCheckpoint = Vector3.new(30,78,-510)

local P = Config.palette

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
    local p = Instance.new("Part")
    p.Name, p.Size, p.CFrame = name, size, cf
    p.Color, p.Material, p.Anchored = color, material, true
    p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
    p.Parent = parent
    return p
end

local function neon(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3): Part
    local p = part(parent,name,size,cf,color,Enum.Material.Neon)
    p.CanCollide = false
    local light = Instance.new("PointLight")
    light.Color, light.Brightness, light.Range = color, 1.8, math.max(size.X,size.Y,size.Z)*3
    light.Parent = p
    return p
end

local function island(parent: Instance, name: string, centre: Vector3, radius: number, accent: Color3): Model
    local model = Instance.new("Model")
    model.Name, model.Parent = name, parent
    part(model,"Ground",Vector3.new(radius*2,10,radius*2),CFrame.new(centre),P.stone,Enum.Material.Slate)
    for i=1,10 do
        local a=(i/10)*math.pi*2
        local r=radius*(0.45+(i%3)*0.08)
        local s=12+(i%4)*4
        local rock=part(model,"Underside",Vector3.new(s,18+(i%3)*6,s),
            CFrame.new(centre+Vector3.new(math.cos(a)*r,-13-(i%2)*8,math.sin(a)*r))
                * CFrame.Angles(math.rad(15+i*7),a,math.rad(i*9)),
            P.stoneLight,Enum.Material.Basalt)
        rock.CanCollide=false
    end
    for i=1,8 do
        local a=(i/8)*math.pi*2
        local post=part(model,"RuinPillar",Vector3.new(3,10+(i%3)*4,3),
            CFrame.new(centre+Vector3.new(math.cos(a)*radius*0.72,10,math.sin(a)*radius*0.72))
                * CFrame.Angles(0,-a,math.rad((i%2)*5)),P.metal,Enum.Material.Metal)
        if i%2==0 then
            neon(post,"LumenStrip",Vector3.new(0.35,post.Size.Y*0.7,0.35),post.CFrame*CFrame.new(0,0,-1.7),accent)
        end
    end
    local region=part(model,"ReviewRegion",Vector3.new(radius*1.8,2,radius*1.8),
        CFrame.new(centre+Vector3.new(0,6,0)),P.stone,Enum.Material.SmoothPlastic)
    region.Transparency,region.CanCollide,region.CanQuery,region.CanTouch=1,false,false,false
    pcall(function() Mark.region(region,string.lower(name)) end)
    return model
end

local function bridge(parent: Instance, from: Vector3, to: Vector3, width: number)
    local delta=to-from
    local mid=(from+to)/2
    local deck=part(parent,"RiftBridge",Vector3.new(width,3,delta.Magnitude),
        CFrame.lookAt(mid,to),P.metal,Enum.Material.DiamondPlate)
    for side=-1,1,2 do
        part(parent,"Rail",Vector3.new(0.6,3,delta.Magnitude),
            deck.CFrame*CFrame.new(side*width*0.48,2.2,0),P.stoneLight,Enum.Material.Metal)
    end
    for i=1,7 do
        neon(parent,"BridgeLumen",Vector3.new(0.55,1.4,0.55),
            CFrame.new(from:Lerp(to,i/8)+Vector3.new(0,2.3,0)),P.lumenCool)
    end
end

local function label(parent: Instance, text: string, at: Vector3, color: Color3)
    local anchor=part(parent,"LabelAnchor",Vector3.new(1,1,1),CFrame.new(at),color,Enum.Material.SmoothPlastic)
    anchor.Transparency,anchor.CanCollide=1,false
    local gui=Instance.new("BillboardGui")
    gui.Name,gui.Size,gui.StudsOffset,gui.MaxDistance="WorldLabel",UDim2.fromOffset(360,70),Vector3.new(0,4,0),180
    gui.Parent=anchor
    local t=Instance.new("TextLabel")
    t.Size,t.BackgroundTransparency,t.Text,t.TextColor3=UDim2.fromScale(1,1),1,text,color
    t.TextStrokeTransparency,t.Font,t.TextScaled=0.45,Enum.Font.GothamBold,true
    t.Parent=gui
end

local function prompt(parent: BasePart, action: string, object: string, distance: number): ProximityPrompt
    local p=Instance.new("ProximityPrompt")
    p.ActionText,p.ObjectText,p.MaxActivationDistance=action,object,distance
    p.HoldDuration,p.RequiresLineOfSight=0.55,false
    p.Parent=parent
    return p
end

local function lumenNode(parent: Instance, at: Vector3, value: number)
    part(parent,"LumenNode",Vector3.new(5,2,5),CFrame.new(at),P.metal,Enum.Material.Metal)
    local crystal=neon(parent,"LumenCrystal",Vector3.new(2.5,8,2.5),
        CFrame.new(at+Vector3.new(0,5,0))*CFrame.Angles(math.rad(8),math.rad(45),math.rad(8)),P.lumen)
    crystal:SetAttribute("LumenValue",value)
    crystal:SetAttribute("Available",true)
    local pr=prompt(crystal,"Harvest","Unstable Lumen",11)
    pr.HoldDuration=0.7
    table.insert(World.lumenNodes,crystal)
end

function World.start()
    local old=Workspace:FindFirstChild("LumenWorld")
    if old then old:Destroy() end
    World.lumenNodes={}
    World.boonPrompts={}
    local root=Instance.new("Folder")
    root.Name,root.Parent="LumenWorld",Workspace

    Lighting.ClockTime,Lighting.FogColor,Lighting.FogStart,Lighting.FogEnd=19.2,Color3.fromRGB(38,26,62),160,850
    local atmosphere=Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
    atmosphere.Color,atmosphere.Decay=Color3.fromRGB(130,103,181),Color3.fromRGB(38,22,70)
    atmosphere.Density,atmosphere.Haze,atmosphere.Glare=0.34,1.7,0.08
    atmosphere.Parent=Lighting

    local hubC=Vector3.new(0,42,55)
    local reachC=Vector3.new(0,42,-95)
    local foundryC=Vector3.new(115,55,-300)
    local crownC=Vector3.new(0,68,-560)

    local hub=island(root,"Hub",hubC,58,P.safe)
    local reach=island(root,"LanternReach",reachC,68,P.lumen)
    local foundry=island(root,"ShatteredFoundry",foundryC,76,Color3.fromRGB(255,126,62))
    local crown=island(root,"StormCrown",crownC,82,P.storm)

    bridge(root,hubC+Vector3.new(0,6,-48),reachC+Vector3.new(0,6,58),15)
    bridge(root,reachC+Vector3.new(52,6,-35),foundryC+Vector3.new(-60,6,48),13)
    bridge(root,foundryC+Vector3.new(-55,6,-52),crownC+Vector3.new(45,6,68),12)

    label(root,"THE SALVAGER FORGE",hubC+Vector3.new(0,11,15),P.safe)
    label(root,"LANTERN REACH",reachC+Vector3.new(0,12,10),P.lumen)
    label(root,"SHATTERED FOUNDRY",foundryC+Vector3.new(0,12,10),Color3.fromRGB(255,145,78))
    label(root,"STORM CROWN",crownC+Vector3.new(0,14,10),Color3.fromRGB(175,120,255))

    local spawn=Instance.new("SpawnLocation")
    spawn.Name,spawn.Size,spawn.CFrame="SalvagerSpawn",Vector3.new(12,1,12),CFrame.new(hubC+Vector3.new(0,6,12))
    spawn.Anchored,spawn.Neutral,spawn.Duration,spawn.Color,spawn.Material=true,true,0,P.safe,Enum.Material.Neon
    spawn.Parent=hub
    World.spawnPoint=spawn.Position+Vector3.new(0,4,0)
    pcall(function() Mark.exclude(spawn) end)

    local station=part(hub,"ForgeStation",Vector3.new(11,8,8),CFrame.new(hubC+Vector3.new(-25,10,3)),P.metal,Enum.Material.Metal)
    neon(station,"Core",Vector3.new(3,4,1),station.CFrame*CFrame.new(0,0,-4.6),P.safe)
    World.upgradePrompt=prompt(station,"Upgrade","Salvager Forge",12)

    lumenNode(reach,reachC+Vector3.new(-24,7,-16),8)
    lumenNode(reach,reachC+Vector3.new(27,7,18),9)

    local overcharge=part(reach,"OverchargeBoon",Vector3.new(7,5,7),CFrame.new(reachC+Vector3.new(-10,8,6)),P.metal,Enum.Material.Metal)
    neon(overcharge,"Core",Vector3.new(2.2,3.2,2.2),overcharge.CFrame*CFrame.new(0,1,0),P.lumen)
    local overchargePrompt=prompt(overcharge,"Unlock","Overcharge Boon",12)
    overchargePrompt.Name="OverchargeBoonPrompt"
    table.insert(World.boonPrompts,{prompt=overchargePrompt,id="overcharge",cost=8})

    local phaseStep=part(reach,"PhaseStepBoon",Vector3.new(7,5,7),CFrame.new(reachC+Vector3.new(10,8,6)),P.metal,Enum.Material.Metal)
    neon(phaseStep,"Core",Vector3.new(2.2,3.2,2.2),phaseStep.CFrame*CFrame.new(0,1,0),P.lumenCool)
    local phasePrompt=prompt(phaseStep,"Unlock","Phase Step Boon",12)
    phasePrompt.Name="PhaseStepBoonPrompt"
    table.insert(World.boonPrompts,{prompt=phasePrompt,id="phase-step",cost=8})

    lumenNode(foundry,foundryC+Vector3.new(-30,7,12),13)
    lumenNode(foundry,foundryC+Vector3.new(31,7,-18),14)
    lumenNode(crown,crownC+Vector3.new(-30,7,-22),18)

    for i=1,6 do
        local x=foundryC.X-45+i*13
        local tower=part(foundry,"FoundryStack",Vector3.new(8,24+(i%2)*10,8),
            CFrame.new(x,foundryC.Y+17,foundryC.Z+32),P.metal,Enum.Material.Metal)
        neon(tower,"Heat",Vector3.new(4,3,4),tower.CFrame*CFrame.new(0,tower.Size.Y/2-3,0),Color3.fromRGB(255,112,54))
    end

    local altar=part(crown,"HollowEngineAltar",Vector3.new(32,3,32),
        CFrame.new(crownC+Vector3.new(0,7,-18)),P.metal,Enum.Material.DiamondPlate)
    local bossCore=neon(altar,"DormantCore",Vector3.new(7,9,7),CFrame.new(crownC+Vector3.new(0,14,-18)),P.storm)
    World.bossPrompt=prompt(bossCore,"Awaken","The Hollow Engine",14)
    -- R15 scale=2.4 needs substantially more pivot clearance than a normal rig.\n    -- Spawning at +11 placed the lower body into the altar top and the boss could\n    -- be destroyed before an agent could observe or fight it. Let gravity settle\n    -- the rig from a safe height instead of guessing from the humanoid root.\n    World.bossPosition=crownC+Vector3.new(0,20,-18)

    local beacon=part(crown,"ExtractionBeacon",Vector3.new(9,18,9),
        CFrame.new(crownC+Vector3.new(42,15,24)),P.metal,Enum.Material.Metal)
    neon(beacon,"BeaconCore",Vector3.new(3,12,3),beacon.CFrame,P.lumenCool)
    World.extractionPrompt=prompt(beacon,"Extract","Rift Beacon",13)

    World.enemySpawns={
        reach={reachC+Vector3.new(-32,8,-34),reachC+Vector3.new(34,8,-30),reachC+Vector3.new(0,8,38)},
        foundry={foundryC+Vector3.new(-42,8,-28),foundryC+Vector3.new(36,8,-34),foundryC+Vector3.new(28,8,32),foundryC+Vector3.new(-20,8,42)},
        crown={crownC+Vector3.new(-42,8,18),crownC+Vector3.new(42,8,-4)},
    }

    for i=1,18 do
        local a=(i/18)*math.pi*2
        local r=300+(i%4)*45
        local h=45+(i%5)*22
        local shard=part(root,"DistantShard",Vector3.new(20,h,32),
            CFrame.new(crownC+Vector3.new(math.cos(a)*r,h/2-20,math.sin(a)*r))*CFrame.Angles(math.rad(i*11),a,math.rad(i*7)),
            P.void,Enum.Material.Basalt)
        shard.CanCollide=false
    end

    pcall(function()
        Mark.landmark(beacon,"extraction-beacon")
        Mark.landmark(altar,"hollow-engine-arena")
    end)
    return root
end

return World
