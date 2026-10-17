-- Permanent home progression. Only canonical catalog prices and owned pets count.
local RS=game:GetService("ReplicatedStorage")
local Forge=require(RS.Forge)
local P=require(RS.Shared.PetConfig)
local H={}
function H.prepare(profile)
    profile.habitat=profile.habitat or {floors=0,owned={},slots={}}
    return profile.habitat
end
local function capacity(p)
    local h=H.prepare(p);local floors=0
    for i=1,math.min(h.floors,#P.floors)do if (p.stars or 0)>=P.floors[i].rebirth then floors=i else break end end
    return floors*2
end
function H.buyFloor(p)
    local h=H.prepare(p);local nextFloor=P.floors[h.floors+1]
    if not nextFloor then return false,"Sua casa já tem todos os andares." end
    if (p.stars or 0)<nextFloor.rebirth then return false,"Requer renascimento "..nextFloor.rebirth.."." end
    if p.coins<nextFloor.cost then return false,"Faltam coroas para construir este andar." end
    p.coins-=nextFloor.cost;h.floors+=1
    if h.floors==1 then h.owned.breeze=1;h.owned.pebble=1;h.slots["1"]="breeze";h.slots["2"]="pebble" end
    return true,if h.floors==1 then "Casa construída! Dois pets iniciais já estão hospedados." else "Novo andar pronto: +2 espaços para pets!"
end
function H.adopt(p,id)
    local h=H.prepare(p);local pet=P.byId[id]
    if not pet or h.owned[id] or capacity(p)<pet.floor*2 or p.coins<pet.cost then return false,"Construa o andar necessário e junte as coroas da adoção." end
    p.coins-=pet.cost;h.owned[id]=1
    -- Adopt into the first vacant, unlocked room; full homes keep it in reserve.
    for slot=1,capacity(p)do if not h.slots[tostring(slot)]then h.slots[tostring(slot)]=id;break end end
    return true,pet.name.." chegou à sua coleção!"
end
local function validSlot(p,slot)return type(slot)=="number" and slot==math.floor(slot) and slot>=1 and slot<=capacity(p)end
function H.equip(p,id,slot)
    local h=H.prepare(p)
    if not validSlot(p,slot) or not P.byId[id] or not h.owned[id] then return false,"Escolha um espaço desbloqueado e um pet seu." end
    for key,petId in h.slots do if petId==id then h.slots[key]=nil end end
    h.slots[tostring(slot)]=id;return true,"Pet hospedado neste espaço."
end
function H.unequip(p,slot)
    if not validSlot(p,slot) then return false,"Espaço bloqueado." end
    H.prepare(p).slots[tostring(slot)]=nil;return true,"Pet guardado na coleção; bônus pausado."
end
function H.upgrade(p,id)
    local h=H.prepare(p);local pet=P.byId[id];local level=h.owned[id]
    if not pet or not level then return false,"Adote este pet primeiro." end
    if level>=P.maxLevel then return false,"Este pet já está no nível máximo." end
    local price=P.upgradePrice(pet,level)
    if p.coins<price then return false,"Faltam coroas para melhorar este pet." end
    p.coins-=price;h.owned[id]+=1;return true,pet.name.." melhorado para o nível "..h.owned[id].."!"
end
function H.bonuses(p)
    local h=H.prepare(p);local result={production=1,manual=1};local seen={}
    for slot=1,capacity(p)do
        local id=h.slots[tostring(slot)];local pet=id and P.byId[id];local level=id and h.owned[id]
        if pet and level and not seen[id] then seen[id]=true;result[pet.kind]+=P.bonus(pet,math.clamp(level,1,P.maxLevel)) end
    end
    return result
end
function H.snapshot(p)
    local h=H.prepare(p)
    return {floors=h.floors,capacity=capacity(p),owned=h.owned,slots=h.slots,bonuses=H.bonuses(p)}
end
function H.start(ctx)
    for name,action in {HabitatBuy=function(p)return H.buyFloor(p)end,PetAdopt=function(p,v)return H.adopt(p,v.id)end,
        PetEquip=function(p,v)return H.equip(p,v.id,v.slot)end,PetUnequip=function(p,v)return H.unequip(p,v.slot)end,
        PetUpgrade=function(p,v)return H.upgrade(p,v.id)end}do
        Forge.Net.on(name,function(player,payload)
            local s=ctx.active(player);if not s then return end
            if ctx.towerActive(player) or not ctx.nearby(player,s.plot.habitatArrival.Position,85)then ctx.feedback(player,"Visite a casa na sua ilha para cuidar dos pets.","error");return end
            local ok,message=action(s.profile,payload)
            if ok then s.lastActive=os.clock();ctx.render(s.plot,s.profile);ctx.sync(player) end
            ctx.feedback(player,message,if ok then "build" else "error")
        end)
    end
    Forge.Net.on("PetVisit",function(player)
        local s=ctx.active(player);if not s or ctx.towerActive(player)then return end
        if os.clock()-(s.lastPetVisit or 0)<3 then return end
        local char=player.Character;local hum=char and char:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health<=0 then return end
        s.lastPetVisit=os.clock();char:PivotTo(s.plot.habitatArrival);ctx.sync(player)
        Forge.Net.fire(player,"OpenHabitat",{})
    end)
end
return H
