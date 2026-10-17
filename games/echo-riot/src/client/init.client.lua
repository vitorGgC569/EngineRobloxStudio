--!strict
local Players=game:GetService("Players")
local ReplicatedStorage=game:GetService("ReplicatedStorage")
local RunService=game:GetService("RunService")
local TweenService=game:GetService("TweenService")
local Workspace=game:GetService("Workspace")
local SoundService=game:GetService("SoundService")
local UserInputService=game:GetService("UserInputService")

local Forge=require(ReplicatedStorage:WaitForChild("Forge"))
local Net=Forge.Net
local Feel=Forge.Feel
local Visual=Forge.Visual
local Access=Forge.Access
local Config=require(ReplicatedStorage.Shared.Config)
local P=Config.palette
local player=Players.LocalPlayer
local gui=player:WaitForChild("PlayerGui")

Net.define({
    Phase={dir="s2c"},
    Score={dir="s2c"},
    Board={dir="s2c"},
    Chaos={dir="s2c"},
    Pulse={dir="s2c"},
    Sample={dir="c2s",rate=14},
    Submit={dir="c2s",rate=3},
    Ready={dir="c2s",rate=4},
    Join={dir="c2s",rate=2},
    Leave={dir="c2s",rate=2},
    HubAction={dir="c2s",rate=4,shape={action="string"}},
})

Feel.mount()
Visual.autoQuality()
Access.followSystem()

local screen=Instance.new("ScreenGui")
screen.Name="EchoRiotUI"
screen.ResetOnSpawn=false
screen.IgnoreGuiInset=true
screen.DisplayOrder=20
screen.Parent=gui

local function corner(object:GuiObject,radius:number)
    local c=Instance.new("UICorner")
    c.CornerRadius=UDim.new(0,radius)
    c.Parent=object
end

local function outline(object:GuiObject,color:Color3,thickness:number?,transparency:number?)
    local s=Instance.new("UIStroke")
    s.Color=color
    s.Thickness=thickness or 1
    s.Transparency=transparency or 0
    s.Parent=object
end

local function gradient(object:GuiObject,a:Color3,b:Color3,rotation:number?)
    local g=Instance.new("UIGradient")
    g.Color=ColorSequence.new(a,b)
    g.Rotation=rotation or 0
    g.Parent=object
end

local function makeLabel(parent:Instance,textValue:string,size:number,bold:boolean?):TextLabel
    local label=Instance.new("TextLabel")
    label.BackgroundTransparency=1
    label.Text=textValue
    label.TextColor3=P.cream
    label.Font=bold and Enum.Font.GothamBlack or Enum.Font.GothamMedium
    label.TextSize=size
    label.Parent=parent
    return label
end

local brand=Instance.new("Frame")
brand.Name="Brand"
brand.Position=UDim2.fromOffset(22,20)
brand.Size=UDim2.fromOffset(196,50)
brand.BackgroundColor3=P.ink
brand.BackgroundTransparency=0.30
brand.Parent=screen
corner(brand,15)
outline(brand,P.violet,1,0.58)

local brandTitle=makeLabel(brand,"ECHO RIOT",20,true)
brandTitle.Position=UDim2.fromOffset(14,5)
brandTitle.Size=UDim2.fromOffset(170,24)
brandTitle.TextXAlignment=Enum.TextXAlignment.Left
gradient(brandTitle,P.coral,P.cyan,0)

local brandSub=makeLabel(brand,"COPY THE CHAOS",10,true)
brandSub.Position=UDim2.fromOffset(15,29)
brandSub.Size=UDim2.fromOffset(166,14)
brandSub.TextColor3=Color3.fromRGB(190,184,211)
brandSub.TextXAlignment=Enum.TextXAlignment.Left

local roundPill=Instance.new("Frame")
roundPill.Name="RoundPill"
roundPill.AnchorPoint=Vector2.new(1,0)
roundPill.Position=UDim2.new(1,-22,0,20)
roundPill.Size=UDim2.fromOffset(138,34)
roundPill.BackgroundColor3=P.ink
roundPill.BackgroundTransparency=0.28
roundPill.Parent=screen
corner(roundPill,17)
outline(roundPill,P.cyan,1,0.58)

local roundText=makeLabel(roundPill,"ROUND 0 / 4",14,true)
roundText.Size=UDim2.fromScale(1,1)

local timerPill=Instance.new("Frame")
timerPill.Name="TimerPill"
timerPill.AnchorPoint=Vector2.new(0.5,0)
timerPill.Position=UDim2.new(0.5,0,0,258)
timerPill.Size=UDim2.fromOffset(92,30)
timerPill.BackgroundColor3=P.ink
timerPill.BackgroundTransparency=0.24
timerPill.Parent=screen
corner(timerPill,18)
outline(timerPill,P.yellow,1.5,0.35)

local timerText=makeLabel(timerPill,"",13,true)
timerText.Size=UDim2.fromScale(1,1)

