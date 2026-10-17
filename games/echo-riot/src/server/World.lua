--!strict
local Lighting=game:GetService("Lighting")
local Workspace=game:GetService("Workspace")

local World={}

local function part(parent:Instance,name:string,size:Vector3,cf:CFrame,color:Color3,material:Enum.Material):Part
    local p=Instance.new("Part")
    p.Name=name
    p.Size=size
    p.CFrame=cf
    p.Color=color
    p.Material=material
    p.Anchored=true
    p.TopSurface=Enum.SurfaceType.Smooth
    p.BottomSurface=Enum.SurfaceType.Smooth
    p.Parent=parent
    return p
end

local function cylinder(parent:Instance,name:string,size:Vector3,cf:CFrame,color:Color3,material:Enum.Material):Part
    local p=part(parent,name,size,cf*CFrame.Angles(0,0,math.rad(90)),color,material)
    p.Shape=Enum.PartType.Cylinder
    return p
end

local function materialRingSegments(
    parent:Instance,
    name:string,
    center:Vector3,
    radius:number,
    segments:number,
    width:number,
    height:number,
    color:Color3,
    material:Enum.Material,
    transparency:number?,
    collidable:boolean?
)
    local arc=(math.pi*2*radius)/segments
    for i=1,segments do
        local a=(i-1)/segments*math.pi*2
        local pos=center+Vector3.new(math.cos(a)*radius,0,math.sin(a)*radius)
        local segment=part(
            parent,
            name,
            Vector3.new(arc*0.82,height,width),
            CFrame.lookAt(pos,center)*CFrame.Angles(0,math.pi/2,0),
            color,
            material
        )
        segment.CanCollide=collidable==true
        segment.Transparency=transparency or 0
    end
end

local function ringSegments(parent:Instance,name:string,center:Vector3,radius:number,segments:number,width:number,height:number,color:Color3,transparency:number?)
    materialRingSegments(parent,name,center,radius,segments,width,height,color,Enum.Material.Neon,transparency,false)
end

local function lightAnchor(parent:Instance,name:string,position:Vector3,color:Color3,brightness:number,range:number,shadows:boolean?)
    local anchor=part(parent,name,Vector3.new(0.5,0.5,0.5),CFrame.new(position),color,Enum.Material.SmoothPlastic)
    anchor.Transparency=1
    anchor.CanCollide=false
    local light=Instance.new("PointLight")
    light.Color=color
    light.Brightness=brightness
    light.Range=range
    light.Shadows=shadows==true
    light.Parent=anchor
end

local function speakerDisc(parent:Instance,name:string,cf:CFrame,radius:number,accent:Color3):Part
    local disc=part(
        parent,
        name,
        Vector3.new(1.4,radius*2,radius*2),
        cf*CFrame.Angles(0,math.rad(90),0),
        Color3.fromRGB(22,21,32),
        Enum.Material.SmoothPlastic
    )
    disc.Shape=Enum.PartType.Cylinder
    disc.CanCollide=false

    local cone=part(
        parent,
        name.."Cone",
        Vector3.new(0.45,radius*1.48,radius*1.48),
        cf*CFrame.new(0,0,-0.86)*CFrame.Angles(0,math.rad(90),0),
        accent,
        Enum.Material.SmoothPlastic
    )
    cone.Shape=Enum.PartType.Cylinder
    cone.CanCollide=false

    local cap=part(
        parent,
        name.."Cap",
        Vector3.new(0.28,radius*0.52,radius*0.52),
        cf*CFrame.new(0,0,-1.14)*CFrame.Angles(0,math.rad(90),0),
        Color3.fromRGB(235,230,245),
        Enum.Material.SmoothPlastic
    )
    cap.Shape=Enum.PartType.Cylinder
    cap.CanCollide=false
    return disc
end

local function speakerTower(parent:Instance,name:string,cf:CFrame,accent:Color3):Model
    local model=Instance.new("Model")
    model.Name=name
    model.Parent=parent

    local body=part(
        model,
        "Cabinet",
        Vector3.new(11,25,6),
        cf,
        Color3.fromRGB(31,29,44),
        Enum.Material.Metal
    )
    body.CanCollide=true

    local inset=part(
        model,
        "Baffle",
        Vector3.new(9.5,22.5,0.7),
        cf*CFrame.new(0,0,-3.35),
        Color3.fromRGB(15,14,24),
        Enum.Material.SmoothPlastic
    )
    inset.CanCollide=false

    speakerDisc(model,"Woofer",cf*CFrame.new(0,-5.1,-3.8),3.55,accent)
    speakerDisc(model,"Mid",cf*CFrame.new(0,2.1,-3.8),2.8,accent)
    speakerDisc(model,"Tweeter",cf*CFrame.new(0,7.6,-3.8),1.7,accent)

    local edge=part(
        model,
        "AccentEdge",
        Vector3.new(0.7,22,0.4),
        cf*CFrame.new(-4.6,0,-3.75),
        accent,
        Enum.Material.Neon
    )
    edge.CanCollide=false
    edge.Transparency=0.18
    return model
end

