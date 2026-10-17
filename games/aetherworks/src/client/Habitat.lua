local RS=game:GetService("ReplicatedStorage")
local C=require(RS.Shared.TycoonConfig)
local P=require(RS.Shared.PetConfig)
local Net=require(RS.Forge).Net
local View=require(script.Parent.ModelView)
local House={}
function House.mount(screen,panel,label,button)
    local self={state={},selected="breeze",slot=1};local colors=C.colors
    local shade=Instance.new("Frame");shade.Name="HabitatOverlay";shade.Size=UDim2.fromScale(1,1);shade.BackgroundColor3=colors.ink;shade.BackgroundTransparency=.25;shade.Visible=false;shade.Active=true;shade.ZIndex=60;shade.Parent=screen
    local card=panel(shade,"Habitat",920,628,0,0);card.Position=UDim2.fromScale(.5,.5);card.AnchorPoint=Vector2.new(.5,.5);card.ZIndex=61
    local scale=Instance.new("UIScale",card)
    label(card,"CASA AURORA · SEUS COMPANHEIROS",22,17,810,23,12,colors.mint,true)
    label(card,"Uma casa que cresce com você",22,46,815,36,26,colors.text,true)
    button(card,"CloseHabitat","×",868,17,30,30,colors.muted,function()self:close()end)
    local summary=label(card,"",22,86,865,24,12,colors.mint,true)
    label(card,"LOTE E ANDARES",22,124,270,23,12,colors.text,true)
    local floorRows={}
    for i,floor in P.floors do
        floorRows[i]=label(card,"",22,154+(i-1)*28,274,25,11,colors.muted)
    end
    local build=button(card,"BuyHabitat","COMPRAR LOTE",22,303,270,39,colors.gold,function()Net.send("HabitatBuy",{})end)
    button(card,"VisitHabitat","IR ATÉ A CASA",22,352,270,32,colors.cream,function()Net.send("PetVisit",{})end)
    label(card,"ESCOLHA UM ESPAÇO",22,396,270,22,11,colors.mint,true)
    local slots={}
    for slot=1,10 do
        local x=22+((slot-1)%2)*139;local y=426+math.floor((slot-1)/2)*31
        slots[slot]=button(card,"PetSlot_"..slot,"",x,y,131,26,colors.cream,function()self.slot=slot;self:update(self.state)end)
        slots[slot].TextSize=10
    end
    local list=Instance.new("ScrollingFrame");list.Name="PetCatalog";list.Position=UDim2.fromOffset(315,127);list.Size=UDim2.fromOffset(246,450)
    list.BackgroundTransparency=1;list.BorderSizePixel=0;list.ScrollBarThickness=4;list.CanvasSize=UDim2.fromOffset(0,#P.pets*66);list.Parent=card
    local petRows={}
    for i,pet in P.pets do
        local b=button(list,"Pet_"..pet.id,pet.name,0,(i-1)*66,234,57,colors.cream,function()self.selected=pet.id;self:update(self.state)end)
        b.TextSize=12;b.TextWrapped=true;petRows[pet.id]=b
    end
    local view=View.mount(card,"PetPortrait",581,128,316,192)
    local name=label(card,"",581,332,316,26,19,colors.text,true)
    local description=label(card,"",581,367,316,44,13,colors.mint,true);description.TextWrapped=true
    local requirement=label(card,"",581,418,316,37,11,colors.muted);requirement.TextWrapped=true
    local adopt=button(card,"AdoptPet","ADOTAR",581,463,316,34,colors.gold,function()Net.send("PetAdopt",{id=self.selected})end)
    local upgrade=button(card,"UpgradePet","MELHORAR",581,463,316,34,colors.gold,function()Net.send("PetUpgrade",{id=self.selected})end)
    local equip=button(card,"EquipPet","HOSPEDAR",581,507,203,34,colors.mint,function()Net.send("PetEquip",{id=self.selected,slot=self.slot})end)
    button(card,"UnequipPet","RETIRAR",792,507,105,34,colors.cream,function()Net.send("PetUnequip",{slot=self.slot})end)
    local room=label(card,"",581,551,316,27,11,colors.muted)
    label(card,"Casa, andares e pets permanecem após renascer. Apenas pets hospedados dão bônus.",22,592,875,22,12,colors.muted)
    for _,obj in card:GetDescendants()do if obj:IsA("GuiObject")then obj.ZIndex=62 end end
    function self:open()shade.Visible=true;self:update(self.state)end
    function self:close()shade.Visible=false end
    function self:isOpen()return shade.Visible end
    function self:layout(size)scale.Scale=math.min(1,(size.X-32)/920,(size.Y-30)/628)end
    function self:update(state)
        self.state=state;if not shade.Visible or not state.habitat then return end
        local h=state.habitat;local stats=h.bonuses
        local function percent(value)return string.format("%.1f%%",(value-1)*100)end
        summary.Text="PRODUÇÃO +"..percent(stats.production).."   ·   MINERAÇÃO MANUAL +"..percent(stats.manual).."   ·   ¤ "..C.format(state.coins)
        for i,floor in P.floors do
            floorRows[i].Text=i.."º · "..(if h.floors>=i then "CONSTRUÍDO · 2 ESPAÇOS" else "R"..floor.rebirth.." · ¤ "..C.format(floor.cost))
            floorRows[i].TextColor3=if h.floors>=i then colors.mint else colors.muted
        end
        local nextFloor=P.floors[h.floors+1]
        build.Text=if not nextFloor then "CASA COMPLETA · 10 ESPAÇOS" elseif state.stars<nextFloor.rebirth then "REQUER RENASCIMENTO "..nextFloor.rebirth else (if h.floors==0 then "LOTE + CASA" else "CONSTRUIR "..(h.floors+1).."º ANDAR").." · ¤ "..C.format(nextFloor.cost)
        build.BackgroundColor3=if nextFloor and state.stars>=nextFloor.rebirth then colors.gold else colors.muted
        for slot,b in slots do
            local id=h.slots[tostring(slot)];local pet=id and P.byId[id]
            b.Text=if slot>h.capacity then "BLOQUEADO · "..math.ceil(slot/2).."º" else slot.." · "..(if pet then pet.name:match("^%S+") else "VAZIO")
            b.BackgroundColor3=if slot>h.capacity then colors.muted elseif self.slot==slot then colors.mint else colors.cream
        end
        for _,pet in P.pets do
            local b=petRows[pet.id];local level=h.owned[pet.id]
            b.Text=pet.name.."\n"..(if level then "NÍVEL "..level else pet.floor.."º ANDAR · ¤ "..C.format(pet.cost))
            b.BackgroundColor3=if pet.id==self.selected then colors.mint else colors.cream
        end
        local pet=P.byId[self.selected];local level=h.owned[pet.id]
        view:show("pet",pet.id,level or 1);name.Text=pet.name
        description.Text="+"..string.format("%.1f%%",P.bonus(pet,level or 1)*100).." "..(if pet.kind=="production" then "de produção automática" else "no valor de cada cristal minerado manualmente")
        requirement.Text=if level then "Nível "..level.." / "..P.maxLevel.." · bônus ativo enquanto hospedado." else "Desbloqueia ao construir o "..pet.floor.."º andar (renascimento "..P.floors[pet.floor].rebirth..")."
        adopt.Visible=not level;upgrade.Visible=level~=nil
        adopt.Text=if h.capacity<pet.floor*2 then "REQUER "..pet.floor.."º ANDAR" else "ADOTAR · ¤ "..C.format(pet.cost)
        upgrade.Text=if level and level>=P.maxLevel then "NÍVEL MÁXIMO" else "MELHORAR · ¤ "..C.format(P.upgradePrice(pet,level or 1))
        equip.Text=if self.slot>h.capacity then "ESPAÇO BLOQUEADO" else "HOSPEDAR NO ESPAÇO "..self.slot
        room.Text="Selecionado: "..math.ceil(self.slot/2).."º andar · espaço "..self.slot
    end
    return self
end
return House