local leaveButton=Instance.new("TextButton")
leaveButton.Name="LeaveShow"
leaveButton.AnchorPoint=Vector2.new(0,1)
leaveButton.Position=UDim2.new(0,22,1,-26)
leaveButton.Size=UDim2.fromOffset(126,42)
leaveButton.BackgroundColor3=P.ink
leaveButton.Text="LEAVE SHOW"
leaveButton.TextColor3=P.cream
leaveButton.TextSize=12
leaveButton.Font=Enum.Font.GothamBold
leaveButton.AutoButtonColor=false
leaveButton.Visible=false
leaveButton.Parent=screen
corner(leaveButton,18)
outline(leaveButton,P.coral,1.5,0.3)

local card=Instance.new("Frame")
card.Name="RoundCard"
card.AnchorPoint=Vector2.new(0.5,0)
card.Position=UDim2.new(0.5,0,0,32)
card.Size=UDim2.fromOffset(448,180)
card.BackgroundColor3=P.ink
card.BackgroundTransparency=0.14
card.Parent=screen
corner(card,22)
outline(card,P.cream,1,0.90)

local phasePill=Instance.new("TextLabel")
phasePill.AnchorPoint=Vector2.new(0.5,0)
phasePill.Position=UDim2.new(0.5,0,0,12)
phasePill.Size=UDim2.fromOffset(130,26)
phasePill.BackgroundColor3=P.violet
phasePill.Text="LOBBY"
phasePill.TextColor3=P.cream
phasePill.Font=Enum.Font.GothamBlack
phasePill.TextSize=11
phasePill.Parent=card
corner(phasePill,16)

local prompt=makeLabel(card,"WAITING FOR PLAYERS",22,true)
prompt.AnchorPoint=Vector2.new(0.5,0)
prompt.Position=UDim2.new(0.5,0,0,45)
prompt.Size=UDim2.fromOffset(408,34)

local hint=makeLabel(card,"The stage is warming up.",12,false)
hint.AnchorPoint=Vector2.new(0.5,0)
hint.Position=UDim2.new(0.5,0,0,79)
hint.Size=UDim2.fromOffset(400,20)
hint.TextColor3=Color3.fromRGB(191,186,207)

local waveform=Instance.new("Frame")
waveform.Name="Waveform"
waveform.Position=UDim2.fromOffset(22,108)
waveform.Size=UDim2.fromOffset(404,48)
waveform.BackgroundColor3=P.ink2
waveform.BackgroundTransparency=0.24
waveform.Parent=card
corner(waveform,14)

local bars:{Frame}={}
for i=1,24 do
    local bar=Instance.new("Frame")
    bar.Name="Bar"..i
    bar.AnchorPoint=Vector2.new(0,0.5)
    bar.Position=UDim2.new((i-1)/24,4,0.5,0)
    bar.Size=UDim2.new(1/24,-7,0,6)
    bar.BackgroundColor3=P.cyan
    bar.BorderSizePixel=0
    bar.Parent=waveform
    corner(bar,4)
    table.insert(bars,bar)
end

local board=Instance.new("Frame")
board.Name="Scoreboard"
board.AnchorPoint=Vector2.new(1,0.5)
board.Position=UDim2.new(1,-22,0.55,0)
board.Size=UDim2.fromOffset(218,248)
board.BackgroundColor3=P.ink
board.BackgroundTransparency=0.20
board.Parent=screen
corner(board,18)
outline(board,P.violet,1,0.65)

local boardTitle=makeLabel(board,"SCOREBOARD",14,true)
boardTitle.Position=UDim2.fromOffset(14,12)
boardTitle.Size=UDim2.fromOffset(188,20)
boardTitle.TextXAlignment=Enum.TextXAlignment.Left

local rowsFrame=Instance.new("Frame")
rowsFrame.Position=UDim2.fromOffset(10,40)
rowsFrame.Size=UDim2.fromOffset(198,196)
rowsFrame.BackgroundTransparency=1
rowsFrame.Parent=board

local rowLayout=Instance.new("UIListLayout")
rowLayout.Padding=UDim.new(0,4)
rowLayout.Parent=rowsFrame

local scoreRows:{Frame}={}

local chaos=Instance.new("Frame")
chaos.Name="ChaosCard"
chaos.Position=UDim2.fromOffset(22,102)
chaos.Size=UDim2.fromOffset(204,72)
chaos.BackgroundColor3=P.ink
chaos.BackgroundTransparency=0.24
chaos.Parent=screen
corner(chaos,16)
outline(chaos,P.coral,1,0.62)

local chaosTag=makeLabel(chaos,"CHAOS CARD",10,true)
chaosTag.Position=UDim2.fromOffset(13,8)
chaosTag.Size=UDim2.fromOffset(178,13)
chaosTag.TextColor3=P.coral
chaosTag.TextXAlignment=Enum.TextXAlignment.Left