local function equalizerBank(
    parent:Instance,
    name:string,
    center:Vector3,
    facing:Vector3,
    accentA:Color3,
    accentB:Color3,
    count:number
):{Part}
    local bars={}
    local baseCF=CFrame.lookAt(center,facing)
    for index=1,count do
        local normalized=(index-1)/math.max(count-1,1)
        local wave=(math.sin(normalized*math.pi*2.5)+1)*0.5
        local height=4+wave*10
        local color=accentA:Lerp(accentB,normalized)
        local bar=part(
            parent,
            name,
            Vector3.new(1.8,height,1.8),
            baseCF*CFrame.new((index-(count+1)/2)*2.8,height/2,0),
            color,
            Enum.Material.SmoothPlastic
        )
        bar.CanCollide=false
        table.insert(bars,bar)
    end
    return bars
end

local function surfaceText(parent:BasePart,textValue:string,color:Color3,face:Enum.NormalId?):TextLabel
    local gui=Instance.new("SurfaceGui")
    gui.Name="Display"
    gui.Face=face or Enum.NormalId.Front
    gui.SizingMode=Enum.SurfaceGuiSizingMode.PixelsPerStud
    gui.PixelsPerStud=30
    gui.Parent=parent

    local text=Instance.new("TextLabel")
    text.Size=UDim2.fromScale(1,1)
    text.BackgroundTransparency=1
    text.Text=textValue
    text.TextColor3=color
    text.TextScaled=true
    text.Font=Enum.Font.GothamBlack
    text.Parent=gui

    local stroke=Instance.new("UIStroke")
    stroke.Thickness=2
    stroke.Color=Color3.fromRGB(16,14,28)
    stroke.Transparency=0.12
    stroke.Parent=text
    return text
end

