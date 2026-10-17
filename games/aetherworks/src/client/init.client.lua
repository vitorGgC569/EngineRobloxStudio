local RS=game:GetService("ReplicatedStorage")
local Players=game:GetService("Players")
local RunService=game:GetService("RunService")
local UserInputService=game:GetService("UserInputService")
local GuiService=game:GetService("GuiService")
local CollectionService=game:GetService("CollectionService")
local ContextActionService=game:GetService("ContextActionService")
local Forge=require(RS:WaitForChild("Forge"))
local C=require(RS.Shared.TycoonConfig)
local P=C.colors
local Net,UI,Feel,Audio=Forge.Net,Forge.UI,Forge.Feel,Forge.Audio
Net.define(C.net)
local player=Players.LocalPlayer
pcall(function() game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList,false) end)
local state={coins=0,bank=0,level=0,rate=0,stars=0,contract=1,contractProgress=0,perks={}}
local settings={sound=true,motion=true,graphics=true}
local hasStarted=false
local expedition,rewards,industry,research,collection,habitat
UI.theme.color.bg=P.ink;UI.theme.color.panel=P.panel;UI.theme.color.text=P.text;UI.theme.color.textDim=P.muted
UI.theme.color.accent=P.mint;UI.theme.color.gold=P.gold;UI.theme.color.stroke=Color3.fromRGB(69,100,103)
UI.theme.font.body=Font.new("rbxasset://fonts/families/GothamSSm.json",Enum.FontWeight.Medium)
UI.theme.font.bold=Font.new("rbxasset://fonts/families/GothamSSm.json",Enum.FontWeight.Bold);UI.theme.font.title=UI.theme.font.bold
Feel.mount();Audio.defineMany(require(RS.Forge.Audio.Bank).specs());Audio.setVolume("master",.35)
local screen=UI.mount("AetherworksHUD",{ignoreInset=false})
local function label(parent,text,x,y,w,h,size,color,bold)
    return UI.label(parent,text,{pos=UDim2.fromOffset(x,y),frameSize=UDim2.fromOffset(w,h),size=size or 13,color=color or P.text,font=if bold then UI.theme.font.bold else UI.theme.font.body})
end
local function panel(parent,name,w,h,x,y)
    return UI.panel(parent,{name=name,size=UDim2.fromOffset(w,h),pos=UDim2.fromOffset(x,y),color=P.panel,radius=12,transparency=.07,strokeColor=Color3.fromRGB(81,113,113)})
end
local function button(parent,name,text,x,y,w,h,color,fn)
    local b=Instance.new("TextButton");b.Name=name;b.Size=UDim2.fromOffset(w,h);b.Position=UDim2.fromOffset(x,y);b.BorderSizePixel=0;b.BackgroundColor3=color or P.mint;b.TextColor3=P.ink;b.Text=text;b.FontFace=UI.theme.font.bold;b.TextSize=12;b.AutoButtonColor=true;b.Selectable=true;b.Parent=parent;UI.corner(b,9)
    b.Activated:Connect(function() Audio.play("ui.click");fn() end)
    return b
