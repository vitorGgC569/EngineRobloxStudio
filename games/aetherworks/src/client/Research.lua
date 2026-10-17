local RS=game:GetService("ReplicatedStorage")
local C=require(RS.Shared.TycoonConfig)
local Net=require(RS.Forge).Net
local Research={}
function Research.mount(screen,panel,label,button)
    local self={state={},tree="legacy"};local P=C.colors
    local shade=Instance.new("Frame");shade.Name="ResearchOverlay";shade.Size=UDim2.fromScale(1,1);shade.BackgroundColor3=P.ink;shade.BackgroundTransparency=.3;shade.Active=true;shade.Visible=false;shade.ZIndex=50;shade.Parent=screen
    local card=panel(shade,"Research",500,544,0,0);card.AnchorPoint=Vector2.new(.5,.5);card.Position=UDim2.fromScale(.5,.5);card.ZIndex=51
    local scale=Instance.new("UIScale",card)
    label(card,"PESQUISAS PERMANENTES",20,18,420,28,22,P.text,true)
    local stats=label(card,"",20,53,450,25,13,P.gold,true)
    button(card,"CloseResearch","×",454,16,28,28,P.muted,function() shade.Visible=false end)
    local tabs={}
    for index,tree in {"legacy","towerResearch"} do
        tabs[tree]=button(card,tree,if tree=="legacy" then "LEGADO · NÚCLEOS" else "TORRE · RELÍQUIAS",20+(index-1)*235,92,225,35,P.cream,function() self.tree=tree;self:update(self.state) end)
    end
    local list=Instance.new("ScrollingFrame");list.Name="ResearchNodes";list.Size=UDim2.fromOffset(460,348);list.Position=UDim2.fromOffset(20,144);list.BackgroundTransparency=1;list.BorderSizePixel=0;list.ScrollBarThickness=4;list.AutomaticCanvasSize=Enum.AutomaticSize.Y;list.CanvasSize=UDim2.new();list.Parent=card
    local layout=Instance.new("UIListLayout",list);layout.Padding=UDim.new(0,10);layout.SortOrder=Enum.SortOrder.LayoutOrder
    local rows={}
    for _,tree in {"legacy","towerResearch"} do
        for index,node in (if tree=="legacy" then C.legacyNodes else C.towerNodes) do
            local row=panel(list,tree..node.id,450,101,0,0);row.LayoutOrder=index
            local name=label(row,node.name,12,7,420,22,14,P.text,true)
            local desc=label(row,node.desc,12,33,420,22,11,P.muted)
            local buy=button(row,"BuyNode","",12,61,426,31,P.mint,function() Net.send("ResearchNode",{tree=tree,id=node.id}) end)
            table.insert(rows,{tree=tree,node=node,frame=row,name=name,button=buy,desc=desc})
        end
    end
    label(card,"Tudo permanece após renascer. Compre fora de uma expedição.",20,511,462,19,11,P.muted)
    for _,obj in card:GetDescendants() do if obj:IsA("GuiObject") then obj.ZIndex=52 end end
    function self:open(tree) self.tree=tree or self.tree;shade.Visible=true;self:update(self.state) end
    function self:isOpen() return shade.Visible end
    function self:close() shade.Visible=false end
    function self:layout(size) scale.Scale=math.min(1,(size.X-32)/500,(size.Y-30)/544) end
    function self:update(state)
        self.state=state;stats.Text=(state.cores or 0).." núcleos · "..(state.relics or 0).." relíquias · R"..(state.stars or 0)
        for tree,b in tabs do b.BackgroundColor3=if tree==self.tree then P.mint else P.cream end
        for _,row in rows do
            row.frame.Visible=row.tree==self.tree
            local node=row.node;local level=(state[row.tree] or {})[node.id] or 0
            row.name.Text=node.name.." · N"..level
            local price=C.nodePrice(node,level)
            row.button.Text="MELHORAR · "..price..(if row.tree=="legacy" then " NÚCLEOS" else " RELÍQUIAS")
            if (state.stars or 0)<(node.rebirth or 0) then row.button.Text="REQUER RENASCIMENTO "..node.rebirth
            elseif node.requires and not (state.perks or {})[node.requires] then row.button.Text="REQUER "..string.upper(C.perks[node.requires].name).." · L" end
            if node.id=="recovery" and C.offlineLimit(state)>=86400 then row.button.Text="RESERVA COMPLETA · 24 HORAS" end
        end
    end
    return self
end
return Research