local function buildHub(root:Folder,Config:any)
    local P=Config.palette
    local origin=Config.hub.origin
    local hub=Instance.new("Folder")
    hub.Name="Hub"
    hub.Parent=root

    cylinder(
        hub,
        "HubIsland",
        Vector3.new(10,Config.hub.plazaRadius*2,Config.hub.plazaRadius*2),
        CFrame.new(origin+Vector3.new(0,4,0)),
        Color3.fromRGB(38,35,56),
        Enum.Material.Slate
    )
    local plazaInlay=cylinder(
        hub,
        "PlazaInlay",
        Vector3.new(0.7,108,108),
        CFrame.new(origin+Vector3.new(0,9.3,0)),
        Color3.fromRGB(46,42,68),
        Enum.Material.SmoothPlastic
    )
    plazaInlay.CanCollide=false

    materialRingSegments(
        hub,"HubStructureRing",origin+Vector3.new(0,31,0),67,20,5.2,3.4,
        Color3.fromRGB(49,45,70),Enum.Material.Metal,0,false
    )
    materialRingSegments(
        hub,"HubCanopyRing",origin+Vector3.new(0,41,0),59,16,9.5,2.6,
        Color3.fromRGB(32,30,48),Enum.Material.Metal,0.04,false
    )
    ringSegments(hub,"HubOuterGlow",origin+Vector3.new(0,9.42,0),Config.hub.plazaRadius-5,36,1.0,0.34,P.violet,0.34)
    ringSegments(hub,"HubInnerGlow",origin+Vector3.new(0,9.48,0),43,28,0.75,0.3,P.cyan,0.46)

    for i=1,12 do
        local a=(i-1)/12*math.pi*2
        local pos=origin+Vector3.new(math.cos(a)*66,25,math.sin(a)*66)

        -- Keep the four cardinal circulation directions open. Only the
        -- diagonal bays are enclosed; this preserves a room silhouette without
        -- turning the social hub into a tunnel.
        local enclosedBay=i==2 or i==6 or i==8 or i==12
        if enclosedBay then
            local pillar=part(
                hub,
                "AtriumPillar",
                Vector3.new(4.2,26,4.2),
                CFrame.lookAt(pos,origin+Vector3.new(0,25,0)),
                Color3.fromRGB(54,50,75),
                Enum.Material.Metal
            )
            pillar.CanCollide=true

            -- Enclose the remaining bays with acoustic wall panels so the room
            -- reads as an atrium rather than void.
            local panelPos=origin+Vector3.new(math.cos(a)*71,24,math.sin(a)*71)
            local panel=part(
                hub,
                "AcousticWall",
                Vector3.new(24,18,2.4),
                CFrame.lookAt(panelPos,origin+Vector3.new(0,20,0)),
                Color3.fromRGB(29,27,43),
                Enum.Material.Metal
            )
            panel.CanCollide=false
            panel.Transparency=0.02

            -- Secondary ribs break the large dark wall into readable bays.
            for ribIndex=-1,1 do
                local rib=part(
                    hub,
                    "AcousticRib",
                    Vector3.new(2.1,14.5,0.9),
                    panel.CFrame*CFrame.new(ribIndex*7.2,0,-1.45),
                    Color3.fromRGB(68,62,88),
                    Enum.Material.Metal
                )
                rib.CanCollide=false
            end

            local wash=part(
                hub,
                "WallWash",
                Vector3.new(15,0.3,0.5),
                panel.CFrame*CFrame.new(0,6.5,-1.7),
                (i%2==0) and P.cyan or P.violet,
                Enum.Material.Neon
            )
            wash.CanCollide=false
            wash.Transparency=0.55

            local accent=part(
                hub,
                "WallAccent",
                Vector3.new(1.2,17,0.35),
                CFrame.lookAt(panelPos-Vector3.new(0,1,0),origin+Vector3.new(0,23,0))*CFrame.new(0,0,-1.35),
                (i%2==0) and P.cyan or P.violet,
                Enum.Material.Neon
            )
            accent.CanCollide=false
            accent.Transparency=0.38
        end

        if i%3==1 then
            lightAnchor(
                hub,
                "AtriumLight",
                pos+Vector3.new(0,10,0),
                (i%2==0) and P.cyan or P.violet,
                0.8,
                38,
                false
            )
        end
    end

    for i=0,3 do
        local beam=part(
            hub,
            "CeilingBeam",
            Vector3.new(4.5,2.4,112),
            CFrame.new(origin+Vector3.new(0,41,0))*CFrame.Angles(0,math.rad(i*45),0),
            Color3.fromRGB(43,40,61),
            Enum.Material.Metal
        )
        beam.CanCollide=false

        local strip=part(
            hub,
            "CeilingStrip",
            Vector3.new(0.7,0.24,94),
            beam.CFrame*CFrame.new(0,-1.3,0),
            (i%2==0) and P.cyan or P.violet,
            Enum.Material.Neon
        )
        strip.CanCollide=false
        strip.Transparency=0.55
    end

    -- Arrival spine.
    local arrival=part(
        hub,
        "ArrivalSpine",
        Vector3.new(40,1.4,118),
        CFrame.new(origin+Vector3.new(0,9.35,10)),
        Color3.fromRGB(50,46,72),
        Enum.Material.Slate
    )
    arrival.CanCollide=true

    -- Layered floor panels give the spine material rhythm even with neon off.
    for panelIndex=1,7 do
        local z=58-(panelIndex*16)
        local floorPanel=part(
            hub,
            "ArrivalFloorPanel",
            Vector3.new(25.5,0.22,12.5),
            CFrame.new(origin+Vector3.new(0,10.08,z)),
            (panelIndex%2==0) and Color3.fromRGB(62,57,83) or Color3.fromRGB(55,50,75),
            panelIndex%2==0 and Enum.Material.Metal or Enum.Material.Slate
        )
        floorPanel.CanCollide=false

        local seam=part(
            hub,
            "ArrivalFloorSeam",
            Vector3.new(0.28,0.12,10.8),
            CFrame.new(origin+Vector3.new(0,10.22,z)),
            Color3.fromRGB(104,94,128),
            Enum.Material.Metal
        )
        seam.CanCollide=false
    end

    -- A distinct social plaza breaks the arrival route into a destination.
    local socialPlaza=cylinder(
        hub,
        "SocialPlaza",
        Vector3.new(1.1,72,72),
        CFrame.new(origin+Vector3.new(0,9.62,5)),
        Color3.fromRGB(55,50,78),
        Enum.Material.Slate
    )
    socialPlaza.CanCollide=true
    materialRingSegments(
        hub,
        "SocialPlazaTrim",
        origin+Vector3.new(0,10.25,5),
        34,
        28,
        2.0,
        0.38,
        Color3.fromRGB(79,71,105),
        Enum.Material.Metal,
        0.04,
        false
    )
    ringSegments(
        hub,
        "SocialPlazaPulse",
        origin+Vector3.new(0,10.48,5),
        24,
        20,
        0.7,
        0.22,
        P.violet,
        0.58
    )

    equalizerBank(
        hub,
        "SocialEqualizerLeft",
        origin+Vector3.new(-34,10,-2),
        origin+Vector3.new(0,14,5),
        P.coral,
        P.violet,
        7
    )
    equalizerBank(
        hub,
        "SocialEqualizerRight",
        origin+Vector3.new(34,10,-2),
        origin+Vector3.new(0,14,5),
        P.cyan,
        P.violet,
        7
    )

    for side=-1,1,2 do
        local rail=part(
            hub,
            "ArrivalRail",
            Vector3.new(0.9,1.8,118),
            CFrame.new(origin+Vector3.new(side*21,10.45,10)),
            Color3.fromRGB(58,53,79),
            Enum.Material.Metal
        )
        rail.CanCollide=true

        local guide=part(
            hub,
            "ArrivalGuide",
            Vector3.new(0.55,0.24,110),
            CFrame.new(origin+Vector3.new(side*17.5,10.1,10)),
            side<0 and P.coral or P.cyan,
            Enum.Material.Neon
        )
        guide.CanCollide=false
        guide.Transparency=0.16
    end

    local spawn=Instance.new("SpawnLocation")
    spawn.Name="HubSpawn"
    spawn.Size=Vector3.new(18,1,18)
    spawn.CFrame=CFrame.new(Config.hub.spawn)
    spawn.Transparency=1
    spawn.CanCollide=false
    spawn.Anchored=true
    spawn.Neutral=true
    spawn.Duration=0
    spawn.Parent=hub

    -- Main identity wall.
    local identity=part(
        hub,
        "IdentityWall",
        Vector3.new(72,24,3),
        CFrame.new(origin+Vector3.new(0,24,62)),
        P.ink,
        Enum.Material.SmoothPlastic
    )
    surfaceText(identity,"ECHO RIOT",P.cream)
    local sub=part(
        hub,
        "IdentitySub",
        Vector3.new(46,6,2.4),
        CFrame.new(origin+Vector3.new(0,10.5,59.8)),
        P.violet,
        Enum.Material.SmoothPlastic
    )
    surfaceText(sub,"COPY THE CHAOS",P.cream)

    local howTo=part(
        hub,
        "HowToBoard",
        Vector3.new(30,18,2.5),
        CFrame.new(origin+Vector3.new(-43,22,50)),
        P.ink,
        Enum.Material.SmoothPlastic
    )
    surfaceText(
        howTo,
        "HOW TO PLAY\n1  ENTER THE SHOW\n2  LISTEN TO THE SHAPE\n3  COPY IT WITH YOUR VOICE\n4  OUTSCORE THE ROOM",
        P.cream
    )

    local leaderboard=part(
        hub,
        "SessionLeaderboard",
        Vector3.new(30,18,2.5),
        CFrame.new(origin+Vector3.new(43,22,50)),
        P.ink,
        Enum.Material.SmoothPlastic
    )
    local leaderboardStatus=surfaceText(
        leaderboard,
        "SESSION LEADERS\nNO SCORES YET",
        P.yellow
    )

    -- Lounge wings create breathing room and places to socialize.
    local practicePrompt:ProximityPrompt?=nil
    local stylePrompt:ProximityPrompt?=nil
    for side=-1,1,2 do
        local wingCenter=origin+Vector3.new(side*50,9,13)
        cylinder(
            hub,
            "LoungeDeck",
            Vector3.new(4,44,44),
            CFrame.new(wingCenter),
            Color3.fromRGB(49,45,69),
            Enum.Material.Slate
        )
        ringSegments(hub,"LoungeRing",wingCenter+Vector3.new(0,2.3,0),21,18,0.75,0.34,side<0 and P.coral or P.cyan,0.42)
        materialRingSegments(
            hub,
            "LoungeCanopy",
            wingCenter+Vector3.new(0,18,0),
            17.5,
            12,
            4.5,
            1.8,
            Color3.fromRGB(42,39,60),
            Enum.Material.Metal,
            0.04,
            false
        )
        lightAnchor(
            hub,
            "LoungeLight",
            wingCenter+Vector3.new(0,15,0),
            side<0 and Color3.fromRGB(255,174,196) or Color3.fromRGB(154,225,245),
            1.15,
            34,
            true
        )

        -- A low arch makes each side lounge read as a destination from the
        -- central plaza without sealing it off.
        local gateCenter=origin+Vector3.new(side*31,15,13)
        local gateCF=CFrame.lookAt(gateCenter,wingCenter)
        for gateSide=-1,1,2 do
            local post=part(
                hub,
                "LoungeGatePost",
                Vector3.new(2.8,14,3.2),
                gateCF*CFrame.new(gateSide*8,0,0),
                Color3.fromRGB(63,58,84),
                Enum.Material.Metal
            )
            post.CanCollide=false
        end
        local lintel=part(
            hub,
            "LoungeGateTop",
            Vector3.new(18.8,2.8,3.2),
            gateCF*CFrame.new(0,7,0),
            Color3.fromRGB(63,58,84),
            Enum.Material.Metal
        )
        lintel.CanCollide=false
        local gateGlow=part(
            hub,
            "LoungeGateGlow",
            Vector3.new(14,0.35,0.35),
            lintel.CFrame*CFrame.new(0,-1.55,-1.75),
            side<0 and P.coral or P.cyan,
            Enum.Material.Neon
        )
        gateGlow.CanCollide=false
        gateGlow.Transparency=0.38

        local loungeTable=cylinder(
            hub,
            "LoungeTable",
            Vector3.new(3.2,9,9),
            CFrame.new(wingCenter+Vector3.new(0,3.8,0)),
            Color3.fromRGB(67,61,88),
            Enum.Material.Metal
        )
        loungeTable.CanCollide=true

        local tableGlow=cylinder(
            hub,
            "LoungeTableGlow",
            Vector3.new(0.25,7.2,7.2),
            CFrame.new(wingCenter+Vector3.new(0,5.45,0)),
            side<0 and P.coral or P.cyan,
            Enum.Material.Neon
        )
        tableGlow.CanCollide=false
        tableGlow.Transparency=0.38

        for seatIndex=1,4 do
            local a=(seatIndex-1)/4*math.pi*2+math.rad(45)
            local seatPos=wingCenter+Vector3.new(math.cos(a)*12,3.1,math.sin(a)*12)
            local seatCF=CFrame.lookAt(seatPos,wingCenter)
            local seat=part(
                hub,
                "LoungeSeat",
                Vector3.new(9,2.4,5),
                seatCF,
                Color3.fromRGB(70,64,92),
                Enum.Material.SmoothPlastic
            )
            seat.CanCollide=true

            local back=part(
                hub,
                "LoungeBack",
                Vector3.new(9,5.5,1.5),
                seatCF*CFrame.new(0,3,-2.4),
                Color3.fromRGB(59,54,80),
                Enum.Material.SmoothPlastic
            )
            back.CanCollide=false
        end

        local booth=part(
            hub,
            side<0 and "MicPracticeBooth" or "StyleBooth",
            Vector3.new(22,14,4),
            CFrame.new(wingCenter+Vector3.new(0,10,side<0 and 18 or -18)),
            P.ink,
            Enum.Material.SmoothPlastic
        )
        surfaceText(booth,side<0 and "MIC LAB" or "STYLE DECK",side<0 and P.coral or P.cyan)

        -- Tall landmark visible from the central route.
        local beaconPos=origin+Vector3.new(side*41,23,8)
        local beacon=part(
            hub,
            side<0 and "MicLabBeacon" or "StyleDeckBeacon",
            Vector3.new(4.5,24,4.5),
            CFrame.lookAt(beaconPos,origin+Vector3.new(0,18,5)),
            Color3.fromRGB(45,41,64),
            Enum.Material.Metal
        )
        beacon.CanCollide=false
        local beaconCap=part(
            hub,
            "WingBeaconCap",
            Vector3.new(6.2,5.2,6.2),
            beacon.CFrame*CFrame.new(0,14,0),
            side<0 and P.coral or P.cyan,
            Enum.Material.Neon
        )
        beaconCap.CanCollide=false
        beaconCap.Transparency=0.2

        local wingSign=part(
            hub,
            side<0 and "MicLabWayfinding" or "StyleDeckWayfinding",
            Vector3.new(18,6,1.8),
            CFrame.lookAt(
                origin+Vector3.new(side*35,18,12),
                origin+Vector3.new(0,18,5)
            ),
            P.ink,
            Enum.Material.SmoothPlastic
        )
        surfaceText(
            wingSign,
            side<0 and "MIC LAB  ←" or "→  STYLE DECK",
            side<0 and P.coral or P.cyan,
            Enum.NormalId.Back
        )

        if side<0 then
            local practice=Instance.new("ProximityPrompt")
            practice.Name="MicPractice"
            practice.ActionText="Open Mic Lab"
            practice.ObjectText="Practice your energy shape"
            practice.KeyboardKeyCode=Enum.KeyCode.E
            practice.HoldDuration=0
            practice.MaxActivationDistance=12
            practice.RequiresLineOfSight=false
            practice.Parent=booth
            practicePrompt=practice
        else
            local style=Instance.new("ProximityPrompt")
            style.Name="StylePreview"
            style.ActionText="Cycle Style"
            style.ObjectText="Choose your stage accent"
            style.KeyboardKeyCode=Enum.KeyCode.E
            style.HoldDuration=0
            style.MaxActivationDistance=12
            style.RequiresLineOfSight=false
            style.Parent=booth
            stylePrompt=style
        end
    end

    -- Portal concourse.
    local portalPos=Config.hub.portal
    local concourse=part(
        hub,
        "PortalConcourse",
        Vector3.new(64,2,40),
        CFrame.new(portalPos+Vector3.new(0,-1,11)),
        Color3.fromRGB(39,35,62),
        Enum.Material.SmoothPlastic
    )
    concourse.CanCollide=true

    for side=-1,1,2 do
        local towerPos=portalPos+Vector3.new(side*29,13,9)
        speakerTower(
            hub,
            side<0 and "PortalSpeakerLeft" or "PortalSpeakerRight",
            CFrame.lookAt(towerPos,origin+Vector3.new(0,13,-24)),
            side<0 and P.coral or P.cyan
        )


        part(
            hub,
            "PortalPillar",
            Vector3.new(7,36,8),
            CFrame.new(portalPos+Vector3.new(side*23,14,0)),
            Color3.fromRGB(55,50,79),
            Enum.Material.Metal
        )
        local blade=part(
            hub,
            "PortalBlade",
            Vector3.new(2.2,25,3),
            CFrame.new(portalPos+Vector3.new(side*19.2,14,1.2)),
            side<0 and P.coral or P.cyan,
            Enum.Material.Neon
        )
        blade.Transparency=0.12
        blade.CanCollide=false
    end
    part(
        hub,
        "PortalTop",
        Vector3.new(53,7,8),
        CFrame.new(portalPos+Vector3.new(0,31,0)),
        Color3.fromRGB(55,50,79),
        Enum.Material.Metal
    )
    local portalCap=part(
        hub,
        "PortalCapGlow",
        Vector3.new(31,1.4,3),
        CFrame.new(portalPos+Vector3.new(0,23.6,1.2)),
        P.violet,
        Enum.Material.Neon
    )
    portalCap.Transparency=0.16
    portalCap.CanCollide=false

    local portalBack=part(
        hub,
        "PortalBack",
        Vector3.new(38,23,1.2),
        CFrame.new(portalPos+Vector3.new(0,12,-0.2)),
        Color3.fromRGB(13,12,25),
        Enum.Material.SmoothPlastic
    )
    portalBack.CanCollide=false

    local portal=part(
        hub,
        "ShowPortal",
        Vector3.new(34,20,0.55),
        CFrame.new(portalPos+Vector3.new(0,12,1.35)),
        Color3.fromRGB(93,205,230),
        Enum.Material.Glass
    )
    portal.Transparency=0.48
    portal.CanCollide=false

    local portalInner=part(
        hub,
        "PortalInnerGlow",
        Vector3.new(28,15,0.36),
        CFrame.new(portalPos+Vector3.new(0,12,1.72)),
        P.cyan,
        Enum.Material.Neon
    )
    portalInner.Transparency=0.62
    portalInner.CanCollide=false

    local portalTitle=part(
        hub,
        "PortalTitle",
        Vector3.new(54,8,2.4),
        CFrame.new(portalPos+Vector3.new(0,38,3.2)),
        P.ink,
        Enum.Material.SmoothPlastic
    )
    surfaceText(portalTitle,"ENTER THE SHOW",P.yellow,Enum.NormalId.Back)

    local portalSign=part(
        hub,
        "PortalStatus",
        Vector3.new(34,5.4,1.8),
        CFrame.new(portalPos+Vector3.new(0,31.4,3.1)),
        Color3.fromRGB(32,29,48),
        Enum.Material.SmoothPlastic
    )
    local portalStatus=surfaceText(portalSign,"0 / 6 READY",P.cream,Enum.NormalId.Back)

    local console=part(
        hub,
        "QueueConsole",
        Vector3.new(10,5.5,8),
        CFrame.new(portalPos+Vector3.new(0,3.25,12)),
        Color3.fromRGB(49,45,75),
        Enum.Material.SmoothPlastic
    )
    local prompt=Instance.new("ProximityPrompt")
    prompt.Name="JoinShow"
    prompt.ActionText="Enter Show"
    prompt.ObjectText="ECHO RIOT"
    prompt.KeyboardKeyCode=Enum.KeyCode.E
    prompt.HoldDuration=0
    prompt.MaxActivationDistance=12
    prompt.RequiresLineOfSight=false
    prompt.Parent=console

    -- Sparse floor markers guide the eye without turning the whole plaza
    -- into a glowing runway.
    for i=1,8 do
        local z=Config.hub.spawn.Z-(i*12)
        for side=-1,1,2 do
            local marker=part(
                hub,
                "ConcourseMarker",
                Vector3.new(2.2,0.18,5.5),
                CFrame.new(origin+Vector3.new(side*11.5,10.08,z)),
                side<0 and P.coral or P.cyan,
                Enum.Material.Neon
            )
            marker.CanCollide=false
            marker.Transparency=0.24
        end
    end

    lightAnchor(hub,"HubAmbient",origin+Vector3.new(0,38,8),Color3.fromRGB(216,204,255),2.05,112,true)
    lightAnchor(hub,"HubKeyA",origin+Vector3.new(-44,34,28),Color3.fromRGB(255,200,221),1.75,88,true)
    lightAnchor(hub,"HubKeyB",origin+Vector3.new(44,34,8),Color3.fromRGB(174,230,250),1.65,88,true)
    lightAnchor(hub,"HubPortalGlow",portalPos+Vector3.new(0,15,9),P.cyan,1.35,50,false)
    lightAnchor(hub,"HubRearFill",origin+Vector3.new(0,28,58),Color3.fromRGB(212,194,244),1.2,66,true)

    return {
        folder=hub,
        spawn=spawn,
        prompt=prompt,
        portal=portal,
        portalStatus=portalStatus,
        leaderboardStatus=leaderboardStatus,
        practicePrompt=practicePrompt,
        stylePrompt=stylePrompt,
    }
