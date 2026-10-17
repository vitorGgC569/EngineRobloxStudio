local RS=game:GetService("ReplicatedStorage")
local Players=game:GetService("Players")
local Input=game:GetService("UserInputService")
local Tags=game:GetService("CollectionService")
local Debris=game:GetService("Debris")
local RunService=game:GetService("RunService")
local Forge=require(RS.Forge)
local C=require(RS.Shared.TycoonConfig)
local View=require(script.Parent.ModelView)
local Net=Forge.Net
local Expedition={}
function Expedition.mount(screen,panel,label,button)
    local self={state={}};local firing=false;local shotAt=0
    local shade=Instance.new("Frame");shade.Name="ArsenalOverlay";shade.Size=UDim2.fromScale(1,1);shade.BackgroundColor3=C.colors.ink;shade.BackgroundTransparency=.3;shade.Visible=false;shade.Active=true;shade.ZIndex=30;shade.Parent=screen
    local shop=panel(shade,"Arsenal",752,516,0,0);shop.AnchorPoint=Vector2.new(.5,.5);shop.Position=UDim2.fromScale(.5,.5);shop.ZIndex=31
    local scale=Instance.new("UIScale");scale.Parent=shop
    label(shop,"PORTO CENTRAL",24,19,350,20,11,C.colors.mint,true)
    label(shop,"Prepare seu próximo horizonte",24,48,398,34,23,C.colors.text,true)
    local relics=label(shop,"0 relíquias · pesquisa +0%",24,87,400,24,13,C.colors.gold,true)
    button(shop,"CloseArsenal","×",703,14,33,33,C.colors.muted,function() shade.Visible=false end)
    local weapon=label(shop,"Luva de brisa · 14 de dano",24,127,395,20,13,C.colors.text,true)
    local weaponBuy=button(shop,"UpgradeWeapon","MELHORAR ARMA",24,152,396,39,C.colors.cream,function() Net.send("Shop",{item="weapon"}) end)
    local armor=label(shop,"Traje de explorador · 100 de vida",24,205,395,20,13,C.colors.text,true)
    local armorBuy=button(shop,"UpgradeArmor","MELHORAR ARMADURA",24,230,396,39,C.colors.cream,function() Net.send("Shop",{item="armor"}) end)
    local researchBuy=button(shop,"Research","PESQUISAR +10% DE PRODUÇÃO · 2 RELÍQUIAS",24,284,396,39,C.colors.mint,function() Net.send("Shop",{item="research"}) end)
    local desc=label(shop,"Chefes a cada 5 ondas. Flanqueie escudos; elimine curadores.\nP · pesquisa permanente. F ou clique segurado · disparar.",24,339,396,42,12,C.colors.muted);desc.TextWrapped=true
    local enter=button(shop,"EnterTower","ENTRAR NA TORRE · ¤ 600",24,395,396,49,C.colors.gold,function() Net.send("EnterTower",{}) end)
    local heroic=button(shop,"EnterHeroic","TORRE HEROICA · RENASCIMENTO 1",24,454,396,40,C.colors.mint,function() Net.send("EnterHeroic",{}) end)
    label(shop,"EQUIPAMENTO EM EXPOSIÇÃO",450,90,278,22,11,C.colors.mint,true)
    local equipmentView=View.mount(shop,"EquipmentDisplay",450,126,278,266)
    local equipmentName=label(shop,"",450,408,278,24,17,C.colors.text,true)
    local equipmentDesc=label(shop,"Projetos dos chefes + cristais da fábrica\n= novas especializações. C · Coleção",450,447,278,46,12,C.colors.muted);equipmentDesc.TextWrapped=true
    equipmentDesc.Position=UDim2.fromOffset(450,407);equipmentDesc.Size=UDim2.fromOffset(278,38);equipmentName.Visible=false
    button(shop,"EnterCoop","6 · EXPEDIÇÃO EM DUPLA",450,454,278,40,C.colors.mint,function()Net.send("EnterCoop",{})end)
    for _,obj in shop:GetDescendants() do if obj:IsA("GuiObject") then obj.ZIndex=32 end end
    local legacyShade=Instance.new("Frame");legacyShade.Name="LegacyOverlay";legacyShade.Size=UDim2.fromScale(1,1);legacyShade.BackgroundColor3=C.colors.ink;legacyShade.BackgroundTransparency=.25;legacyShade.Active=true;legacyShade.Visible=false;legacyShade.ZIndex=35;legacyShade.Parent=screen
    local legacyCard=panel(legacyShade,"LegacyCard",444,553,0,0);legacyCard.AnchorPoint=Vector2.new(.5,.5);legacyCard.Position=UDim2.fromScale(.5,.5);legacyCard.ZIndex=36
    local legacyScale=Instance.new("UIScale");legacyScale.Parent=legacyCard
    label(legacyCard,"UM NOVO HORIZONTE",24,20,360,20,11,C.colors.mint,true)
    label(legacyCard,"Seu legado permanece",24,48,380,35,25,C.colors.text,true)
    local legacyStats=label(legacyCard,"0 renascimentos · 0 núcleos",24,91,390,24,14,C.colors.gold,true)
    local legacyButtons={}
    for i,id in {"magnet","drone","overdrive"} do
        local perk=C.perks[id];local y=131+(i-1)*94
        label(legacyCard,perk.name.." · R"..perk.rebirth,24,y,396,22,15,C.colors.text,true)
        label(legacyCard,perk.description,24,y+24,396,20,11,C.colors.muted)
        legacyButtons[id]=button(legacyCard,id,"DESBLOQUEAR",24,y+47,396,35,C.colors.mint,function()
            if id=="overdrive" and self.state.perks and self.state.perks.overdrive then Net.send("Overdrive",{});legacyShade.Visible=false
            else Net.send("Legacy",{perk=id}) end
        end)
    end
    local resetDesc=label(legacyCard,"Reset: fábrica, níveis das máquinas e coroas. Permanecem:\nequipamentos, tropas, pesquisas e legado. P · árvore permanente.",24,424,396,41,11,C.colors.muted);resetDesc.TextWrapped=true
    local requirement=label(legacyCard,"",24,468,396,22,11,C.colors.gold,true)
    local confirmUntil=0
    local rebirth=button(legacyCard,"Rebirth","RENASCER",24,504,396,33,C.colors.gold,function()
        if os.clock()>confirmUntil then confirmUntil=os.clock()+5;return end
        confirmUntil=0;Net.send("Rebirth",{})
    end)
    button(legacyCard,"CloseLegacy","×",395,14,33,33,C.colors.muted,function() legacyShade.Visible=false end)
    for _,obj in legacyCard:GetDescendants() do if obj:IsA("GuiObject") then obj.ZIndex=37 end end
    local hud=panel(screen,"ExpeditionStatus",360,71,0,0);hud.AnchorPoint=Vector2.new(.5,0);hud.Position=UDim2.new(.5,0,0,14);hud.Visible=false
    local title=label(hud,"TORRE DA AURORA · ONDA 1",14,5,332,20,13,C.colors.gold,true);title.TextXAlignment=Enum.TextXAlignment.Center
    local status=label(hud,"",14,26,332,19,11,C.colors.text);status.TextXAlignment=Enum.TextXAlignment.Center
    local hp=label(hud,"",14,47,332,18,11,C.colors.mint,true);hp.TextXAlignment=Enum.TextXAlignment.Center
    local actions=Instance.new("Frame");actions.Name="CombatActions";actions.BackgroundTransparency=1;actions.Size=UDim2.fromOffset(342,77);actions.AnchorPoint=Vector2.new(.5,1);actions.Position=UDim2.new(.5,0,1,-20);actions.Parent=screen;actions.Visible=false
    button(actions,"Fire","F · DISPARAR",0,0,166,38,C.colors.gold,function() Net.send("Attack",{}) end)
    button(actions,"Evade","Q · ESQUIVAR",176,0,166,38,C.colors.mint,function() Net.send("Dodge",{}) end)
    button(actions,"LeaveTower","X · SAIR DA TORRE",76,46,190,26,C.colors.muted,function() Net.send("LeaveTower",{}) end)
    local choices=panel(screen,"WaveChoices",618,121,0,0);choices.AnchorPoint=Vector2.new(.5,1);choices.Position=UDim2.new(.5,0,1,-108);choices.Visible=false;choices.ZIndex=24
    local choiceTitle=label(choices,"ESCOLHA PARA ESTA EXPEDIÇÃO",14,9,590,20,11,C.colors.mint,true)
    for i,id in {"focus","repair","risk"} do
        local data=C.towerChoices[id]
        button(choices,"Choice_"..id,i.." · "..data.name,14+(i-1)*200,37,190,34,C.colors[data.color],function()Net.send("TowerChoice",{id=id})end)
        local desc=label(choices,data.desc,14+(i-1)*200,78,190,32,10,C.colors.muted);desc.TextWrapped=true
    end
    for _,obj in choices:GetDescendants()do if obj:IsA("GuiObject")then obj.ZIndex=25 end end
    local selected=Instance.new("Highlight");selected.Name="PriorityTarget";selected.Enabled=false;selected.FillTransparency=1;selected.OutlineColor=C.colors.gold;selected.DepthMode=Enum.HighlightDepthMode.Occluded;selected.Parent=workspace
    local function selectTarget()
        local target=Players.LocalPlayer:GetMouse().Target
        while target and target~=workspace do
            if target:GetAttribute("TowerOwner")==((self.state.tower or {}).ownerId or Players.LocalPlayer.UserId) and target:GetAttribute("TargetId") then Net.send("TowerTarget",{id=target:GetAttribute("TargetId")});return end
            target=target.Parent
        end
    end
    Input.InputBegan:Connect(function(input,processed)
        if processed then return end
        if shade.Visible then
            local shopKeys={[Enum.KeyCode.One]="weapon",[Enum.KeyCode.Two]="armor",[Enum.KeyCode.Three]="research"}
            if shopKeys[input.KeyCode] then Net.send("Shop",{item=shopKeys[input.KeyCode]}) end
            if input.KeyCode==Enum.KeyCode.Four then Net.send("EnterTower",{}) end
            if input.KeyCode==Enum.KeyCode.Five then Net.send("EnterHeroic",{}) end
            if input.KeyCode==Enum.KeyCode.Six then Net.send("EnterCoop",{}) end
            return
        end
        if legacyShade.Visible then
            local keys={[Enum.KeyCode.One]="magnet",[Enum.KeyCode.Two]="drone",[Enum.KeyCode.Three]="overdrive"}
            local id=keys[input.KeyCode]
            if id then
                if id=="overdrive" and self.state.perks and self.state.perks.overdrive then Net.send("Overdrive",{}) else Net.send("Legacy",{perk=id}) end
            end
            if input.KeyCode==Enum.KeyCode.Return then
                if os.clock()>confirmUntil then confirmUntil=os.clock()+5 else confirmUntil=0;Net.send("Rebirth",{}) end
            end
            return
        end
        if not self.state.tower or not self.state.tower.active then return end
        if self.state.tower.choice then
            local choiceKeys={[Enum.KeyCode.One]="focus",[Enum.KeyCode.Two]="repair",[Enum.KeyCode.Three]="risk"}
            if choiceKeys[input.KeyCode]then Net.send("TowerChoice",{id=choiceKeys[input.KeyCode]});return end
        end
        if input.UserInputType==Enum.UserInputType.MouseButton1 then selectTarget()end
        if input.KeyCode==Enum.KeyCode.F or input.KeyCode==Enum.KeyCode.ButtonR2 or input.UserInputType==Enum.UserInputType.MouseButton1 then firing=true;Net.send("Attack",{});shotAt=os.clock() end
        if input.KeyCode==Enum.KeyCode.Q or input.KeyCode==Enum.KeyCode.ButtonB then Net.send("Dodge",{}) end
        if input.KeyCode==Enum.KeyCode.X then Net.send("LeaveTower",{}) end
    end)
    Input.InputEnded:Connect(function(input)
        if input.KeyCode==Enum.KeyCode.F or input.KeyCode==Enum.KeyCode.ButtonR2 or input.UserInputType==Enum.UserInputType.MouseButton1 then firing=false end
    end)
    Input.WindowFocusReleased:Connect(function() firing=false end)
    RunService.Heartbeat:Connect(function()
        if firing and self.state.tower and self.state.tower.active and not Input:GetFocusedTextBox() and os.clock()-shotAt>=.4 then
            shotAt=os.clock();Net.send("Attack",{})
        end
    end)
    Net.on("Feedback",function(payload)
        if payload.kind=="shop" then shade.Visible=true end
        if payload.kind=="shot" and payload.position and payload.from then
            local delta=payload.position-payload.from
            local beam=Instance.new("Part");beam.Name="AetherPulse";beam.Anchored=true;beam.CanCollide=false;beam.CanTouch=false;beam.CanQuery=false
            beam.Material=Enum.Material.Neon;beam.Color=C.colors.gold;beam.Size=Vector3.new(.22,.22,delta.Magnitude);beam.CFrame=CFrame.lookAt((payload.position+payload.from)/2,payload.position);beam.Parent=workspace;Debris:AddItem(beam,.12)
        end
    end)
    local animators={}
    local droneParts
    RunService.RenderStepped:Connect(function()
        local char=Players.LocalPlayer.Character;local r=char and char:FindFirstChild("HumanoidRootPart")
        if not self.state.perks or not self.state.perks.drone or not r then
            if droneParts then for _,p in droneParts do p:Destroy() end;droneParts=nil end
            return
        end
        if not droneParts then
            droneParts={}
            for i=1,3 do
                local p=Instance.new("Part");p.Name="LegacyDrone";p.Size=if i==1 then Vector3.new(1.8,.9,1.6) else Vector3.new(1.2,.2,2.5)
                p.Anchored=true;p.CanCollide=false;p.CanTouch=false;p.CanQuery=false;p.Material=if i==1 then Enum.Material.Metal else Enum.Material.Neon;p.Color=if i==1 then C.colors.teal else C.colors.mint;p.Parent=workspace;droneParts[i]=p
            end
        end
        local cf=r.CFrame*CFrame.new(3,3+math.sin(os.clock()*2)*.2,1)
        for i,p in droneParts do p.CFrame=cf*CFrame.new(if i==1 then 0 elseif i==2 then -1.3 else 1.3,0,0) end
    end)
    local function animate(model)
        if not model:IsA("Model") then return end
        if not Forge.Anim.waitForRig(model,5) or not model:IsDescendantOf(workspace) or animators[model] then return end
        local animator=Forge.Anim.new(model);local connection=Forge.Anim.bind(animator)
        local healthConnection
        local hum=model:FindFirstChildOfClass("Humanoid")
        local head=model:FindFirstChild("Head")
        if hum and head then
            local gui=Instance.new("BillboardGui");gui.Name="EnemyHealth";gui.Size=UDim2.fromOffset(128,36);gui.StudsOffset=Vector3.new(0,3,0);gui.AlwaysOnTop=true;gui.MaxDistance=90;gui.Adornee=head;gui.Parent=head
            local name=label(gui,model.Name,0,0,128,18,10,C.colors.text,true);name.TextXAlignment=Enum.TextXAlignment.Center
            local owner=model:GetAttribute("ArmyOwner");if owner then name.TextColor3=C.factions[table.find(C.plotIds,owner) or 1] end
            local bar=Forge.UI.bar(gui,{size=UDim2.fromOffset(112,5),pos=UDim2.fromOffset(8,24),color=C.colors.gold})
            bar:set(hum.Health/hum.MaxHealth)
            healthConnection=hum.HealthChanged:Connect(function() bar:set(hum.Health/hum.MaxHealth) end)
        end
        animators[model]={animator,connection,healthConnection}
    end
    for _,model in Tags:GetTagged("AetherEnemy") do animate(model) end
    for _,model in Tags:GetTagged("AetherSoldier") do animate(model) end
    Tags:GetInstanceAddedSignal("AetherSoldier"):Connect(animate)
    Tags:GetInstanceAddedSignal("AetherEnemy"):Connect(animate)
    local function stopAnimation(model)
        local pair=animators[model];if pair then pair[2]:Disconnect();pair[1]:destroy();if pair[3] then pair[3]:Disconnect() end;animators[model]=nil end
    end
    Tags:GetInstanceRemovedSignal("AetherEnemy"):Connect(stopAnimation)
    Tags:GetInstanceRemovedSignal("AetherSoldier"):Connect(stopAnimation)
    function self:close() shade.Visible=false;legacyShade.Visible=false end
    function self:isLegacyOpen() return legacyShade.Visible end
    function self:openLegacy() shade.Visible=false;legacyShade.Visible=true end
    function self:update(state)
        self.state=state
        local wi,ai=state.weapon or 1,state.armor or 1
        local w,a=C.weapons[wi],C.armors[ai]
        if shade.Visible then equipmentView:show("equipment",wi,math.clamp(wi,1,5));equipmentName.Text=w.name end
        weapon.Text=w.name.." · "..C.weaponDamage(state).." de dano";armor.Text=a.name.." · "..C.armorHealth(state).." de vida"
        weaponBuy.Text=if C.weapons[wi+1] then "MELHORAR ARMA · ¤ "..C.format(C.weapons[wi+1].cost) else "MAESTRIA "..((state.weaponMastery or 0)+1).." · ¤ "..C.format(C.infinitePrice(650000,state.weaponMastery or 0)).." + "..(3+math.floor((state.weaponMastery or 0)/3)).." REL."
        if C.weapons[wi+1] and (C.weapons[wi+1].rebirth or 0)>(state.stars or 0) then weaponBuy.Text="ARMA EXCLUSIVA · RENASCIMENTO "..C.weapons[wi+1].rebirth end
        armorBuy.Text=if C.armors[ai+1] then "MELHORAR ARMADURA · ¤ "..C.format(C.armors[ai+1].cost) else "MAESTRIA "..((state.armorMastery or 0)+1).." · ¤ "..C.format(C.infinitePrice(210000,state.armorMastery or 0)).." + "..(3+math.floor((state.armorMastery or 0)/3)).." REL."
        weaponBuy.Text="1 · "..weaponBuy.Text;armorBuy.Text="2 · "..armorBuy.Text
        relics.Text=(state.relics or 0).." relíquias · pesquisa +"..((state.research or 0)*10).."%"
        researchBuy.Text="PESQUISA +10% · "..(((state.research or 0)+1)*2).." RELÍQUIAS"
        researchBuy.Text="3 · "..researchBuy.Text
        enter.Text=if state.level<5 then "REQUER A TURBINA · CONSTRUÇÃO 5" else "ENTRAR NA TORRE · ¤ "..C.format(1500+math.min(10,state.towerWins or 0)*500)
        heroic.Text=if state.stars<1 then "TORRE HEROICA · RENASCIMENTO 1" else "TORRE HEROICA · ¤ "..C.format(12000+math.min(10,state.towerWins or 0)*500)
        enter.Text="4 · "..enter.Text;heroic.Text="5 · "..heroic.Text
        rebirth.Text=if os.clock()<confirmUntil then "CONFIRMAR: ZERAR FÁBRICA E COROAS?" else "RENASCER · ¤ "..C.format(C.prestigePrice(state.stars))
        legacyStats.Text=state.stars.." renascimentos · "..(state.cores or 0).." núcleos"
        requirement.Text="Próximo renascimento: "..C.requiredLevel(state.stars).." construções + ¤ "..C.format(C.prestigePrice(state.stars))
        for id,b in legacyButtons do
            local owned=state.perks and state.perks[id];local perk=C.perks[id]
            b.Text=if owned then "ATIVO PARA SEMPRE" elseif state.stars<perk.rebirth then "DESBLOQUEIA NO RENASCIMENTO "..perk.rebirth else "DESBLOQUEAR · "..perk.cores.." NÚCLEO(S)"
            if owned and id=="overdrive" then
                local wait=math.max(0,(state.overdriveReadyAt or 0)-(state.serverTime or 0))
                b.Text=if wait>0 then "RECARREGANDO · "..wait.."s" else "ATIVAR SOBRECARGA · PRODUÇÃO ×3"
            end
            b.Text=(if id=="magnet" then "1 · " elseif id=="drone" then "2 · " else "3 · ")..b.Text
        end
        local t=state.tower or {};hud.Visible=t.active==true;actions.Visible=t.active==true
        choices.Visible=t.active==true and t.choice==true
        choiceTitle.Text="PRÓXIMA ONDA EM "..(t.choiceSeconds or 0).."s · 1/2/3 ESCOLHER · X EXTRAIR"
        selected.Enabled=false;selected.Adornee=nil
        if t.active and t.targetId then for _,model in Tags:GetTagged("AetherEnemy")do if model:GetAttribute("TowerOwner")== (t.ownerId or Players.LocalPlayer.UserId) and model:GetAttribute("TargetId")==t.targetId then selected.Adornee=model;selected.Enabled=true;break end end end
        if t.active then
            shade.Visible=false;legacyShade.Visible=false
            title.Text=(if t.heroic then "TORRE HEROICA" else "TORRE DA AURORA").." · ONDA "..math.max(1,t.wave or 1)
            status.Text=if t.nextWave then "Foco +"..math.floor((t.focus or 0)*12).."% · risco "..(t.risk or 0).." · X extrair ¤ "..C.format(t.cacheCoins or 0) else (t.modifier or "Avanço").." · "..(t.enemies or 0).." inimigos · "..(t.relics or 0).." relíquias"
            local char=Players.LocalPlayer.Character;local hum=char and char:FindFirstChildOfClass("Humanoid")
            hp.Text=if hum then "VIDA "..C.format(hum.Health).." / "..C.format(hum.MaxHealth) else ""
            if (t.bossMax or 0)>0 then hp.Text..="   ·   CHEFE "..C.format(t.bossHealth).." / "..C.format(t.bossMax) end
        else firing=false
        end
    end
    function self:layout(size)
        scale.Scale=math.min(1,(size.X-28)/752,(size.Y-35)/516)
        legacyScale.Scale=math.min(1,(size.X-28)/444,(size.Y-35)/553)
        local compact=false
        hud.Position=UDim2.new(.5,0,0,if compact then 6 else 14)
        local hs=hud:FindFirstChildOfClass("UIScale") or Instance.new("UIScale",hud);hs.Scale=if compact then .8 else 1
        actions.Position=UDim2.new(.5,0,1,-12)
    end
    return self
end
return Expedition