end
local brand=label(screen,"A E T H E R W O R K S",18,8,242,25,14,P.text,true)
local money=panel(screen,"Wallet",230,64,0,0);money.AnchorPoint=Vector2.new(1,0);money.Position=UDim2.new(1,-18,0,8)
local coins=label(money,"¤ 100",13,7,210,27,23,P.gold,true)
local rate=label(money,"+0/s · coletor ¤ 0",13,40,210,17,11,P.mint)
local eventPanel=panel(screen,"Aurora",266,49,0,0);eventPanel.AnchorPoint=Vector2.new(.5,0);eventPanel.Position=UDim2.new(.5,0,0,10)
local domination=label(eventPanel,"CENTRO NEUTRO · G",8,27,250,17,10,P.text,true);domination.TextXAlignment=Enum.TextXAlignment.Center
local eventText=label(eventPanel,"AURORA EM 04:00",8,5,250,20,10,P.mint,true);eventText.TextXAlignment=Enum.TextXAlignment.Center
local quest=panel(screen,"Contracts",270,163,18,84);quest.Visible=false
label(quest,"CONTRATO DA ILHA",14,12,224,20,10,P.mint,true)
local questName=label(quest,"",14,41,242,25,16,P.text,true)
local questDesc=label(quest,"",14,74,240,34,12,P.muted);questDesc.TextWrapped=true
local questTrack=UI.bar(quest,{name="Progress",size=UDim2.fromOffset(240,5),pos=UDim2.fromOffset(14,120),color=P.mint})
local questCount=label(quest,"",14,133,241,19,11,P.gold)
button(quest,"CloseContracts","×",232,9,26,26,P.muted,function() quest.Visible=false end)
local construction=panel(screen,"Construction",290,437,0,0);construction.AnchorPoint=Vector2.new(1,0);construction.Position=UDim2.new(1,-18,0,84);construction.Visible=false
label(construction,"CONSTRUA SEU HORIZONTE",16,13,236,20,10,P.mint,true)
button(construction,"CloseConstruction","×",251,9,26,26,P.muted,function() construction.Visible=false end)
local preview=Instance.new("ViewportFrame");preview.Name="MachinePreview";preview.Size=UDim2.fromOffset(258,137);preview.Position=UDim2.fromOffset(16,46);preview.BackgroundColor3=Color3.fromRGB(43,72,76);preview.BorderSizePixel=0;preview.Ambient=Color3.fromRGB(180,202,202);preview.LightColor=Color3.fromRGB(255,235,205);preview.LightDirection=Vector3.new(-1,-1,-.5);preview.Parent=construction;UI.corner(preview,10)
local previewCamera=Instance.new("Camera");previewCamera.FieldOfView=35;previewCamera.Parent=preview;preview.CurrentCamera=previewCamera
local previewIndex=-1
local function setPreview(index)
    if previewIndex==index then return end;previewIndex=index
    local previous=preview:FindFirstChild("PreviewModel");if previous then previous:Destroy() end
    local book=RS:FindFirstChild("AetherPreviews");local source=book and book:FindFirstChild("Machine_"..index);if not source then previewIndex=-1;return end
    local clone=source:Clone();clone.Name="PreviewModel";clone.Parent=preview
    for _,d in clone:GetDescendants() do if d:IsA("ParticleEmitter") then d.Enabled=false end end
    local cf,size=clone:GetBoundingBox();local distance=math.max(size.X,size.Y,size.Z)*1.9
    previewCamera.CFrame=CFrame.lookAt(cf.Position+Vector3.new(distance*.7,distance*.5,distance*.85),cf.Position)
end
local nextName=label(construction,"Extrator de brisa",16,195,258,25,18,P.text,true)
local nextDesc=label(construction,"",16,229,256,36,12,P.muted);nextDesc.TextWrapped=true
local nextRate=label(construction,"",16,275,258,19,11,P.mint,true)
local buildButton=button(construction,"Build","CONSTRUIR",16,305,258,44,P.gold,function()
    local u=C.upgrades[state.level+1];if u then Net.send("Buy",{id=u.id}) else construction.Visible=false;expedition:openLegacy() end
end)
button(construction,"MachineMenu","M · MELHORAR MÁQUINAS ∞",16,359,258,32,P.mint,function() construction.Visible=false;industry:open("machines") end)
local progressTitle=label(construction,"",16,402,258,21,11,P.muted)
local settingsPanel=panel(screen,"Settings",270,202,0,0);settingsPanel.AnchorPoint=Vector2.new(.5,.5);settingsPanel.Position=UDim2.fromScale(.5,.5);settingsPanel.Visible=false;settingsPanel.ZIndex=15
label(settingsPanel,"DO SEU JEITO",16,14,220,20,13,P.text,true)
local soundButton,motionButton,graphicsButton
soundButton=button(settingsPanel,"Sound","SOM: LIGADO",16,48,238,36,P.cream,function()
    settings.sound=not settings.sound;Audio.setVolume("master",if settings.sound then .35 else 0);soundButton.Text=if settings.sound then "SOM: LIGADO" else "SOM: DESLIGADO"
end)
motionButton=button(settingsPanel,"Motion","MOVIMENTO: COMPLETO",16,93,238,36,P.cream,function()
    settings.motion=not settings.motion;motionButton.Text=if settings.motion then "MOVIMENTO: COMPLETO" else "MOVIMENTO: REDUZIDO"
end)
graphicsButton=button(settingsPanel,"Graphics","LUZ: CINEMATOGRÁFICA",16,138,238,36,P.cream,function()
    settings.graphics=not settings.graphics
    for _,effect in game:GetService("Lighting"):GetChildren() do if effect:IsA("PostEffect") then effect.Enabled=settings.graphics end end
    graphicsButton.Text=if settings.graphics then "LUZ: CINEMATOGRÁFICA" else "LUZ: SIMPLES"
end)
button(settingsPanel,"CloseSettings","×",231,10,26,26,P.muted,function() settingsPanel.Visible=false end)
for _,obj in settingsPanel:GetDescendants() do if obj:IsA("GuiObject") then obj.ZIndex=16 end end
expedition=require(script.Expedition).mount(screen,panel,label,button)
rewards=require(script.Rewards).mount(screen,panel,label,button)
industry=require(script.Industry).mount(screen,panel,label,button)
research=require(script.Research).mount(screen,panel,label,button)
collection=require(script.Collection).mount(screen,panel,label,button)
habitat=require(script.Habitat).mount(screen,panel,label,button)
local function closeMenus()
    construction.Visible=false;quest.Visible=false;settingsPanel.Visible=false;expedition:close();rewards:close();industry:close();research:close();collection:close();habitat:close()
