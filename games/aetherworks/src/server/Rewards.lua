local RS=game:GetService("ReplicatedStorage")
local C=require(RS.Shared.TycoonConfig)
local Net=require(RS.Forge).Net
local Rewards={}
local function day() return math.floor(os.time()/86400) end
function Rewards.step(profile,dt,isActive,todayOverride)
    local today=todayOverride or day()
    if profile.lastVisitDay~=today then
        profile.lastVisitDay=today;profile.daysPlayed+=1
    end
    if profile.playDay~=today then profile.playDay=today;profile.dayPlaySeconds=0;profile.timeClaims={} end
    profile.rewardActive=isActive~=false
    if profile.rewardActive then profile.dayPlaySeconds+=math.max(0,dt);profile.totalPlaySeconds+=math.max(0,dt) end
end
function Rewards.claimDay(p,today)
    today=today or day()
    if p.lastDailyDay>=today then return nil end
    p.dailyStreak=if p.lastDailyDay==today-1 then (p.dailyStreak or 0)+1 else 1
    p.bestStreak=math.max(p.bestStreak or 0,p.dailyStreak)
    local index=p.dailyClaims%7+1
    p.lastDailyDay=today;p.lastDaily=os.time();p.dailyClaims+=1
    return index,1+math.min(7,p.dailyStreak-1)*.05
end
function Rewards.snapshot(profile)
    local today=day();local ready=false
    for _,reward in C.timeRewards do
        if profile.dayPlaySeconds>=reward.minutes*60 and not profile.timeClaims[reward.id] then ready=true end
    end
    return {seconds=math.floor(profile.dayPlaySeconds),totalSeconds=math.floor(profile.totalPlaySeconds),daysPlayed=profile.daysPlayed,
        claims=profile.timeClaims,dailyReady=profile.lastDailyDay~=today,dayIndex=profile.dailyClaims%7+1,dailyClaims=profile.dailyClaims,
        timeReady=ready,resetIn=(today+1)*86400-os.time(),active=profile.rewardActive,
        streak=profile.dailyStreak or 0,bestStreak=profile.bestStreak or 0,visitClaims=profile.visitClaims or {}}
end
function Rewards.start(ctx)
    Net.on("Daily",function(player)
        local s=ctx.active(player);if not s then return end
        local p=s.profile;Rewards.step(p,0,p.rewardActive)
        local index,streakBonus=Rewards.claimDay(p)
        if not index then ctx.feedback(player,"O presente de hoje já foi recolhido.");return end
        local amount=math.floor((C.dayRewards[index]+math.min(50000,C.rate(p.level,p.stars,p.research,p.machineLevels,p.legacy)*8))*streakBonus)
        ctx.credit(p,amount)
        local relics=if index==7 then 3 elseif index==3 then 1 else 0
        p.relics+=relics
        ctx.feedback(player,"DIA "..index.." · +"..C.format(amount).." coroas"..(if relics>0 then " e "..relics.." relíquias!" else "!"),"contract")
        ctx.sync(player)
    end)
    Net.on("TimeReward",function(player,payload)
        local s=ctx.active(player);if not s then return end
        local p=s.profile;Rewards.step(p,0,p.rewardActive)
        local reward
        for _,candidate in C.timeRewards do if candidate.id==payload.id then reward=candidate;break end end
        if not reward or p.timeClaims[payload.id] then return end
        if p.dayPlaySeconds<reward.minutes*60 then ctx.feedback(player,"Essa recompensa ainda está em preparação.");return end
        p.timeClaims[payload.id]=true
        local amount=reward.coins+math.min(50000,C.rate(p.level,p.stars,p.research,p.machineLevels,p.legacy)*10)
        ctx.credit(p,amount);p.relics+=reward.relics
        ctx.feedback(player,reward.minutes.." MINUTOS · +"..C.format(amount).." coroas"..(if reward.relics>0 then " e "..reward.relics.." relíquias!" else "!"),"contract")
        ctx.sync(player)
    end)
    Net.on("VisitReward",function(player,payload)
        local s=ctx.active(player);if not s then return end
        local p=s.profile;Rewards.step(p,0,p.rewardActive)
        local reward
        for _,entry in C.visitMilestones do if entry.days==payload.days then reward=entry;break end end
        local key=tostring(payload.days)
        if not reward or p.visitClaims[key] or p.daysPlayed<reward.days then return end
        p.visitClaims[key]=true;p.relics+=reward.relics;p.cores+=reward.cores
        ctx.feedback(player,reward.days.." dias de história · +"..reward.relics.." relíquias e +"..reward.cores.." núcleos!","contract");ctx.sync(player)
    end)
end
return Rewards