local chaosTitle=makeLabel(chaos,"CLEAN ROUND",14,true)
chaosTitle.Position=UDim2.fromOffset(13,23)
chaosTitle.Size=UDim2.fromOffset(178,21)
chaosTitle.TextXAlignment=Enum.TextXAlignment.Left

local chaosDesc=makeLabel(chaos,"No tricks. Just copy the shape.",11,false)
chaosDesc.Position=UDim2.fromOffset(13,45)
chaosDesc.Size=UDim2.fromOffset(178,20)
chaosDesc.TextWrapped=true
chaosDesc.TextXAlignment=Enum.TextXAlignment.Left
chaosDesc.TextYAlignment=Enum.TextYAlignment.Top
chaosDesc.TextColor3=Color3.fromRGB(193,188,209)

local capture=Instance.new("Frame")
capture.AnchorPoint=Vector2.new(0.5,1)
capture.Position=UDim2.new(0.5,0,1,-26)
capture.Size=UDim2.fromOffset(392,62)
capture.BackgroundColor3=P.ink
capture.BackgroundTransparency=0.18
capture.Parent=screen
corner(capture,18)
outline(capture,P.cyan,1,0.58)

local micDot=Instance.new("Frame")
micDot.Position=UDim2.fromOffset(14,17)
micDot.Size=UDim2.fromOffset(28,28)
micDot.BackgroundColor3=P.coral
micDot.Parent=capture
corner(micDot,14)

local micGlyph=makeLabel(micDot,"●",16,true)
micGlyph.Size=UDim2.fromScale(1,1)
micGlyph.TextColor3=P.cream

local captureTitle=makeLabel(capture,"MIC CHECK",14,true)
captureTitle.Position=UDim2.fromOffset(54,11)
captureTitle.Size=UDim2.fromOffset(220,19)
captureTitle.TextXAlignment=Enum.TextXAlignment.Left

local captureHint=makeLabel(capture,"Checking microphone…",11,false)
captureHint.Position=UDim2.fromOffset(54,31)
captureHint.Size=UDim2.fromOffset(250,18)
captureHint.TextXAlignment=Enum.TextXAlignment.Left
captureHint.TextColor3=Color3.fromRGB(190,185,206)

local meter=Instance.new("Frame")
meter.AnchorPoint=Vector2.new(1,0.5)
meter.Position=UDim2.new(1,-14,0.5,0)
meter.Size=UDim2.fromOffset(62,8)
meter.BackgroundColor3=P.ink2
meter.Parent=capture
corner(meter,6)

local meterFill=Instance.new("Frame")
meterFill.Size=UDim2.fromScale(0.08,1)
meterFill.BackgroundColor3=P.cyan
meterFill.Parent=meter
corner(meterFill,6)

local toast=makeLabel(screen,"",15,true)
toast.AnchorPoint=Vector2.new(0.5,0.5)
toast.Position=UDim2.fromScale(0.5,0.46)
toast.Size=UDim2.fromOffset(420,48)
toast.BackgroundTransparency=0.08
toast.BackgroundColor3=P.ink
toast.Visible=false
corner(toast,18)
outline(toast,P.yellow,1.5,0.2)

local hubGuide=Instance.new("Frame")
hubGuide.AnchorPoint=Vector2.new(0.5,1)
hubGuide.Position=UDim2.new(0.5,0,1,-28)
hubGuide.Size=UDim2.fromOffset(520,76)
hubGuide.BackgroundColor3=P.ink
hubGuide.BackgroundTransparency=0.06
hubGuide.Parent=screen
corner(hubGuide,22)
outline(hubGuide,P.violet,2,0.28)

local hubTitle=makeLabel(hubGuide,"ENTER THE SHOW",16,true)
hubTitle.Position=UDim2.fromOffset(18,12)
hubTitle.Size=UDim2.new(1,-188,0,24)
hubTitle.TextXAlignment=Enum.TextXAlignment.Left

local hubHint=makeLabel(hubGuide,"Explore, warm up, then enter when your group is ready.",11,false)
hubHint.Position=UDim2.fromOffset(18,39)
hubHint.Size=UDim2.new(1,-188,0,22)
hubHint.TextXAlignment=Enum.TextXAlignment.Left
hubHint.TextColor3=Color3.fromRGB(194,188,211)

local hubEnterButton=Instance.new("TextButton")
hubEnterButton.Name="EnterShowButton"
hubEnterButton.AnchorPoint=Vector2.new(1,0.5)
hubEnterButton.Position=UDim2.new(1,-14,0.5,0)
hubEnterButton.Size=UDim2.fromOffset(154,46)
hubEnterButton.BackgroundColor3=P.violet
hubEnterButton.Text="ENTER SHOW"
hubEnterButton.TextColor3=P.cream
hubEnterButton.TextSize=12
hubEnterButton.Font=Enum.Font.GothamBlack
hubEnterButton.AutoButtonColor=false
hubEnterButton.Parent=hubGuide
corner(hubEnterButton,16)
outline(hubEnterButton,P.cyan,1.5,0.35)