end

local function buildStage(root:Folder,Config:any)
    local P=Config.palette
    local origin=Config.stage.origin
    local stage=Instance.new("Folder")
    stage.Name="Stage"
    stage.Parent=root

    local stageCenter=origin+Vector3.new(0,8,0)
    local envAccents={P.coral,P.cyan,P.violet}
    local podAccents={}

    cylinder(
        stage,
        "UnderStage",
        Vector3.new(14,Config.stage.radius*2+18,Config.stage.radius*2+18),
        CFrame.new(origin+Vector3.new(0,2,0)),
        P.ink,
        Enum.Material.SmoothPlastic
    )
    cylinder(
        stage,
        "MainStage",
        Vector3.new(7,Config.stage.radius*2,Config.stage.radius*2),
        CFrame.new(stageCenter),
        P.ink2,
        Enum.Material.SmoothPlastic
    )

    materialRingSegments(
        stage,
        "OuterRing",
        origin+Vector3.new(0,11.75,0),
        Config.stage.radius-5,
        24,
        2.6,
        0.72,
        Color3.fromRGB(67,61,88),
        Enum.Material.Metal,
        0.04,
        false
    )
    ringSegments(stage,"InnerRing",origin+Vector3.new(0,11.95,0),Config.stage.radius-31,18,1.25,0.42,P.cyan,0.48)

    -- A matte inner floor gives the neon accents something to read against and
    -- prevents the stage from collapsing into one dark circular slab.
    cylinder(
        stage,
        "StageFloorInset",
        Vector3.new(6.9,118,118),
        CFrame.new(origin+Vector3.new(0,8.18,0)),
        Color3.fromRGB(42,38,66),
        Enum.Material.Slate
    )

    -- Six lanes align one-to-one with the six player pods. Environment
    -- color is intentionally limited to coral/cyan/violet so player styles can
    -- remain meaningful instead of competing with rainbow scenery.
    for lane=1,6 do
        local a=(lane-1)/6*math.pi*2+math.rad(30)
        local accent=envAccents[((lane-1)%#envAccents)+1]
        local laneCenter=origin+Vector3.new(math.cos(a)*39,11.9,math.sin(a)*39)
        local laneCF=CFrame.lookAt(laneCenter,origin+Vector3.new(0,11.9,0))
        local lanePart=part(
            stage,
            "StageLane",
            Vector3.new(5.5,0.32,52),
            laneCF,
            Color3.fromRGB(56,51,78),
            Enum.Material.Metal
        )
        lanePart.Transparency=0.04
        lanePart.CanCollide=false

        local laneAccent=part(
            stage,
            "StageLaneAccent",
            Vector3.new(0.55,0.12,38),
            laneCF*CFrame.new(0,0,-2),
            accent,
            Enum.Material.Neon
        )
        laneAccent.Transparency=0.42
        laneAccent.CanCollide=false
    end

    cylinder(
        stage,
        "CenterDaisLower",
        Vector3.new(3.4,42,42),
        CFrame.new(origin+Vector3.new(0,10.1,0)),
        Color3.fromRGB(31,29,48),
        Enum.Material.Metal
    )
    cylinder(
        stage,
        "CenterDaisUpper",
        Vector3.new(2.4,32,32),
        CFrame.new(origin+Vector3.new(0,12.5,0)),
        Color3.fromRGB(50,45,70),
        Enum.Material.Slate
    )
    materialRingSegments(
        stage,
        "CenterDaisTrim",
        origin+Vector3.new(0,14,0),
        19.8,
        20,
        1.15,
        0.42,
        Color3.fromRGB(91,82,118),
        Enum.Material.Metal,
        0.03,
        false
    )

    cylinder(stage,"ResonatorBase",Vector3.new(9,28,28),CFrame.new(origin+Vector3.new(0,16.5,0)),P.ink,Enum.Material.SmoothPlastic)
    ringSegments(stage,"CoreRingA",origin+Vector3.new(0,22.7,0),12.5,20,0.8,0.65,P.yellow,0.12)
    ringSegments(stage,"CoreRingB",origin+Vector3.new(0,25.5,0),8.9,16,0.7,0.55,P.coral,0.14)

    local core=part(stage,"ResonanceCore",Vector3.new(6.5,6.5,6.5),CFrame.new(origin+Vector3.new(0,23.9,0)),P.yellow,Enum.Material.Neon)
    core.Shape=Enum.PartType.Ball
    core.CanCollide=false
    local coreLight=Instance.new("PointLight")
    coreLight.Color=P.yellow
    coreLight.Range=26
    coreLight.Brightness=1.15
    coreLight.Shadows=false
    coreLight.Parent=core

    -- Larger player pods: distinct islands connected by readable bridges.
    local stageSpawns={}
    for i=1,6 do
        local a=(i-1)/6*math.pi*2+math.rad(30)
        local radial=Config.stage.podRadius
        local podCenter=origin+Vector3.new(math.cos(a)*radial,12,math.sin(a)*radial)
        local accent=envAccents[((i-1)%#envAccents)+1]

        cylinder(stage,"Pod"..i,Vector3.new(5.4,22,22),CFrame.new(podCenter),Color3.fromRGB(27,25,43),Enum.Material.Slate)
        local accentPart=cylinder(
            stage,
            "PodAccent"..i,
            Vector3.new(5.7,13.5,13.5),
            CFrame.new(podCenter+Vector3.new(0,0.25,0)),
            accent,
            Enum.Material.SmoothPlastic
        )
        accentPart.Transparency=0.38
        podAccents[i]=accentPart
        ringSegments(stage,"PodHalo"..i,podCenter+Vector3.new(0,3.2,0),12.2,10,0.48,0.34,accent,0.58)

        local bridgeMid=(podCenter+stageCenter)/2
        local delta=Vector3.new(stageCenter.X-podCenter.X,0,stageCenter.Z-podCenter.Z)
        local bridge=part(
            stage,
            "PodBridge"..i,
            Vector3.new(9,1.25,math.max(10,delta.Magnitude-22)),
            CFrame.lookAt(bridgeMid,stageCenter),
            Color3.fromRGB(39,35,60),
            Enum.Material.SmoothPlastic
        )
        bridge.CanCollide=true

        local spawn=Instance.new("SpawnLocation")
        spawn.Name="StageSpawn"..i
        spawn.Size=Vector3.new(8,1,8)
        spawn.CFrame=CFrame.new(podCenter+Vector3.new(0,5,0),stageCenter)
        spawn.Transparency=1
        spawn.CanCollide=false
        spawn.Anchored=true
        spawn.Neutral=true
        spawn.Duration=0
        spawn.Parent=stage
        table.insert(stageSpawns,spawn)
    end

    -- Broadcast arch belongs on the far side of the arena relative to the
    -- canonical show camera. Putting it on the near side occludes the entire
    -- stage because the camera sits outside the -Z edge.
    local front=origin+Vector3.new(0,0,Config.stage.radius+22)
    for side=-1,1,2 do
        part(stage,"ArchPillar",Vector3.new(7,44,7),CFrame.new(front+Vector3.new(side*38,28,0)),Color3.fromRGB(54,49,74),Enum.Material.Metal)
    end
    part(stage,"ArchTop",Vector3.new(84,7,7),CFrame.new(front+Vector3.new(0,47,0)),Color3.fromRGB(54,49,74),Enum.Material.Metal)
    local archAccent=part(
        stage,
        "ArchAccent",
        Vector3.new(62,0.65,1.1),
        CFrame.new(front+Vector3.new(0,43.1,-3.7)),
        P.violet,
        Enum.Material.Neon
    )
    archAccent.Transparency=0.34
    archAccent.CanCollide=false
    local board=part(stage,"MainBoard",Vector3.new(62,26,2.6),CFrame.new(front+Vector3.new(0,31,2)),P.ink,Enum.Material.SmoothPlastic)
    surfaceText(board,"ECHO RIOT",P.cream)

    -- Spectator architecture stays mostly neutral; only small caps carry
    -- ambient color. This keeps player pods and the resonance core dominant.
    for i=1,32 do
        local a=(i-1)/32*math.pi*2
        local radius=Config.stage.spectatorRadius
        local finHeight=11+(i%5)*2.2
        local pos=origin+Vector3.new(math.cos(a)*radius,17+((i%4)*2.2),math.sin(a)*radius)
        local accent=envAccents[((i-1)%#envAccents)+1]
        local fin=part(
            stage,
            "SpectatorFin",
            Vector3.new(3.2,finHeight,5.5),
            CFrame.new(pos)*CFrame.Angles(0,-a+math.pi/2,math.rad((i%2==0) and 5 or -5)),
            Color3.fromRGB(38,35,55),
            Enum.Material.Metal
        )
        fin.CanCollide=false

        local cap=part(
            stage,
            "SpectatorCap",
            Vector3.new(3.4,0.85,5.8),
            CFrame.new(pos+Vector3.new(0,finHeight*0.5+0.45,0))*CFrame.Angles(0,-a+math.pi/2,0),
            accent,
            Enum.Material.Neon
        )
        cap.Transparency=0.24
        cap.CanCollide=false

        if i%4==0 then
            lightAnchor(stage,"AudienceGlow",pos+Vector3.new(0,finHeight*0.5+2,0),accent,0.32,18,false)
        end
    end

    -- Suspended light rig creates a ceiling reference and keeps the show
    -- volume from reading as an empty void.
    ringSegments(stage,"OverheadRig",origin+Vector3.new(0,49,0),58,32,1.8,0.65,Color3.fromRGB(82,75,120),0.08)
    ringSegments(stage,"OverheadLight",origin+Vector3.new(0,48.6,0),51,28,0.75,0.30,P.violet,0.28)
    for rigIndex=1,8 do
        local a=(rigIndex-1)/8*math.pi*2
        local rigPos=origin+Vector3.new(math.cos(a)*58,31,math.sin(a)*58)
        local drop=part(
            stage,
            "RigDrop",
            Vector3.new(1.2,34,1.2),
            CFrame.new(rigPos),
            Color3.fromRGB(55,50,82),
            Enum.Material.Metal
        )
        drop.CanCollide=false
    end

    lightAnchor(stage,"StageKeyA",origin+Vector3.new(-68,52,-58),Color3.fromRGB(255,196,218),1.25,105,true)
    lightAnchor(stage,"StageKeyB",origin+Vector3.new(68,50,-42),Color3.fromRGB(171,225,255),1.2,105,true)
    lightAnchor(stage,"StageFill",origin+Vector3.new(0,44,72),Color3.fromRGB(203,181,255),0.92,115,true)

    return {
        folder=stage,
        core=core,
        spawns=stageSpawns,
        podAccents=podAccents,
        center=stageCenter,
    }
end

local function configureLighting()
    Lighting.Brightness=3.0
    Lighting.Ambient=Color3.fromRGB(45,40,66)
    Lighting.OutdoorAmbient=Color3.fromRGB(40,36,58)
    Lighting.EnvironmentDiffuseScale=0.55
    Lighting.EnvironmentSpecularScale=0.72

    local bloom=Lighting:FindFirstChildOfClass("BloomEffect") or Instance.new("BloomEffect")
    bloom.Intensity=0.14
    bloom.Size=18
    bloom.Threshold=2.05
    bloom.Parent=Lighting

    local correction=Lighting:FindFirstChildOfClass("ColorCorrectionEffect") or Instance.new("ColorCorrectionEffect")
    correction.Brightness=0.015
    correction.Contrast=0.11
    correction.Saturation=0.07
    correction.TintColor=Color3.fromRGB(255,247,255)
    correction.Parent=Lighting

    local atmosphere=Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
    atmosphere.Density=0.12
    atmosphere.Offset=0.08
    atmosphere.Color=Color3.fromRGB(180,162,222)
    atmosphere.Decay=Color3.fromRGB(44,35,67)
    atmosphere.Haze=0.58
    atmosphere.Parent=Lighting
end

function World.build(Config:any)
    local previous=Workspace:FindFirstChild("EchoRiotWorld")
    if previous then previous:Destroy() end

    local root=Instance.new("Folder")
    root.Name="EchoRiotWorld"
    root.Parent=Workspace

    configureLighting()
    local hub=buildHub(root,Config)
    local stage=buildStage(root,Config)

    return {
        root=root,
        hub=hub,
        stage=stage,
        hubSpawn=hub.spawn,
        portalPrompt=hub.prompt,
        practicePrompt=hub.practicePrompt,
        portal=hub.portal,
        portalStatus=hub.portalStatus,
        leaderboardStatus=hub.leaderboardStatus,
        stylePrompt=hub.stylePrompt,
        core=stage.core,
        stageSpawns=stage.spawns,
        podAccents=stage.podAccents,
        stageCenter=stage.center,
    }
end

return World
