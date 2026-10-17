--!strict
local Players=game:GetService("Players")
local ReplicatedStorage=game:GetService("ReplicatedStorage")

local Forge=require(ReplicatedStorage:WaitForChild("Forge"))
Forge.require("0.2.0")
local Net=Forge.Net
local Debug=Forge.Debug

local Config=require(ReplicatedStorage.Shared.Config)
local World=require(script:WaitForChild("World"))

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

type AnswerBuffer={
    token:string,
    samples:{number},
    lastSeq:number,
    source:string,
}

local P=Config.palette
local world=World.build(Config)
local worldRoot:Folder=world.root
local worldCore:BasePart=world.core

local round=0
local showId=0
local phase="LOBBY"
local boardingSecondsLeft=0
local currentPattern:any=nil
local currentChaos:any=nil
local answerToken=""
local updatePortalStatus:(()->())?=nil

local showScores:{[Player]:number}={}
local sessionScores:{[Player]:number}={}
local ready:{[Player]:boolean}={}
local submitted:{[Player]:boolean}={}
local stageSlot:{[Player]:SpawnLocation}={}
local answers:{[Player]:AnswerBuffer}={}

local function isFinite(value:any):boolean
    return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge
end

local function normalize(samples:{number}):{number}
    local peak=0
    for _,value in samples do
        peak=math.max(peak,math.abs(value))
    end
    if peak<0.01 then return table.clone(samples) end

    local output={}
    for index,value in samples do
        output[index]=math.clamp(value/peak,0,1)
    end
    return output
end

