local RS=game:GetService("ReplicatedStorage")
local C=require(RS.Shared.TycoonConfig)
local Net=require(RS.Forge).Net
local Rewards={}
function Rewards.mount(screen,panel,label,button)
    local self={}
    local shade=Instance.new("Frame");shade.Name="RewardsOverlay";shade.Size=UDim2.fromScale(1,1);shade.BackgroundColor3=C.colors.ink;shade.BackgroundTransparency=.25;shade.Active=true;shade.Visible=false;shade.ZIndex=40;shade.Parent=screen
    local card=panel(shade,"Rewards",480,674,0,0);card.AnchorPoint=Vector2.new(.5,.5);card.Position=UDim2.fromScale(.5,.5);card.ZIndex=41
    local scale=Instance.new("UIScale");scale.Parent=card
    label(card,"CADA VISITA CONTA",24,18,410,20,11,C.colors.mint,true)
    label(card,"Presentes do horizonte",24,47,425,34,26,C.colors.text,true)
    local summary=label(card,"",24,87,430,20,11,C.colors.muted)
    local dayCells={}
    for i=1,7 do
        local box=panel(card,"Day"..i,54,62,24+(i-1)*61,121)
        label(box,"DIA "..i,4,8,46,16,10,C.colors.muted,true)
        local amount=label(box,C.format(C.dayRewards[i]),4,31,46,20,12,C.colors.gold,true);amount.TextXAlignment=Enum.TextXAlignment.Center
        dayCells[i]=box
    end
    local daily=button(card,"ClaimDay","RECOLHER PRESENTE DE HOJE",24,199,432,39,C.colors.gold,function() Net.send("Daily",{}) end)
    local activeTime=label(card,"TEMPO ATIVO HOJE",24,253,430,20,11,C.colors.mint,true)
    local rows={}
    for i,reward in C.timeRewards do
        local y=280+(i-1)*46
        local text=label(card,reward.minutes.." min",24,y,98,22,13,C.colors.text,true)
        local value=label(card,"+"..C.format(reward.coins)..(if reward.relics>0 then " · "..reward.relics.." relíquias" else " coroas"),108,y,181,22,12,C.colors.muted)
        local claim=button(card,"Time_"..reward.id,"AGUARDANDO",301,y-2,155,32,C.colors.cream,function() Net.send("TimeReward",{id=reward.id}) end)
        rows[reward.id]={button=claim,label=text,value=value}
    end
    label(card,"MARCOS DE VISITAS · DIAS ACUMULADOS",24,515,430,20,11,C.colors.mint,true)
    local visits={}
    for index,m in C.visitMilestones do
        local b=button(card,"Visit"..m.days,m.days.." DIAS",24+((index-1)%2)*222,546+math.floor((index-1)/2)*38,210,31,C.colors.cream,function() Net.send("VisitReward",{days=m.days}) end)
        visits[m.days]=b
    end
    local note=label(card,"Sequência diária: até +35%. Seus dias acumulados permanecem.\nTempo pausa após 3 min inativo; retome movendo-se ou jogando.\nCalendário renova às 00h UTC (21h de Brasília).",24,627,432,40,10,C.colors.muted);note.TextWrapped=true
    button(card,"CloseRewards","×",430,16,30,30,C.colors.muted,function() shade.Visible=false end)
    for _,obj in card:GetDescendants() do if obj:IsA("GuiObject") then obj.ZIndex=42 end end
    function self:open() shade.Visible=true end
    function self:isOpen() return shade.Visible end
    function self:close() shade.Visible=false end
    game:GetService("UserInputService").InputBegan:Connect(function(input,processed)
        if processed or not shade.Visible then return end
        if input.KeyCode==Enum.KeyCode.One then Net.send("Daily",{});return end
        local keys={Enum.KeyCode.Two,Enum.KeyCode.Three,Enum.KeyCode.Four,Enum.KeyCode.Five,Enum.KeyCode.Six}
        local index=table.find(keys,input.KeyCode)
        if index then Net.send("TimeReward",{id=C.timeRewards[index].id}) end
    end)
    function self:layout(size) scale.Scale=math.min(1,(size.X-32)/480,(size.Y-30)/674) end
    function self:update(state)
        local r=state.rewards;if not r then return end
        summary.Text=r.daysPlayed.." dias · sequência "..(r.streak or 0).." · recorde "..(r.bestStreak or 0).." · "..math.floor(r.totalSeconds/60).." min"
        activeTime.Text=if r.active==false then "TEMPO PAUSADO · VOLTE A JOGAR PARA CONTINUAR" else "TEMPO ATIVO HOJE"
        for days,b in visits do
            local claimed=(r.visitClaims or {})[tostring(days)]
            local reward
            for _,m in C.visitMilestones do if m.days==days then reward=m end end
            b.Text=if claimed then days.." DIAS · RECEBIDO" else (if r.daysPlayed>=days then "RECOLHER" else r.daysPlayed.."/"..days.." DIAS").." · "..reward.relics.." REL. +"..reward.cores.." NÚC."
            b.TextSize=10
            b.BackgroundColor3=if not claimed and r.daysPlayed>=days then C.colors.mint else C.colors.muted
        end
        daily.Text=if r.dailyReady then "1 · RECOLHER DIA "..r.dayIndex.." · BÔNUS DA FÁBRICA" else "PRESENTE RECEBIDO · PRÓXIMO EM "..math.ceil(r.resetIn/3600).."h"
        daily.BackgroundColor3=if r.dailyReady then C.colors.gold else C.colors.muted
        local shown=if r.dailyReady then r.dayIndex else (if r.dayIndex==1 then 7 else r.dayIndex-1)
        for i,cell in dayCells do cell.BackgroundColor3=if i==shown then C.colors.teal else C.colors.panel end
        for _,reward in C.timeRewards do
            local row=rows[reward.id];local claimed=r.claims and r.claims[reward.id]
            local seconds=math.max(0,reward.minutes*60-r.seconds)
            row.button.Text=if claimed then "RECOLHIDO" elseif seconds==0 then "RECOLHER" else string.format("%02d:%02d",math.floor(seconds/60),seconds%60)
            row.button.BackgroundColor3=if not claimed and seconds==0 then C.colors.mint else C.colors.muted
        end
    end
    return self
end
return Rewards