end
local function toggle(menu)
    local open=not menu.Visible;closeMenus();menu.Visible=open
end
local toolbar=panel(screen,"MenuBar",1030,43,0,0);toolbar.AnchorPoint=Vector2.new(.5,1);toolbar.Position=UDim2.new(.5,0,1,-12)
local items={
    {"Construction","B · CONSTRUIR",function() toggle(construction) end},
    {"Machines","M · MÁQUINAS",function() local open=not industry:isOpen("machines");closeMenus();if open then industry:open("machines") end end},
    {"Army","G · TROPAS",function() local open=not industry:isOpen("army");closeMenus();if open then industry:open("army") end end},
    {"Harbor","T · PORTO",function() closeMenus();Net.send("Travel",{}) end},
    {"Legacy","L · LEGADO",function() local open=not expedition:isLegacyOpen();closeMenus();if open then expedition:openLegacy() end end},
    {"Rewards","R · PRESENTES",function() local open=not rewards:isOpen();closeMenus();if open then rewards:open() end end},
    {"Home","H · ILHA",function() closeMenus();Net.send("Home",{}) end},
    {"Settings","O · OPÇÕES",function() toggle(settingsPanel) end},
    {"Research","P · PESQUISA",function() local open=not research:isOpen();closeMenus();if open then research:open() end end},
    {"Collection","C · COLEÇÃO",function()local open=not collection:isOpen();closeMenus();if open then collection:open()end end},
}
table.insert(items,{"Pets","U · PETS",function()local open=not habitat:isOpen();closeMenus();if open then habitat:open()end end})
Net.on("OpenHabitat",function()closeMenus();habitat:open()end)
local menuButtons={}
for i,item in items do
    local b=button(toolbar,item[1],item[2],6+(i-1)*93,5,88,33,if i==1 then P.gold else P.cream,item[3]);b.TextSize=10;menuButtons[item[1]]=b
end
local questChip=button(screen,"CurrentGoal","Extraia 3 cristais · J",18,39,270,24,P.muted,function() toggle(quest) end);questChip.TextSize=10;questChip.BackgroundTransparency=.72;questChip.TextColor3=P.text
local toast=panel(screen,"Toast",420,44,0,0);toast.AnchorPoint=Vector2.new(.5,0);toast.Position=UDim2.new(.5,0,0,55);toast.Visible=false
local toastText=label(toast,"",12,6,396,32,12,P.text,true);toastText.TextWrapped=true;toastText.TextXAlignment=Enum.TextXAlignment.Center
local toastId=0
local function notify(text,kind)
    toastId+=1;local id=toastId;toast.Visible=true;toastText.Text=text;toastText.TextColor3=if kind=="error" then Color3.fromRGB(255,170,143) elseif kind=="contract" then P.gold else P.text
    task.delay(3.4,function() if toastId==id then toast.Visible=false end end)