local function scoreEnvelope(target:{number},samples:{number},chaosId:string):number
    if #samples<4 then return 0 end

    local normalized=normalize(samples)
    local aligned={}
    for index=1,#target do
        local t=(index-1)/math.max(#target-1,1)
        local sourceIndex=math.clamp(
            math.floor(t*math.max(#normalized-1,1))+1,
            1,
            #normalized
        )
        aligned[index]=normalized[sourceIndex] or 0
    end

    local errorSum=0
    local weightSum=0
    for index=1,#target do
        local weight=1
        if chaosId=="pulse" and target[index]>0.65 then
            weight=1.8
        end
        errorSum+=math.abs(target[index]-aligned[index])*weight
        weightSum+=weight
    end

    local similarity=math.clamp(1-(errorSum/math.max(weightSum,1)),0,1)
    return math.floor((similarity^1.25)*100+0.5)
end

local function readyPlayers():{Player}
    local result={}
    for _,player in Players:GetPlayers() do
        if ready[player] then
            table.insert(result,player)
        end
    end
    table.sort(result,function(a,b) return a.UserId<b.UserId end)
    return result
end

local function activeParticipants(snapshot:{Player}):{Player}
    local result={}
    for _,player in snapshot do
        if player.Parent and ready[player] then
            table.insert(result,player)
        end
    end
    return result
end

local function scoreRows(source:{[Player]:number}):{{name:string,userId:number,score:number}}
    local rows={}
    for _,player in Players:GetPlayers() do
        table.insert(rows,{
            name=player.DisplayName,
            userId=player.UserId,
            score=source[player] or 0,
        })
    end
    table.sort(rows,function(a,b)
        if a.score==b.score then return a.userId<b.userId end
        return a.score>b.score
    end)
    return rows
end

local function updateHubLeaderboard()
    if not world.leaderboardStatus then return end
    local rows=scoreRows(sessionScores)
    local lines={"SESSION LEADERS"}
    local inserted=0
    for _,row in rows do
        if row.score>0 then
            inserted+=1
            table.insert(lines,("%d  %s  ·  %d"):format(inserted,row.name,row.score))
            if inserted>=3 then break end
        end
    end
    if inserted==0 then
        table.insert(lines,"NO SCORES YET")
    end
    world.leaderboardStatus.Text=table.concat(lines,"\n")
end

local function broadcastBoard()
    Net.fireAll("Board",{
        rows=scoreRows(showScores),
        round=round,
        totalRounds=Config.rounds,
        showId=showId,
    })
    updateHubLeaderboard()
end

local function setPhase(nextPhase:string,payload:any?)
    phase=nextPhase
    if updatePortalStatus then updatePortalStatus() end
    Net.fireAll("Phase",{
        phase=nextPhase,
        round=round,
        totalRounds=Config.rounds,
        showId=showId,
        pattern=currentPattern,
        chaos=currentChaos,
        payload=payload,
    })
end

updatePortalStatus=function()
    local queued=#readyPlayers()
    local portal=world.portal
    local prompt=world.portalPrompt

    if phase=="LOBBY" then
        world.portalStatus.Text=("%d / %d READY"):format(queued,Config.maxPlayers)
        portal.Color=P.cyan
        portal.Transparency=0.42
        prompt.Enabled=true
        prompt.ActionText="Enter Show"
    elseif phase=="BOARDING" then
        world.portalStatus.Text=("BOARDING · %ds  ·  %d/%d"):format(
            boardingSecondsLeft,
            queued,
            Config.maxPlayers
        )
        portal.Color=P.mint
        portal.Transparency=0.26
        prompt.Enabled=true
        prompt.ActionText="Join Boarding"
    elseif phase=="RESULTS" then
        world.portalStatus.Text="RESULTS LIVE · NEXT SHOW SOON"
        portal.Color=P.yellow
        portal.Transparency=0.58
        prompt.Enabled=false
    else
        world.portalStatus.Text="SHOW IN PROGRESS · NEXT BOARDING SOON"
        portal.Color=P.violet
        portal.Transparency=0.66
        prompt.Enabled=false
    end
end

local function setHubState(player:Player,reason:string?)
    ready[player]=nil
    stageSlot[player]=nil
    answers[player]=nil
    submitted[player]=nil

    player:SetAttribute("EchoReady",false)
    player:SetAttribute("EchoZone","HUB")
    player:SetAttribute("EchoPortalStatus","IDLE")
    player:SetAttribute("EchoLastTransition","HUB:"..tostring(reason or "unspecified"))
    player:SetAttribute("EchoTransitionClock",os.clock())
    player.RespawnLocation=world.hubSpawn

    local character=player.Character
    if character then
        character:PivotTo(world.hubSpawn.CFrame+Vector3.new(0,4,0))
    end

    if updatePortalStatus then updatePortalStatus() end
end

local function setStageState(player:Player,slotIndex:number,reason:string?)
    local spawns=world.stageSpawns
    if #spawns==0 then return end

    local podIndex=((slotIndex-1)%#spawns)+1
    local spawn=spawns[podIndex]
    ready[player]=true
    stageSlot[player]=spawn

    local styleIndex=tonumber(player:GetAttribute("EchoStyleIndex")) or 1
    local style=Config.styles[math.clamp(styleIndex,1,#Config.styles)]
    local podAccent=world.podAccents and world.podAccents[podIndex]
    if style and podAccent then
        podAccent.Color=style.color
    end

    player:SetAttribute("EchoReady",true)
    player:SetAttribute("EchoZone","STAGE")
    player:SetAttribute("EchoPortalStatus","JOINED")
    player:SetAttribute("EchoLastTransition","STAGE:"..tostring(reason or "unspecified"))
    player:SetAttribute("EchoTransitionClock",os.clock())
    player.RespawnLocation=spawn

    local character=player.Character
    if character then
        character:PivotTo(spawn.CFrame+Vector3.new(0,4,0))
    end

    if updatePortalStatus then updatePortalStatus() end
end

local function placeReadyPlayersOnStage()
    for index,player in readyPlayers() do
        setStageState(player,index,"boarding_assign")
    end
end

local function returnEveryoneToHub()
    for _,player in Players:GetPlayers() do
        setHubState(player,"show_complete")
    end
end

local function shuffledIndices(count:number,rng:Random):{number}
    local indices={}
    for index=1,count do indices[index]=index end
    for index=count,2,-1 do
        local swap=rng:NextInteger(1,index)
        indices[index],indices[swap]=indices[swap],indices[index]
    end
    return indices
end

local function targetForCurrentRound():{number}
    local target=table.clone(currentPattern.envelope)
    if currentChaos.id=="reverse" then
        local reversed={}
        for index=#target,1,-1 do
            table.insert(reversed,target[index])
        end
        target=reversed
    end
    return target
end

local function finalizeAnswer(player:Player,missed:boolean?)
    if submitted[player] then return end
    submitted[player]=true

    local buffer=answers[player]
    local value=0
    local source="none"

    if buffer and not missed and #buffer.samples>=4 then
        source=buffer.source
        value=scoreEnvelope(targetForCurrentRound(),buffer.samples,currentChaos.id)

        if currentChaos.id=="double" then
            value=value*2
        end

        -- Practice input is an accessibility/Studio fallback, never a route to
        -- competitive session scores.
        if source=="practice" then
            value=math.min(value,65)
        end
    end

    showScores[player]=(showScores[player] or 0)+value

    -- Practice mode remains useful for Studio/offline dogfood, but never
    -- contaminates the competitive session leaderboard.
    local competitiveValue=source=="practice" and 0 or value
    sessionScores[player]=(sessionScores[player] or 0)+competitiveValue

    player:SetAttribute("EchoRoundScore",value)
    player:SetAttribute("EchoScore",showScores[player])
    player:SetAttribute("EchoSessionScore",sessionScores[player])
    player:SetAttribute("EchoInputSource",source)

    Net.fireAll("Score",{
        player=player.DisplayName,
        userId=player.UserId,
        value=value,
        total=showScores[player],
        sessionTotal=sessionScores[player],
        source=source,
        missed=(value==0),
    })
    broadcastBoard()
end

Net.on("Ready",function(player,_payload)
    player:SetAttribute("EchoClientReady",true)
end)

Net.on("Sample",function(player,payload)
    if phase~="ANSWER" or not ready[player] or submitted[player] then return end
    if type(payload)~="table" then return end

    local buffer=answers[player]
    if not buffer then return end

    local token=payload.token
    local seq=payload.seq
    local value=payload.value
    local source=payload.source

    if token~=buffer.token then return end
    if not isFinite(seq) or seq%1~=0 or seq<=buffer.lastSeq or seq>128 then return end
    if not isFinite(value) then return end
    if source~="microphone" and source~="practice" then return end

    if buffer.source=="unknown" then
        buffer.source=source
    elseif buffer.source~=source then
        return
    end

    buffer.lastSeq=seq
    if #buffer.samples<64 then
        table.insert(buffer.samples,math.clamp(value,0,1))
    end
end)

Net.on("Submit",function(player,payload)
    if phase~="ANSWER" or not ready[player] or submitted[player] then return end
    if type(payload)~="table" then return end

    local buffer=answers[player]
    if not buffer or payload.token~=buffer.token then return end
    finalizeAnswer(player,false)
end)

Net.on("Leave",function(player,_payload)
    if ready[player] then
        setHubState(player,"leave_button")
        player:SetAttribute("EchoPortalStatus","LEFT_SHOW")
    end
end)

local function runGame()
    while true do
        while #readyPlayers()<1 do
            setPhase("LOBBY",{hub=true})
            task.wait(0.75)
        end

        boardingSecondsLeft=math.max(1,math.floor(Config.boardingSeconds))
        setPhase("BOARDING",{seconds=boardingSecondsLeft})
        for remaining=boardingSecondsLeft,1,-1 do
            boardingSecondsLeft=remaining
            if updatePortalStatus then updatePortalStatus() end
            if #readyPlayers()<1 then break end
            task.wait(1)
        end
        boardingSecondsLeft=0

        local participants=readyPlayers()
        if #participants<1 then
            setPhase("LOBBY",{hub=true})
            task.wait(0.5)
            continue
        end

        showId+=1
        placeReadyPlayersOnStage()

        for _,player in participants do
            showScores[player]=0
            player:SetAttribute("EchoScore",0)
            player:SetAttribute("EchoRoundScore",0)
        end
        broadcastBoard()

        setPhase("COUNTDOWN",{seconds=Config.countdownSeconds,players=#participants})
        task.wait(Config.countdownSeconds)

        local rng=Random.new(showId*9973+#participants*71)
        local patternBag=shuffledIndices(#Config.patterns,rng)
        local chaosBag=shuffledIndices(#Config.chaos,rng)
        local aborted=false

        for index=1,Config.rounds do
            local active=activeParticipants(participants)
            if #active<1 then
                aborted=true
                break
            end

            round=index
            submitted={}
            answers={}

            currentPattern=Config.patterns[patternBag[((index-1)%#patternBag)+1]]
            currentChaos=Config.chaos[chaosBag[((index-1)%#chaosBag)+1]]
            Net.fireAll("Chaos",currentChaos)

            setPhase("LISTEN",{seconds=Config.listenSeconds})
            for pulse,value in currentPattern.envelope do
                Net.fireAll("Pulse",{
                    index=pulse,
                    value=value,
                    count=#currentPattern.envelope,
                })
                worldCore.Color=P.yellow:Lerp(P.coral,math.clamp(value,0,1))
                task.wait(Config.listenSeconds/#currentPattern.envelope)
            end

            active=activeParticipants(participants)
            if #active<1 then
                aborted=true
                break
            end

            local answerSeconds=(currentChaos.id=="tiny") and 2.8 or Config.answerSeconds
            answerToken=("%d:%d:%08x"):format(
                showId,
                round,
                rng:NextInteger(0,0x7fffffff)
            )

            for _,player in active do
                answers[player]={
                    token=answerToken,
                    samples={},
                    lastSeq=0,
                    source="unknown",
                }
            end

            setPhase("ANSWER",{
                seconds=answerSeconds,
                token=answerToken,
            })
            task.wait(answerSeconds+0.35)

            for _,player in active do
                if player.Parent and ready[player] and not submitted[player] then
                    local buffer=answers[player]
                    finalizeAnswer(player,not buffer or #buffer.samples<4)
                end
            end

            setPhase("REVEAL",{seconds=Config.revealSeconds})
            task.wait(Config.revealSeconds)

            if index<Config.rounds then
                setPhase("INTERMISSION",{seconds=Config.intermissionSeconds})
                task.wait(Config.intermissionSeconds)
            end
        end

        if aborted then
            setPhase("RESULTS",{aborted=true,rows=scoreRows(showScores)})
            task.wait(2)
        else
            setPhase("RESULTS",{rows=scoreRows(showScores)})
            task.wait(8)
        end

        returnEveryoneToHub()
        round=0
        currentPattern=nil
        currentChaos=nil
        answerToken=""
        answers={}
        setPhase("LOBBY",{hub=true})
        task.wait(1.5)
    end
end

local function withinPromptRange(player:Player,prompt:ProximityPrompt?):boolean
    if not prompt or not prompt.Enabled then return false end
    local anchor=prompt.Parent
    local character=player.Character
    local root=character and character:FindFirstChild("HumanoidRootPart")
    if not root or not root:IsA("BasePart") or not anchor or not anchor:IsA("BasePart") then
        return false
    end
    return (root.Position-anchor.Position).Magnitude<=prompt.MaxActivationDistance+2
end

Net.on("HubAction",function(player,payload)
    if tostring(player:GetAttribute("EchoZone") or "HUB")~="HUB" then return end

    local action=payload.action
    if action=="practice_toggle" then
        if not withinPromptRange(player,world.practicePrompt) then return end
        player:SetAttribute(
            "EchoPracticeMode",
            not (player:GetAttribute("EchoPracticeMode")==true)
        )
        return
    end

    if action=="cycle_style" then
        if not withinPromptRange(player,world.stylePrompt) then return end

        local current=tonumber(player:GetAttribute("EchoStyleIndex")) or 0
        local nextIndex=(current%#Config.styles)+1
        local style=Config.styles[nextIndex]

        player:SetAttribute("EchoStyleIndex",nextIndex)
        player:SetAttribute("EchoStyleName",style.label)
    end
end)

local function joinShow(player:Player,source:string)
    if tostring(player:GetAttribute("EchoZone") or "HUB")~="HUB" then
        player:SetAttribute("EchoPortalStatus","ALREADY_JOINED")
        return
    end
    if phase~="LOBBY" and phase~="BOARDING" then
        player:SetAttribute("EchoPortalStatus","SHOW_IN_PROGRESS")
        return
    end
    if ready[player] then
        player:SetAttribute("EchoPortalStatus","ALREADY_JOINED")
        return
    end

    local queued=readyPlayers()
    if #queued>=Config.maxPlayers then
        player:SetAttribute("EchoPortalStatus","SHOW_FULL")
        return
    end

    setStageState(player,#queued+1,source)
end

world.portalPrompt.Triggered:Connect(function(player:Player)
    joinShow(player,"portal")
end)

Net.on("Join",function(player,_payload)
    joinShow(player,"hud")
end)

local function initializePlayer(player:Player)
    showScores[player]=showScores[player] or 0
    sessionScores[player]=sessionScores[player] or 0

    player:SetAttribute("EchoReady",false)
    player:SetAttribute("EchoClientReady",false)
    player:SetAttribute("EchoZone","HUB")
    player:SetAttribute("EchoPortalStatus","IDLE")
    player:SetAttribute("EchoPracticeMode",false)
    player:SetAttribute("EchoStyleIndex",1)
    player:SetAttribute("EchoStyleName",Config.styles[1].label)
    player:SetAttribute("EchoScore",0)
    player:SetAttribute("EchoSessionScore",sessionScores[player])
    player:SetAttribute("EchoRoundScore",0)
    player:SetAttribute("EchoInputSource","none")
    player:SetAttribute("EchoLastTransition","HUB:initialize")
    player:SetAttribute("EchoTransitionClock",os.clock())
    player.RespawnLocation=world.hubSpawn

    player.CharacterAdded:Connect(function(character)
        task.defer(function()
            if ready[player] and stageSlot[player] then
                character:PivotTo(stageSlot[player].CFrame+Vector3.new(0,4,0))
            else
                character:PivotTo(world.hubSpawn.CFrame+Vector3.new(0,4,0))
            end
        end)
    end)

    if player.Character then
        player.Character:PivotTo(world.hubSpawn.CFrame+Vector3.new(0,4,0))
    end

    task.delay(1,broadcastBoard)
end

Players.PlayerAdded:Connect(initializePlayer)

Players.PlayerRemoving:Connect(function(player)
    showScores[player]=nil
    sessionScores[player]=nil
    ready[player]=nil
    submitted[player]=nil
    stageSlot[player]=nil
    answers[player]=nil
    if updatePortalStatus then updatePortalStatus() end
    updateHubLeaderboard()
end)

for _,player in Players:GetPlayers() do
    initializePlayer(player)
end

updatePortalStatus()
updateHubLeaderboard()

Debug.expose()
Debug.probe("echo-riot.state",function()
    return {
        phase=phase,
        round=round,
        showId=showId,
        players=#Players:GetPlayers(),
        ready=#readyPlayers(),
        worldReady=worldRoot.Parent~=nil,
        answerTokenActive=(answerToken~=""),
    }
end)

task.spawn(runGame)
print("[EchoRiot] server ready")
