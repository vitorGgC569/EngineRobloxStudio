-- Durable discoveries, recipe progression and weekly objectives; server owned.
local RS=game:GetService("ReplicatedStorage")
local Players=game:GetService("Players")
local Forge=require(RS.Forge)
local C=require(RS.Shared.TycoonConfig)
local D={};local ctx
local function week(now)return math.floor(((now or os.time())+3*86400)/604800)end
function D.prepare(p,now)
    p.discovery=p.discovery or {crystals={},blueprints={},crafted={},specialization="",honor=0,decoration="default"}
    local d=p.discovery;d.crystals=d.crystals or {};d.blueprints=d.blueprints or {};d.crafted=d.crafted or {}
    d.honor=d.honor or 0;d.specialization=d.specialization or "";d.decoration=d.decoration or "default"
    local current=week(now)
    if not p.weekly or (p.weekly.week or -1)<current then p.weekly={week=current,progress={},claims={}} end
    return d
end
function D.objectives(now)
    local shift=week(now)%3
    return {{id="mine",name="Minerador de aether",goal=60+shift*20,relics=6,cores=0},
        {id="waves",name="Explorador da torre",goal=15+shift*5,relics=10,cores=1},
        {id="dominion",name="Disputa pelo horizonte",goal=300+shift*60,relics=12,cores=1}}
end
function D.progress(p,id,amount)
    D.prepare(p);p.weekly.progress[id]=math.min(1e6,(p.weekly.progress[id] or 0)+amount)
end
function D.discover(p)
    local d=D.prepare(p)
    for index=1,p.level do local u=C.upgrades[index]
        if C.isMachine(u) then local _,tier=C.crystal(C.machineLevel(p.machineLevels,u.id));for i=1,tier do d.crystals[tostring(i)]=true end end
    end
end
function D.boss(p,wave)
    local d=D.prepare(p)
    for _,entry in C.blueprints do if wave>=entry.wave then d.blueprints[entry.id]=true end end
end
function D.craft(p,id)
    local d=D.prepare(p);local recipe
    for _,v in C.blueprints do if v.id==id then recipe=v end end
    if not recipe or d.crafted[id] or not d.blueprints[id] or not d.crystals[tostring(recipe.tier)] or p.cores<recipe.cores then return false end
    p.cores-=recipe.cores;d.crafted[id]=true;d.specialization=id;return true
end
function D.claim(p,id,now)
    D.prepare(p,now)
    for _,v in D.objectives(now) do
        if v.id==id and not p.weekly.claims[id] and (p.weekly.progress[id] or 0)>=v.goal then
            p.weekly.claims[id]=true;p.relics+=v.relics;p.cores+=v.cores;return true
        end
    end
    return false
end
function D.multiplier(p)return if p.discovery and p.discovery.specialization=="industry" and p.discovery.crafted.industry then 1.1 else 1 end
function D.snapshot(p)
    local d=D.prepare(p)
    return {crystals=d.crystals,blueprints=d.blueprints,crafted=d.crafted,specialization=d.specialization,honor=d.honor,decoration=d.decoration,
        objectives=D.objectives(),weekly=p.weekly,resetIn=604800-((os.time()+3*86400)%604800)}
end
function D.start(callbacks)
    ctx=callbacks
    Forge.Net.on("Craft",function(player,payload)
        local s=ctx.active(player);if not s or ctx.towerActive(player) then return end
        if D.craft(s.profile,payload.id) then ctx.feedback(player,"Projeto fabricado e equipado!","contract");ctx.equip(player)
        else ctx.feedback(player,"Requer projeto do chefe, cristal descoberto e núcleos.","error") end
        ctx.sync(player)
    end)
    Forge.Net.on("Specialize",function(player,payload)
        local s=ctx.active(player);if not s or ctx.towerActive(player) then return end
        local d=D.prepare(s.profile);if not d.crafted[payload.id] then return end
        d.specialization=payload.id;ctx.feedback(player,"Especialização equipada.");ctx.sync(player)
    end)
    Forge.Net.on("WeeklyClaim",function(player,payload)
        local s=ctx.active(player);if not s then return end
        if D.claim(s.profile,payload.id) then ctx.feedback(player,"Desafio semanal concluído!","contract");ctx.sync(player) end
    end)
    Forge.Net.on("Decoration",function(player,payload)
        local s=ctx.active(player);if not s then return end
        local d=D.prepare(s.profile)
        local allowed=payload.id=="default" or (payload.id=="champion" and d.honor>=25) or (payload.id=="astral" and d.crystals["4"])
        if not allowed then return end
        d.decoration=payload.id;ctx.decorate(s.plot,s.profile);ctx.sync(player)
    end)
end
return D