end
local actionBar=panel(screen,"ContextAction",272,43,0,0);actionBar.AnchorPoint=Vector2.new(.5,1);actionBar.Position=UDim2.new(.5,0,1,-65);actionBar.Visible=false
local actionLabel=label(actionBar,"EXTRAIR CRISTAL",12,7,177,17,11,P.text,true)
local actionHint=label(actionBar,"E · interagir",12,24,177,13,9,P.muted)
local currentAction="Mine"
button(actionBar,"Act","E / AGIR",199,6,66,31,P.mint,function() Net.send(currentAction,{}) end)
local welcome=Instance.new("Frame");welcome.Name="Welcome";welcome.Size=UDim2.fromScale(1,1);welcome.BackgroundColor3=P.ink;welcome.BackgroundTransparency=.3;welcome.BorderSizePixel=0;welcome.Active=true;welcome.ZIndex=25;welcome.Parent=screen
local welcomeCard=panel(welcome,"WelcomeCard",446,278,0,0);welcomeCard.AnchorPoint=Vector2.new(.5,.5);welcomeCard.Position=UDim2.fromScale(.5,.48);welcomeCard.ZIndex=26
local wc=Instance.new("UIScale");wc.Parent=welcomeCard
local wt=label(welcomeCard,"AETHERWORKS",24,26,398,42,31,P.text,true);wt.TextXAlignment=Enum.TextXAlignment.Center
local intro=label(welcomeCard,"Uma pequena ilha. Um novo horizonte.",24,79,398,25,16,P.gold);intro.TextXAlignment=Enum.TextXAlignment.Center
local desc=label(welcomeCard,"Expanda seu terreno, construa andares e equipe-se.\nEnfrente a torre. Renasça e deixe seu legado.",24,122,398,49,13,P.muted);desc.TextWrapped=true;desc.TextXAlignment=Enum.TextXAlignment.Center
local function start() welcome.Visible=false;hasStarted=true;GuiService.SelectedObject=nil;Net.send("Ready",{}) end
button(welcomeCard,"Start","VAMOS CONSTRUIR",24,202,398,43,P.mint,start)
local controls=label(welcomeCard,"WASD mover · E interagir · B construir · T porto",24,253,398,16,10,P.muted);controls.TextXAlignment=Enum.TextXAlignment.Center
for _,obj in welcomeCard:GetDescendants() do if obj:IsA("GuiObject") then obj.ZIndex=27 end end
local wasInTower=false
local function redraw()
    expedition:update(state);rewards:update(state);industry:update(state);research:update(state);collection:update(state);habitat:update(state)
    local combat=state.tower and state.tower.active==true
    if combat~=wasInTower then closeMenus();wasInTower=combat end
    toolbar.Visible=not combat;eventPanel.Visible=not combat;domination.Visible=not combat;questChip.Visible=not combat
    coins.Text="¤ "..C.format(state.coins)
    rate.Text="+"..C.format(state.rate).."/s · coletor ¤ "..C.format(state.bank)
    local u=C.upgrades[state.level+1]
    if u then
        nextName.Text=u.name;nextDesc.Text=u.desc;nextRate.Text="PRODUÇÃO TOTAL +"..C.format(C.rate(state.level+1,state.stars,state.research,state.machineLevels,state.legacy)).."/s"
        buildButton.Text="CONSTRUIR · ¤ "..C.format(C.price(u,state.stars));buildButton.BackgroundColor3=if state.coins>=C.price(u,state.stars) then P.gold else P.muted
        if state.stars<(u.rebirth or 0) then buildButton.Text="REQUER RENASCIMENTO "..u.rebirth;buildButton.BackgroundColor3=P.muted end
        setPreview(state.level+1)
    else nextName.Text="Um império no céu";nextDesc.Text="Expanda níveis infinitos nas máquinas ou renasça para fortalecer seu legado.";nextRate.Text="FÁBRICA COMPLETA";buildButton.Text="ABRA LEGADO PARA RENASCER";setPreview(#C.upgrades) end
    progressTitle.Text=state.level.." / "..C.requiredLevel(state.stars).." construções · renascimento "..state.stars
    local q=C.contracts[state.contract]
    if q then
        questName.Text=q.name;questDesc.Text=q.desc;questTrack:set(state.contractProgress/q.goal);questCount.Text=state.contractProgress.."/"..q.goal.." · recompensa ¤ "..C.format(q.reward)
        questChip.Text=q.name.."  "..state.contractProgress.."/"..q.goal.." · J"
    else questName.Text="Contratos concluídos";questDesc.Text="Expanda seu legado e avance na torre.";questTrack:set(1);questCount.Text="Todos os contratos completos";questChip.Text="Seu próximo horizonte está no legado · L" end
    local sec=math.ceil(if state.surge then state.surgeRemaining or 0 else state.surgeIn or 240)
    eventText.Text=if state.surge then "AURORA ×2 · "..sec.."s" else string.format("AURORA EM %02d:%02d",math.floor(sec/60),sec%60).." · "..(state.community or 0).."/30"
    if (state.overdriveRemaining or 0)>0 then eventText.Text="SOBRECARGA ×3 · "..state.overdriveRemaining.."s" end
    local d=state.dominion or {}
    domination.Text=if d.contested then "CENTRO CONTESTADO · BÔNUS SUSPENSO" elseif d.owner then d.owner:upper().." DOMINA · ×1,5" elseif d.contender then d.contender:upper().." CAPTURA · "..math.floor((d.progress or 0)*100).."%" else "CENTRO NEUTRO · G PARA TROPAS"
    domination.TextColor3=if d.multiplier==1.5 then P.mint else P.text
    local r=state.rewards
    menuButtons.Rewards.BackgroundColor3=if r and (r.dailyReady or r.timeReady) then P.mint else P.cream
end
Net.on("StateSync",function(payload) for k,v in payload do state[k]=v end;redraw() end)
Net.on("Feedback",function(payload)
    if payload.kind~="mine" and payload.kind~="shot" and payload.kind~="dodge" then notify(payload.text,payload.kind) end
    Audio.play(if payload.kind=="shot" then "combat.shoot" elseif payload.kind=="dodge" then "ui.open" elseif payload.kind=="error" then "ui.error" elseif payload.kind=="mine" then "machine.clank" elseif payload.kind=="collect" then "reward.coin" else "ui.success")
    if payload.position then
        Feel.number(payload.position+Vector3.new(0,3,0),payload.text,{color=if payload.kind=="mine" then P.mint else P.gold,size=20,maxDistance=90})
        if settings.motion and payload.kind=="build" then Feel.shake(.1);Feel.impact(payload.position,{color=P.mint,count=10}) end
    end
end)
local function layout()
    local size=screen.AbsoluteSize
    if size.X<=0 or size.Y<=0 then return end
    expedition:layout(size);rewards:layout(size);industry:layout(size);research:layout(size);collection:layout(size);habitat:layout(size)
    wc.Scale=math.min(1,(size.X-32)/446,(size.Y-50)/278)
    local scale=toolbar:FindFirstChildOfClass("UIScale") or Instance.new("UIScale",toolbar);scale.Scale=math.min(1,(size.X-28)/1030)
    local cs=construction:FindFirstChildOfClass("UIScale") or Instance.new("UIScale",construction);cs.Scale=math.min(1,(size.Y-170)/437)
    toast.Size=UDim2.fromOffset(math.min(420,size.X-30),44);toastText.Size=UDim2.new(1,-24,1,-12)
end
screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout);layout()
local keyActions={B=items[1][3],M=items[2][3],G=items[3][3],J=function() toggle(quest) end,T=items[4][3],L=items[5][3],R=items[6][3],H=items[7][3],O=items[8][3],P=items[9][3],C=items[10][3],U=items[11][3]}
UserInputService.InputBegan:Connect(function(input,processed)
    if input.KeyCode==Enum.KeyCode.Escape then closeMenus();return end
    if processed then return end
    if not hasStarted and (input.KeyCode==Enum.KeyCode.Return or input.KeyCode==Enum.KeyCode.ButtonA) then start();return end
    if not hasStarted or (state.tower and state.tower.active) then return end
    if construction.Visible and input.KeyCode==Enum.KeyCode.Return then
        local u=C.upgrades[state.level+1];if u then Net.send("Buy",{id=u.id}) else closeMenus();expedition:openLegacy() end
        return
    end
    local action=keyActions[input.KeyCode.Name];if action then action() end
end)
ContextActionService:BindAction("AetherHome",function(_,status) if status==Enum.UserInputState.Begin then Net.send("Home",{}) end end,false,Enum.KeyCode.ButtonY)
local function orientCamera(character)
    local root=character:WaitForChild("HumanoidRootPart")
    for _=1,30 do if state.plotCFrame then break end;task.wait(.1) end
    task.wait(.3)
    local camera=workspace.CurrentCamera;camera.CameraType=Enum.CameraType.Custom;camera.CameraSubject=character:WaitForChild("Humanoid")
    if state.plotCFrame then camera.CFrame=CFrame.lookAt(state.plotCFrame*Vector3.new(12,25,-61),state.plotCFrame*Vector3.new(0,3,-8)) end
