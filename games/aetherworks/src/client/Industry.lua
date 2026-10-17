local RS=game:GetService("ReplicatedStorage")
local C=require(RS.Shared.TycoonConfig)
local Net=require(RS.Forge).Net
local View=require(script.Parent.ModelView)
local Industry={}
function Industry.mount(screen,panel,label,button)
    local self={mode="machines",state={},selected=1};local P=C.colors
    local shade=Instance.new("Frame");shade.Name="IndustryOverlay";shade.Size=UDim2.fromScale(1,1);shade.BackgroundColor3=P.ink;shade.BackgroundTransparency=.25;shade.Active=true;shade.Visible=false;shade.ZIndex=45;shade.Parent=screen
    local card=panel(shade,"Industry",780,580,0,0);card.AnchorPoint=Vector2.new(.5,.5);card.Position=UDim2.fromScale(.5,.5);card.ZIndex=46
    local scale=Instance.new("UIScale",card)
    label(card,"OFICINA & COMANDO",24,18,600,20,11,P.mint,true)
    local title=label(card,"Sua linha de produção",24,44,700,34,26,P.text,true)
    button(card,"CloseIndustry","×",728,16,30,30,P.muted,function()shade.Visible=false end)
    local caption=label(card,"",24,85,730,22,12,P.muted)
    local machines=Instance.new("ScrollingFrame");machines.Name="MachineList";machines.Position=UDim2.fromOffset(24,124);machines.Size=UDim2.fromOffset(326,421);machines.BackgroundTransparency=1;machines.BorderSizePixel=0;machines.ScrollBarThickness=4;machines.CanvasSize=UDim2.new();machines.AutomaticCanvasSize=Enum.AutomaticSize.Y;machines.Parent=card
    local layout=Instance.new("UIListLayout",machines);layout.Padding=UDim.new(0,7);layout.SortOrder=Enum.SortOrder.LayoutOrder
    local detail=Instance.new("Frame");detail.Name="UpgradeComparison";detail.BackgroundTransparency=1;detail.Position=UDim2.fromOffset(369,124);detail.Size=UDim2.fromOffset(386,421);detail.Parent=card
    local before=View.mount(detail,"CurrentMachine",0,31,186,210);local after=View.mount(detail,"UpgradedMachine",200,31,186,210)
    local beforeText=label(detail,"ATUAL",0,0,186,22,11,P.muted,true)
    local afterText=label(detail,"APÓS +10",200,0,186,22,11,P.mint,true)
    local name=label(detail,"",0,256,386,27,18,P.text,true)
    local effect=label(detail,"",0,293,386,48,12,P.muted);effect.TextWrapped=true
    local one=button(detail,"UpgradeOne","+1",0,356,186,45,P.cream,function()Net.send("MachineUpgrade",{id=C.upgrades[self.selected].id,count=1})end)
    local ten=button(detail,"UpgradeTen","+10",200,356,186,45,P.gold,function()Net.send("MachineUpgrade",{id=C.upgrades[self.selected].id,count=10})end)
    local rows={}
    for i,u in C.upgrades do if C.isMachine(u) then
        local row=panel(machines,u.id,317,72,0,0);row.LayoutOrder=i
        local choose=button(row,"Select",u.name,8,7,300,28,P.panel,function()self.selected=i;self:update(self.state)end);choose.TextColor3=P.text;choose.TextXAlignment=Enum.TextXAlignment.Left;choose.TextSize=13
        local tier=label(row,"",8,40,299,23,11,P.muted);rows[i]={frame=row,choose=choose,tier=tier}
    end end
    local army=Instance.new("Frame");army.Name="Garrison";army.Size=UDim2.fromOffset(732,432);army.Position=UDim2.fromOffset(24,119);army.BackgroundTransparency=1;army.Parent=card
    local stats=label(army,"",0,0,460,65,13,P.text,true)
    local train=button(army,"TrainArmy","TREINAR",480,0,252,43,P.gold,function()Net.send("ArmyUpgrade",{})end)
    label(army,"COMPOSIÇÃO · CLIQUE PARA TROCAR · APLICA NOS REFORÇOS",0,77,732,20,11,P.mint,true)
    local slots={};local roleOrder={"Vanguard","Shield","Gunner","Support","Siege"}
    for i=1,6 do slots[i]=button(army,"Slot"..i,"",(i-1)*123,103,116,40,P.cream,function()
        local current=(self.state.armyLoadout or {})[tostring(i)] or C.defaultArmy[i]
        Net.send("ArmyLoadout",{slot=i,role=roleOrder[(table.find(roleOrder,current) or 1)%#roleOrder+1]})
    end)end
    local groups={}
    for n,entry in {{"FORMAÇÃO","ArmyTactic","armyTactic",{"balanced","assault","guard"},C.tactics},{"ORDEM","ArmyOrder","armyOrder",{"advance","hold","regroup"},C.armyOrders},{"DESTINO","ArmyRoute","armyRoute",{"center","left","right"},C.armyRoutes},{"ALVO","ArmyPriority","armyPriority",{"nearest","support","weak"},C.armyPriorities}} do
        local y=166+(n-1)*49;label(army,entry[1],0,y+7,114,22,10,P.mint,true);local buttons={}
        for i,id in entry[4] do local value=entry[5][id];buttons[id]=button(army,entry[2]..id,if type(value)=="table" then value.name else value,125+(i-1)*204,y,194,35,P.cream,function()Net.send(entry[2],{id=id})end)end
        groups[entry[3]]=buttons
    end
    local round=label(army,"",0,375,732,52,11,P.muted);round.TextWrapped=true
    for _,obj in card:GetDescendants()do if obj:IsA("GuiObject")then obj.ZIndex=47 end end
    function self:open(mode)self.mode=mode;shade.Visible=true;self:update(self.state)end
    function self:isOpen(mode)return shade.Visible and self.mode==mode end
    function self:close()shade.Visible=false end
    function self:layout(size)scale.Scale=math.min(1,(size.X-32)/780,(size.Y-30)/580)end
    function self:update(state)
        self.state=state;if not shade.Visible then return end
        local isArmy=self.mode=="army";machines.Visible=not isArmy;detail.Visible=not isArmy;army.Visible=isArmy
        title.Text=if isArmy then "Comande sua guarnição" else "Sua linha de produção"
        caption.Text=if isArmy then "Defensores seguram vanguardas; artilharia rompe escudos; médicos sustentam o avanço." else "Compare a máquina, o rendimento e o custo antes de investir."
        for i,row in rows do
            row.frame.Visible=i<=(state.level or 0);local u=C.upgrades[i];local rank=C.machineLevel(state.machineLevels,u.id);local tier=C.crystal(rank)
            row.choose.BackgroundColor3=if i==self.selected then P.teal else P.panel
            row.tier.Text="N"..rank.." · "..tier.name;row.tier.TextColor3=tier.aura or tier.color
        end
        if not isArmy then
            local u=C.upgrades[self.selected];local rank=C.machineLevel(state.machineLevels,u.id);local tier,index=C.crystal(rank);local nextTier,nextIndex=C.crystal(rank+10)
            before:show("machine",self.selected,index);after:show("machine",self.selected,nextIndex)
            beforeText.Text="ATUAL · N"..rank;afterText.Text="APÓS +10 · N"..(rank+10);name.Text=u.name
            local delta=u.rate-(if self.selected>1 then C.upgrades[self.selected-1].rate else 0)
            local production=delta*(1+(rank-1)*.22)*tier.multiplier;local future=delta*(1+(rank+9)*.22)*nextTier.multiplier
            effect.Text="Produção base: "..C.format(production).." → "..C.format(future).."/s\n"..(if C.crystals[index+1]then "Nova forma e componentes no nível "..C.crystals[index+1].level else "Obsidiana dominada · níveis continuam sem limite")
            one.Text="+1 · ¤ "..C.format(C.machinePrice(u,state.machineLevels,state.stars,1));ten.Text="+10 · ¤ "..C.format(C.machinePrice(u,state.machineLevels,state.stars,10))
            if (state.level or 0)==0 then effect.Text="B · Construa seu primeiro extrator para abrir a oficina." end
        end
        local a=C.armyStats(state.armyLevel or 0,state.armyTactic,state.legacy);local d=state.dominion or {}
        stats.Text="GUARNIÇÃO N"..(state.armyLevel or 0).." · "..(d.troops or 0).."/"..a.count.." soldados\n"..a.health.." vida base · "..math.floor(a.damage).." dano base\n"..(if d.contested then "Centro em disputa" elseif d.owner then "Domínio: "..d.owner else "Centro neutro")
        train.Text="TREINAR +1 · ¤ "..C.format(C.infinitePrice(1200,state.armyLevel or 0))
        for i,b in slots do local role=(state.armyLoadout or {})[tostring(i)] or C.defaultArmy[i];b.Text=i.." · "..C.soldierRoles[role].name;b.TextSize=11;b.BackgroundColor3=if i<=a.count then P.cream else P.muted end
        for field,buttons in groups do for id,b in buttons do b.BackgroundColor3=if state[field]==id then P.mint else P.cream end end
        local scores={};for _,id in C.plotIds do table.insert(scores,id.." "..math.floor((d.scores or {})[id] or 0))end
        round.Text="RODADA "..math.floor((d.roundSeconds or 0)/60)..":"..string.format("%02d",(d.roundSeconds or 0)%60).." · "..table.concat(scores,"  |  ").."\nCentro: ×1,5 renda. Relés: cura local. Vitória: honra para decoração."
    end
    return self
end
return Industry