local function applyStyle()
    local index=tonumber(player:GetAttribute("EchoStyleIndex")) or 1
    local style=Config.styles[math.clamp(index,1,#Config.styles)]
    local accent=style and style.color or P.coral

    local brandStroke=brand:FindFirstChildOfClass("UIStroke")
    if brandStroke then brandStroke.Color=accent end
    local roundStroke=roundPill:FindFirstChildOfClass("UIStroke")
    if roundStroke then roundStroke.Color=accent end
    local hubStroke=hubGuide:FindFirstChildOfClass("UIStroke")
    if hubStroke then hubStroke.Color=accent end
    hubTitle.TextColor3=accent

    local character=player.Character
    if character then
        local existing=character:FindFirstChild("EchoStyleHighlight")
        local highlight=existing and existing:IsA("Highlight") and existing or Instance.new("Highlight")
        highlight.Name="EchoStyleHighlight"
        highlight.FillColor=accent
        highlight.FillTransparency=0.82
        highlight.OutlineColor=accent
        highlight.OutlineTransparency=0.12
        highlight.DepthMode=Enum.HighlightDepthMode.Occluded
        highlight.Parent=character
    end
end

local currentPhase="LOBBY"
local currentTarget:{number}={}
local currentChaosId="clean"
local captureSamples:{number}={}
local answerDeadline=0
local answerDuration=Config.answerSeconds
local answerToken=""
local sampleSeq=0
local lastSampleSent=0
local phaseDeadline=0
local analyzer:AudioAnalyzer?=nil
local micInput:AudioDeviceInput?=nil
local micReady=false
local practice=true
local answering=false
local cameraTween:Tween?=nil

local function stageCameraFor(phaseName:string)
    local camera=Workspace.CurrentCamera
    if not camera then return end

    local zone=tostring(player:GetAttribute("EchoZone") or "HUB")
    local onStage=zone=="STAGE"
    if not onStage then
        if cameraTween then cameraTween:Cancel();cameraTween=nil end
        camera.CameraType=Enum.CameraType.Custom
        camera.FieldOfView=70
        return
    end

    local stageOrigin=Config.stage.origin
    local targetPosition=stageOrigin+Vector3.new(0,44,-112)
    local targetLook=stageOrigin+Vector3.new(0,16,2)
    local fov=58

    if phaseName=="ANSWER" then
        local character=player.Character
        local root=character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
        if root then
            local flat=Vector3.new(root.Position.X-stageOrigin.X,0,root.Position.Z-stageOrigin.Z)
            if flat.Magnitude<1 then flat=Vector3.new(0,0,-1) end
            local outward=flat.Unit
            targetPosition=root.Position+outward*22+Vector3.new(0,12,0)
            targetLook=root.Position+Vector3.new(0,4,0)
            fov=52
        end
    elseif phaseName=="RESULTS" then
        targetPosition=stageOrigin+Vector3.new(0,54,-132)
        targetLook=stageOrigin+Vector3.new(0,16,4)
        fov=61
    elseif phaseName=="COUNTDOWN" or phaseName=="BOARDING" then
        targetPosition=stageOrigin+Vector3.new(0,50,-124)
        targetLook=stageOrigin+Vector3.new(0,14,0)
        fov=60
    end

    camera.CameraType=Enum.CameraType.Scriptable
    local goal=CFrame.lookAt(targetPosition,targetLook)
    if cameraTween then cameraTween:Cancel() end
    cameraTween=TweenService:Create(
        camera,
        TweenInfo.new(0.7,Enum.EasingStyle.Quint,Enum.EasingDirection.Out),
        {CFrame=goal,FieldOfView=fov}
    )
    cameraTween:Play()
end

local referenceSound=Instance.new("Sound")
referenceSound.Name="EchoRiotReference"
referenceSound.SoundId="rbxasset://sounds/electronicpingshort.wav"
referenceSound.Volume=0.42
referenceSound.Parent=SoundService

local function playReferencePulse(value:number)
    if value<0.12 then return end
    referenceSound:Stop()
    referenceSound.TimePosition=0
    referenceSound.Volume=0.16+math.clamp(value,0,1)*0.44
    referenceSound.PlaybackSpeed=0.68+math.clamp(value,0,1)*0.82
    referenceSound:Play()
end

local function showToast(textValue:string,color:Color3?)
    toast.Text=textValue
    toast.TextColor3=color or P.cream
    toast.Visible=true
    toast.TextTransparency=1
    TweenService:Create(toast,TweenInfo.new(0.14),{TextTransparency=0}):Play()
    local stamp=os.clock()
    toast:SetAttribute("stamp",stamp)
    task.delay(2.2,function()
        if toast:GetAttribute("stamp")==stamp then toast.Visible=false end
    end)
end

local function setBars(values:{number},color:Color3)
    if #values==0 then
        for _,bar in bars do
            bar.Size=UDim2.new(1/24,-7,0,6)
            bar.BackgroundColor3=color
        end
        return
    end

    for i,bar in bars do
        local source=math.clamp(
            math.floor((i-1)/math.max(#bars-1,1)*math.max(#values-1,1))+1,
            1,
            #values
        )
        local value=math.clamp(values[source] or 0,0,1)
        bar.Size=UDim2.new(1/24,-7,0,math.max(6,50*value))
        bar.BackgroundColor3=color
    end
end

local function setupMic()
    captureHint.Text="CHECKING MICROPHONE..."
    practice=true
    micReady=false

    -- Studio/RQE automation has no trustworthy microphone permission surface.
    -- Keep it deterministic instead of probing restricted AudioDeviceInput state.
    if RunService:IsStudio() then
        captureHint.Text="STUDIO PRACTICE · simulated envelope · max 65 pts"
        micDot.BackgroundColor3=P.coral
        return
    end

    local existing=player:FindFirstChildOfClass("AudioDeviceInput")
    if existing then
        micInput=existing
    end

    if not micInput then
        local ok,result=pcall(function()
            local input=Instance.new("AudioDeviceInput")
            input.Name="EchoRiotMic"
            input.Player=player
            input.Parent=player
            return input
        end)
        if ok and result then
            micInput=result
        end
    end

    if not micInput then
        captureHint.Text="MICROPHONE UNAVAILABLE"
        micDot.BackgroundColor3=P.coral
        return
    end

    local audioAnalyzer=Instance.new("AudioAnalyzer")
    audioAnalyzer.Name="EchoRiotAnalyzer"
    audioAnalyzer.SpectrumEnabled=false
    audioAnalyzer.Parent=micInput

    local wire=Instance.new("Wire")
    wire.Name="EchoRiotMicWire"
    wire.SourceInstance=micInput
    wire.TargetInstance=audioAnalyzer
    wire.Parent=audioAnalyzer

    analyzer=audioAnalyzer
    micReady=true
    practice=false
    captureHint.Text="MIC CONNECTED · rhythm + intensity scoring"
    micDot.BackgroundColor3=P.mint
end

setupMic()

local function practiceValue(t:number):number
    if #currentTarget==0 then return 0.12 end
    local index=math.clamp(math.floor(t*#currentTarget)+1,1,#currentTarget)
    local base=currentTarget[index] or 0.2
    return math.clamp(base*0.78+math.sin(t*19)*0.08+0.04,0,1)
end

RunService.RenderStepped:Connect(function()
    local now=os.clock()
    local level=0

    if analyzer and micReady and not practice then
        level=math.clamp(math.sqrt(math.max(0,analyzer.RmsLevel))*2.4,0,1)
    elseif answering then
        local t=math.clamp(1-(answerDeadline-now)/math.max(answerDuration,0.1),0,1)
        level=practiceValue(t)
    end

    meterFill.Size=UDim2.fromScale(math.max(0.04,level),1)

    if phaseDeadline>0 and currentPhase~="LOBBY" then
        local remaining=math.max(0,phaseDeadline-now)
        timerText.Text=("%.1fs"):format(remaining)
    else
        timerText.Text=""
    end

    if answering then
        if #captureSamples<96 then
            table.insert(captureSamples,level)
        end

        if answerToken~="" and now-lastSampleSent>=0.095 then
            lastSampleSent=now
            sampleSeq+=1
            Net.send("Sample",{
                token=answerToken,
                seq=sampleSeq,
                value=level,
                source=practice and "practice" or "microphone",
            })
        end
    end
end)

local function refreshZoneUI()
    local onStage=tostring(player:GetAttribute("EchoZone") or "HUB")=="STAGE" or player:GetAttribute("EchoReady")==true
    local practiceMode=player:GetAttribute("EchoPracticeMode")==true
    local camera=Workspace.CurrentCamera

    local showBoard=onStage and (currentPhase=="REVEAL" or currentPhase=="RESULTS")
    local showChaos=onStage and (
        currentPhase=="COUNTDOWN"
        or currentPhase=="LISTEN"
        or currentPhase=="ANSWER"
        or currentPhase=="REVEAL"
    )

    card.Visible=onStage
    chaos.Visible=showChaos
    capture.Visible=onStage or practiceMode
    board.Visible=showBoard and (not camera or camera.ViewportSize.X>=820)
    roundPill.Visible=onStage
    timerPill.Visible=onStage and currentPhase~="LOBBY" and currentPhase~="RESULTS"
    leaveButton.Visible=onStage
    hubGuide.Visible=not onStage

    local canJoin=currentPhase=="LOBBY" or currentPhase=="BOARDING"
    hubEnterButton.Active=(not onStage) and canJoin
    hubEnterButton.BackgroundColor3=canJoin and P.violet or P.ink2
    hubEnterButton.Text=canJoin and "ENTER SHOW" or "SHOW LIVE"

    if not onStage then
        answering=false
        answerToken=""
        captureSamples={}
        hubTitle.Text=currentPhase=="BOARDING" and "BOARDING OPEN" or "ENTER THE SHOW"
        hubHint.Text=currentPhase=="BOARDING"
            and "The portal is open for this group · step through before boarding closes."
            or "Explore the hub · use the portal console when your group is ready."

        if practiceMode then
            captureTitle.Text="MIC LAB"
            captureHint.Text=micReady
                and "Live microphone meter · use this space to warm up."
                or "Microphone unavailable · practice mode only."
        end
    end
end

local function beginAnswer(seconds:number,token:string)
    if tostring(player:GetAttribute("EchoZone") or "HUB")~="STAGE" then return end

    answering=true
    answerDuration=seconds
    answerToken=token
    answerDeadline=os.clock()+seconds
    sampleSeq=0
    lastSampleSent=0
    captureSamples={}

    captureTitle.Text=practice and "PRACTICE INPUT" or "YOUR TURN · MAKE THE SHAPE"
    micDot.BackgroundColor3=P.coral

    task.delay(seconds,function()
        if not answering or answerToken~=token then return end

        answering=false
        micDot.BackgroundColor3=(micReady and not practice) and P.mint or P.coral
        captureTitle.Text="SUBMITTED"

        Net.send("Submit",{
            token=token,
            source=practice and "practice" or "microphone",
        })
        answerToken=""
    end)
end

Net.on("Phase",function(data)
    currentPhase=data.phase or "LOBBY"
    local payload=data.payload or {}
    local seconds=tonumber(payload.seconds) or 0
    phaseDeadline=seconds>0 and (os.clock()+seconds) or 0

    if data.chaos then
        currentChaosId=tostring(data.chaos.id or "clean")
    end

    if currentPhase~="ANSWER" then
        answering=false
        answerToken=""
    end

    refreshZoneUI()
    stageCameraFor(currentPhase)
    phasePill.Text=currentPhase
    roundText.Text=("ROUND %d / %d"):format(data.round or 0,data.totalRounds or Config.rounds)

    if data.pattern then
        currentTarget=data.pattern.envelope or {}
        prompt.Text=data.pattern.label or "COPY THE SHAPE"
    end

    if currentPhase=="LOBBY" then
        prompt.Text="THE STAGE IS OPEN"
        hint.Text="Explore, warm up, style up, then enter the show."
        setBars({},P.cyan)
    elseif currentPhase=="BOARDING" then
        prompt.Text="BOARDING"
        hint.Text="Your group is arriving · find your pod."
        hubTitle.Text="BOARDING OPEN"
        hubHint.Text="The portal is open for this group · step through before boarding closes."
    elseif currentPhase=="COUNTDOWN" then
        prompt.Text="GET READY"
        hint.Text="One listen. One response."
    elseif currentPhase=="LISTEN" then
        hint.Text=currentChaosId=="reverse"
            and "LISTEN · MIRROR MODE means perform it backwards"
            or "LISTEN · remember the attacks and pauses"
        setBars(currentTarget,P.yellow)
        captureTitle.Text="LISTEN FIRST"
    elseif currentPhase=="ANSWER" then
        hint.Text=currentChaosId=="reverse"
            and "MIRROR IT · perform the shape backwards"
            or "NOW COPY IT · rhythm and intensity matter"
        setBars({},currentChaosId=="reverse" and P.violet or P.cyan)
        beginAnswer(seconds>0 and seconds or Config.answerSeconds,tostring(payload.token or ""))
    elseif currentPhase=="REVEAL" then
        hint.Text="SCORES ARE IN"
        captureTitle.Text="ROUND LOCKED"
    elseif currentPhase=="INTERMISSION" then
        prompt.Text="CHAOS LOADING"
        hint.Text="The next modifier is being dealt."
    elseif currentPhase=="RESULTS" then
        prompt.Text="FINAL RIOT"
        hint.Text="Top score owns the stage."
    end
end)

Net.on("Pulse",function(data)
    if currentPhase~="LISTEN" or #currentTarget==0 then return end
    playReferencePulse(tonumber(data.value) or 0)
    local pulseIndex=data.index or 1
    local fraction=pulseIndex/math.max(#currentTarget,1)

    for i,bar in bars do
        local source=math.clamp(math.floor((i-1)/23*math.max(#currentTarget-1,1))+1,1,#currentTarget)
        local base=currentTarget[source] or 0
        local boosted=(math.abs(i-fraction*24)<2) and math.min(1,base+0.25) or base
        bar.Size=UDim2.new(1/24,-7,0,math.max(6,50*boosted))
    end
end)

Net.on("Chaos",function(data)
    chaosTitle.Text=data.label or "CLEAN ROUND"
    chaosDesc.Text=data.description or ""
    showToast(data.label or "CHAOS CARD",P.coral)
end)

Net.on("Score",function(data)
    if data.userId==player.UserId then
        local value=tonumber(data.value) or 0
        local verdict
        if value>=140 then
            verdict="DOUBLE RIOT"
        elseif value>=75 then
            verdict="NAILED IT"
        elseif value>=50 then
            verdict="CLOSE"
        elseif value<=0 then
            verdict="MISSED"
        else
            verdict="CHAOS"
        end
        showToast(
            ("+%d · %s"):format(value,verdict),
            value>=75 and P.mint or value<=0 and P.coral or P.yellow
        )
    end
end)

local function requestJoin()
    if tostring(player:GetAttribute("EchoZone") or "HUB")~="HUB" then return end
    if not hubEnterButton.Active then return end

    hubEnterButton.Active=false
    hubEnterButton.Text="JOINING..."
    Net.send("Join",{})

    task.delay(1,function()
        hubEnterButton.Active=true
        hubEnterButton.Text="ENTER SHOW"
    end)
end

hubEnterButton.Activated:Connect(requestJoin)

local function requestLeave()
    if tostring(player:GetAttribute("EchoZone") or "HUB")~="STAGE" then return end
    if not leaveButton.Active then return end

    leaveButton.Active=false
    leaveButton.Text="LEAVING..."
    Net.send("Leave",{})

    task.delay(1,function()
        leaveButton.Active=true
        leaveButton.Text="LEAVE SHOW · L"
    end)
end

leaveButton.Text="LEAVE SHOW · L"
leaveButton.Activated:Connect(requestLeave)

UserInputService.InputBegan:Connect(function(input,gameProcessed)
    if gameProcessed then return end

    if input.KeyCode==Enum.KeyCode.L then
        requestLeave()
        return
    end

    if tostring(player:GetAttribute("EchoZone") or "HUB")~="HUB" then
        return
    end

    if input.KeyCode==Enum.KeyCode.M then
        Net.send("HubAction",{action="practice_toggle"})
    elseif input.KeyCode==Enum.KeyCode.C then
        Net.send("HubAction",{action="cycle_style"})
    end
end)

Net.on("Board",function(data)
    for _,row in scoreRows do row:Destroy() end
    table.clear(scoreRows)

    for index,item in ipairs(data.rows or {}) do
        local row=Instance.new("Frame")
        row.Size=UDim2.new(1,0,0,28)
        row.BackgroundColor3=index==1 and Color3.fromRGB(53,45,79) or P.ink2
        row.Parent=rowsFrame
        corner(row,12)

        local rank=makeLabel(row,tostring(index),12,true)
        rank.Position=UDim2.fromOffset(10,0)
        rank.Size=UDim2.fromOffset(22,28)
        rank.TextColor3=index==1 and P.yellow or Color3.fromRGB(175,169,195)

        local name=makeLabel(row,item.name or "Player",12,true)
        name.Position=UDim2.fromOffset(34,0)
        name.Size=UDim2.fromOffset(112,28)
        name.TextXAlignment=Enum.TextXAlignment.Left

        local score=makeLabel(row,tostring(item.score or 0),13,true)
        score.AnchorPoint=Vector2.new(1,0)
        score.Position=UDim2.new(1,-10,0,0)
        score.Size=UDim2.fromOffset(46,28)
        score.TextXAlignment=Enum.TextXAlignment.Right
        score.TextColor3=index==1 and P.yellow or P.cyan

        table.insert(scoreRows,row)
    end
end)

local function fit()
    local camera=Workspace.CurrentCamera
    if not camera then return end

    local width=camera.ViewportSize.X
    local height=camera.ViewportSize.Y
    local narrow=width<820
    local phone=width<560
    local short=height<680

    local onStage=tostring(player:GetAttribute("EchoZone") or "HUB")=="STAGE" or player:GetAttribute("EchoReady")==true
    local showBoard=onStage and (currentPhase=="REVEAL" or currentPhase=="RESULTS")
    board.Visible=showBoard and not narrow

    if phone then
        brand.Position=UDim2.fromOffset(12,12)
        brand.Size=UDim2.fromOffset(156,44)
        roundPill.Position=UDim2.new(1,-12,0,12)
        roundPill.Size=UDim2.fromOffset(112,32)

        card.Position=UDim2.new(0.5,0,0,68)
        card.Size=UDim2.fromOffset(math.max(304,width-24),170)
        phasePill.Size=UDim2.fromOffset(116,24)
        prompt.Position=UDim2.new(0.5,0,0,42)
        prompt.Size=UDim2.new(1,-28,0,30)
        prompt.TextSize=19
        hint.Position=UDim2.new(0.5,0,0,73)
        hint.Size=UDim2.new(1,-34,0,20)
        hint.TextSize=10
        waveform.Position=UDim2.fromOffset(14,103)
        waveform.Size=UDim2.new(1,-28,0,43)

        timerPill.Position=UDim2.new(0.5,0,0,246)
        timerPill.Size=UDim2.fromOffset(84,28)

        chaos.Position=UDim2.fromOffset(12,286)
        chaos.Size=UDim2.fromOffset(176,68)
        capture.Size=UDim2.fromOffset(math.max(304,width-24),60)
        capture.Position=UDim2.new(0.5,0,1,-18)

        hubGuide.Size=UDim2.fromOffset(math.max(320,width-24),72)
        hubGuide.Position=UDim2.new(0.5,0,1,-18)

        leaveButton.Position=UDim2.new(0,12,1,-98)
        leaveButton.Size=UDim2.fromOffset(112,38)
    else
        brand.Position=UDim2.fromOffset(22,20)
        brand.Size=UDim2.fromOffset(narrow and 178 or 196,50)
        roundPill.Position=UDim2.new(1,-22,0,20)
        roundPill.Size=UDim2.fromOffset(narrow and 124 or 138,34)

        card.Position=UDim2.new(0.5,0,0,30)
        card.Size=UDim2.fromOffset(narrow and 380 or 448,180)
        phasePill.Size=UDim2.fromOffset(130,26)
        prompt.Position=UDim2.new(0.5,0,0,45)
        prompt.Size=UDim2.fromOffset(narrow and 338 or 408,34)
        prompt.TextSize=22
        hint.Position=UDim2.new(0.5,0,0,79)
        hint.Size=UDim2.fromOffset(narrow and 338 or 400,20)
        hint.TextSize=12
        waveform.Position=UDim2.fromOffset(22,108)
        waveform.Size=UDim2.fromOffset(narrow and 336 or 404,48)

        timerPill.Position=UDim2.new(0.5,0,0,220)
        timerPill.Size=UDim2.fromOffset(92,30)

        chaos.Position=UDim2.fromOffset(22,86)
        chaos.Size=UDim2.fromOffset(narrow and 188 or 204,72)
        capture.Size=UDim2.fromOffset(narrow and 350 or 392,62)
        capture.Position=UDim2.new(0.5,0,1,-26)
        hubGuide.Size=UDim2.fromOffset(narrow and 420 or 520,76)
        hubGuide.Position=UDim2.new(0.5,0,1,-28)

        leaveButton.Position=UDim2.new(0,22,1,-26)
        leaveButton.Size=UDim2.fromOffset(126,42)
    end

    if short and onStage then
        chaos.Visible=false
    end
end

local camera=Workspace.CurrentCamera
if camera then
    camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
end
fit()
refreshZoneUI()
stageCameraFor(currentPhase)

player:GetAttributeChangedSignal("EchoZone"):Connect(function()
    refreshZoneUI()
    fit()
    stageCameraFor(currentPhase)
end)

player:GetAttributeChangedSignal("EchoPortalStatus"):Connect(function()
    local status=tostring(player:GetAttribute("EchoPortalStatus") or "IDLE")
    if status=="JOINED" then
        showToast("WELCOME TO THE SHOW",P.mint)
    elseif status=="SHOW_FULL" then
        showToast("SHOW FULL · WAIT FOR THE NEXT ROUND",P.yellow)
    elseif status=="SHOW_IN_PROGRESS" then
        showToast("SHOW IN PROGRESS · NEXT BOARDING SOON",P.yellow)
    end
end)

player:GetAttributeChangedSignal("EchoPracticeMode"):Connect(function()
    refreshZoneUI()
    local enabled=player:GetAttribute("EchoPracticeMode")==true
    showToast(enabled and "MIC LAB OPEN" or "MIC LAB CLOSED",enabled and P.cyan or P.cream)
end)

player:GetAttributeChangedSignal("EchoStyleIndex"):Connect(function()
    applyStyle()
    local label=tostring(player:GetAttribute("EchoStyleName") or "STYLE")
    showToast(label,P.cream)
end)

player.CharacterAdded:Connect(function()
    task.defer(applyStyle)
end)

applyStyle()

task.spawn(function()
    local worldFolder=Workspace:WaitForChild("EchoRiotWorld",30)
    if not worldFolder then return end
    local hub=worldFolder:WaitForChild("Hub",30)
    if not hub then return end

    local micBooth=hub:WaitForChild("MicPracticeBooth",30)
    local styleBooth=hub:WaitForChild("StyleBooth",30)

    local micPrompt=micBooth and micBooth:WaitForChild("MicPractice",30)
    local stylePrompt=styleBooth and styleBooth:WaitForChild("StylePreview",30)

    if micPrompt and micPrompt:IsA("ProximityPrompt") then
        micPrompt.Triggered:Connect(function()
            Net.send("HubAction",{action="practice_toggle"})
        end)
    end

    if stylePrompt and stylePrompt:IsA("ProximityPrompt") then
        stylePrompt.Triggered:Connect(function()
            Net.send("HubAction",{action="cycle_style"})
        end)
    end
end)

task.delay(0.5,function()
    Net.send("Ready",{})
end)

print("[EchoRiot] client ready")
