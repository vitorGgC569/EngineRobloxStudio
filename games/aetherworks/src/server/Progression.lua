-- Permanent trees share one server transaction path and survive every rebirth.
local RS=game:GetService("ReplicatedStorage")
local C=require(RS.Shared.TycoonConfig)
local Net=require(RS.Forge).Net
local Progression={}
function Progression.purchase(profile,tree,id)
    if tree~="legacy" and tree~="towerResearch" then return false,"Pesquisa desconhecida." end
    local nodes=if tree=="legacy" then C.legacyNodes else C.towerNodes
    local node
    for _,entry in nodes do if entry.id==id then node=entry;break end end
    if not node then return false,"Pesquisa desconhecida." end
    if profile.stars<(node.rebirth or 0) then return false,"Requer renascimento "..node.rebirth.."." end
    if node.requires and not profile.perks[node.requires] then return false,"Desbloqueie "..C.perks[node.requires].name.." primeiro." end
    local levels=profile[tree];local level=levels[id] or 0
    if tree=="legacy" and id=="recovery" and C.offlineLimit(profile)>=86400 then return false,"Reserva máxima: 24 horas." end
    local price=C.nodePrice(node,level);local currency=if tree=="legacy" then "cores" else "relics"
    if profile[currency]<price then return false,"Faltam "..(price-profile[currency])..(if currency=="cores" then " núcleos." else " relíquias.") end
    profile[currency]-=price;levels[id]=level+1
    return true,node.name.." · nível "..(level+1).."!"
end
function Progression.start(ctx)
    Net.on("ResearchNode",function(player,payload)
        local s=ctx.active(player);if not s then return end
        if ctx.towerActive(player) then ctx.feedback(player,"Encerre a expedição para pesquisar.","error");return end
        local ok,message=Progression.purchase(s.profile,payload.tree,payload.id)
        if ok then ctx.equip(player);s.lastActive=os.clock() end
        ctx.feedback(player,message,if ok then "contract" else "error");ctx.sync(player)
    end)
end
return Progression