end
player.CharacterAdded:Connect(orientCamera);if player.Character then task.spawn(orientCamera,player.Character) end

-- Bounded local presentation: the server owns production and money. Moving
-- crystals are the visual representation, never a source of economic rewards.
local Art=require(game:GetService("ReplicatedStorage").Shared.Art)
local visuals=Instance.new("Folder");visuals.Name="AetherClientVisuals";visuals.Parent=workspace
local ledger=Forge.Tycoon.ThroughputLedger.new()
local chain=Forge.Tycoon.DropperChain.new({baseLimit=48,perLevelBonus=0})
local orbs={};local rotors={};local sequence=0;local lastEmit=0;local actionTick=0
local function rotor(instance)
    if instance:IsA("Model") and instance:IsDescendantOf(workspace) then rotors[instance]={cf=instance:GetPivot(),axis=instance:GetAttribute("SpinAxis"),speed=instance:GetAttribute("SpinSpeed") or .65} end
end
for _,obj in CollectionService:GetTagged("AetherSpin") do rotor(obj) end
CollectionService:GetInstanceAddedSignal("AetherSpin"):Connect(rotor)
CollectionService:GetInstanceRemovedSignal("AetherSpin"):Connect(function(obj) rotors[obj]=nil end)
RunService.RenderStepped:Connect(function(dt)
    local now=os.clock()
    if settings.motion then
        for model,data in rotors do
            if model.Parent then model:PivotTo(data.cf*(if data.axis=="Z" then CFrame.Angles(0,0,now*data.speed) else CFrame.Angles(0,now*data.speed,0))) else rotors[model]=nil end
        end
    end
    for id,orb in orbs do
        local alpha=(now-orb.at)/4.7
        if alpha>=1 or not orb.part.Parent then orb.part:Destroy();orbs[id]=nil;ledger:remove(id)
        else
            local at=orb.cf*CFrame.new(-32+64*alpha,0,0)
            if alpha>.45 and not orb.polished then
                orb.part:Destroy();orb.part=Art.crystal(visuals,at,.4,orb.tier);orb.polished=true
                -- Moving gems own their transforms; their child orbiters must not anchor to the belt origin.
                for _,v in orb.part:GetDescendants() do if CollectionService:HasTag(v,"AetherSpin") then CollectionService:RemoveTag(v,"AetherSpin") end end
            end
            orb.part:PivotTo(at*CFrame.Angles(0,alpha*2,0))
        end
    end
    if now-lastEmit>.75 then
        lastEmit=now
        local world=workspace:FindFirstChild("Aetherworks")
        if world then
            for _,id in C.plotIds do
                local plot=world:FindFirstChild(id)
                if plot and (plot:GetAttribute("Level") or 0)>0 and chain:canProduce(ledger:count(),1) then
                    local arrival=plot:FindFirstChild("Arrival")
                    if arrival then
                        local base=arrival.CFrame*CFrame.new(0,3.5,47)
                        sequence+=1;local key=tostring(sequence)
                        local built=plot:FindFirstChild("Machines");local sources={}
                        if built then for _,m in built:GetChildren() do if m:GetAttribute("CrystalTier") then table.insert(sources,m) end end end
                        table.sort(sources,function(a,b)return (a:GetAttribute("UpgradeIndex") or 0)<(b:GetAttribute("UpgradeIndex") or 0)end)
                        local tier=if #sources>0 then sources[(sequence-1)%#sources+1]:GetAttribute("CrystalTier") else 1
                        local p=Art.crystal(visuals,base*CFrame.new(-32,0,0),.4,tier,true)
                        orbs[key]={part=p,at=now,cf=base,tier=tier};ledger:add(key)
                    end
                end
            end
        end
    end
    actionTick+=dt
    if actionTick>.15 then
        actionTick=0
        local character=player.Character;local root=character and character:FindFirstChild("HumanoidRootPart")
        if root and state.plotCFrame and hasStarted then
            local localPos=state.plotCFrame:PointToObjectSpace(root.Position)
            local mineDistance=(localPos-Vector3.new(-25,3,-31)).Magnitude
            local bankDistance=if state.collectorPosition then (root.Position-state.collectorPosition).Magnitude else math.huge
            actionBar.Visible=mineDistance<15 or bankDistance<15
            if mineDistance<bankDistance then currentAction="Mine";actionLabel.Text="EXTRAIR CRISTAL";actionHint.Text="Veio de aether · extração manual"
            else currentAction="Collect";actionLabel.Text="RECOLHER ¤ "..C.format(state.bank);actionHint.Text="Ganhos da sua fábrica" end
            if root.Position.Y<10 then Net.send("Home",{}) end
        else actionBar.Visible=false end
    end
end)
task.spawn(function()
    for _=1,6 do Net.send("Ready",{});if state.plotId then break end;task.wait(1) end
end)
print("[Aetherworks] client ready")
