local RS=game:GetService("ReplicatedStorage")
local C=require(RS.Shared.TycoonConfig)
local Net=require(RS.Forge).Net
local View=require(script.Parent.ModelView)
local Book={}
function Book.mount(screen,panel,label,button)
    local self={state={},tab="crystals"};local P=C.colors
    local shade=Instance.new("Frame");shade.Name="CollectionOverlay";shade.Size=UDim2.fromScale(1,1);shade.BackgroundColor3=P.ink;shade.BackgroundTransparency=.25;shade.Visible=false;shade.Active=true;shade.ZIndex=50;shade.Parent=screen
    local card=panel(shade,"Collection",780,570,0,0);card.Position=UDim2.fromScale(.5,.5);card.AnchorPoint=Vector2.new(.5,.5);card.ZIndex=51
    local scale=Instance.new("UIScale",card)
    label(card,"ARQUIVO DOS EXPLORADORES",24,18,680,20,11,P.mint,true)
    label(card,"Cada descoberta fica com você",24,48,680,34,25,P.text,true)
    button(card,"CloseCollection","×",727,17,30,30,P.muted,function()shade.Visible=false end)
    local tabs={};local frames={}
    for i,entry in {{"crystals","Cristais"},{"recipes","Projetos & equipamentos"},{"weekly","Desafios & decoração"}} do
        tabs[entry[1]]=button(card,entry[1],entry[2],24+(i-1)*248,100,237,37,P.cream,function()self.tab=entry[1];self:update(self.state)end)
        local f=Instance.new("Frame");f.Name=entry[1].."Page";f.Position=UDim2.fromOffset(24,157);f.Size=UDim2.fromOffset(732,386);f.BackgroundTransparency=1;f.Parent=card;frames[entry[1]]=f
    end
    local crystals={}
    for i,tier in C.crystals do
        local x=(i-1)*148;local view=View.mount(frames.crystals,"Crystal"..i,x,0,139,182)
        local name=label(frames.crystals,tier.name,x,197,139,41,13,tier.aura or tier.color,true);name.TextWrapped=true
        label(frames.crystals,"Nível "..tier.level.." · ×"..tier.multiplier,x,246,139,25,11,P.muted)
        local unlocked=label(frames.crystals,"",x,281,139,23,10,P.mint,true)
        crystals[i]={view=view,unlocked=unlocked}
    end
    label(frames.crystals,"Descubra pela fábrica. Os cristais registrados permanecem após renascer.",0,348,732,28,12,P.muted)
    local recipes={}
    for i,recipe in C.blueprints do
        local y=(i-1)*126;local row=panel(frames.recipes,recipe.id,732,114,0,y)
        label(row,recipe.name,15,11,452,26,18,P.text,true)
        label(row,recipe.desc,15,42,450,23,12,P.muted)
        local req=label(row,"",15,77,450,23,11,P.mint)
        local action=button(row,"Craft_"..recipe.id,"FABRICAR",486,38,229,41,P.gold,function()
            local d=self.state.discovery or {};Net.send(if (d.crafted or {})[recipe.id]then "Specialize" else "Craft",{id=recipe.id})
        end)
        recipes[recipe.id]={req=req,action=action}
    end
    local weekly={};local reset=label(frames.weekly,"",0,0,732,23,11,P.mint,true)
    for i,id in {"mine","waves","dominion"}do
        local y=35+(i-1)*71;local name=label(frames.weekly,"",0,y,473,22,14,P.text,true)
        local reward=label(frames.weekly,"",0,y+27,473,21,11,P.muted)
        local claim=button(frames.weekly,"Weekly_"..id,"RECOLHER",490,y+8,242,38,P.gold,function()Net.send("WeeklyClaim",{id=id})end)
        weekly[id]={name=name,reward=reward,claim=claim}
    end
    label(frames.weekly,"DECORAÇÃO DA ILHA · SEM BÔNUS DE PODER",0,263,732,21,11,P.mint,true)
    local decor={}
    for i,entry in {{"default","Aurora · inicial"},{"astral","Astral · cristal violeta"},{"champion","Campeão · 25 honra"}}do
        decor[entry[1]]=button(frames.weekly,entry[1],entry[2],(i-1)*248,298,237,40,P.cream,function()Net.send("Decoration",{id=entry[1]})end)
    end
    local honor=label(frames.weekly,"",0,351,732,28,12,P.muted)
    for _,obj in card:GetDescendants()do if obj:IsA("GuiObject")then obj.ZIndex=52 end end
    function self:open()shade.Visible=true;self:update(self.state)end
    function self:close()shade.Visible=false end
    function self:isOpen()return shade.Visible end
    function self:layout(size)scale.Scale=math.min(1,(size.X-32)/780,(size.Y-30)/570)end
    function self:update(state)
        self.state=state;if not shade.Visible or not state.discovery then return end
        local d=state.discovery
        for id,f in frames do f.Visible=id==self.tab;tabs[id].BackgroundColor3=if id==self.tab then P.mint else P.cream end
        if self.tab=="crystals" then for i,row in crystals do row.view:show("crystal",i,i);row.unlocked.Text=if d.crystals[tostring(i)]then "DESCOBERTO" else "POR DESCOBRIR" end end
        for _,recipe in C.blueprints do
            local row=recipes[recipe.id];local owns=d.crafted[recipe.id];local equipped=d.specialization==recipe.id
            row.req.Text=(if d.blueprints[recipe.id]then "Projeto obtido" else "Chefe da onda "..recipe.wave).." · "..C.crystals[recipe.tier].name.." · "..recipe.cores.." núcleo(s)"
            row.action.Text=if equipped then "EQUIPADO" elseif owns then "EQUIPAR" else "FABRICAR";row.action.BackgroundColor3=if equipped then P.mint else P.gold
        end
        reset.Text="DESAFIOS DA SEMANA · RENOVA EM "..math.ceil(d.resetIn/3600).."h"
        for _,goal in d.objectives do
            local row=weekly[goal.id];local value=(d.weekly.progress or {})[goal.id] or 0;local claimed=d.weekly.claims[goal.id]
            row.name.Text=goal.name.." · "..math.min(goal.goal,math.floor(value)).." / "..goal.goal..(if goal.id=="dominion" then "s de domínio" else "")
            row.reward.Text=goal.relics.." relíquias + "..goal.cores.." núcleo(s)";row.claim.Text=if claimed then "RECEBIDO" elseif value>=goal.goal then "RECOLHER" else "EM PROGRESSO"
            row.claim.BackgroundColor3=if not claimed and value>=goal.goal then P.gold else P.muted
        end
        for id,b in decor do b.BackgroundColor3=if d.decoration==id then P.mint else P.cream end
        honor.Text=d.honor.." honra · vença rodadas de domínio para obter o acabamento de campeão."
    end
    return self
end
return Book
