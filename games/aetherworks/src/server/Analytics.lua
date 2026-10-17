local Analytics=game:GetService("AnalyticsService")
local Run=game:GetService("RunService")
local Players=game:GetService("Players")
local Http=game:GetService("HttpService")
local Forge=require(game:GetService("ReplicatedStorage").Forge)
local A={};local sessions={};local steps={};local warned=false
function A.step(player,step,name)
    if step<=(steps[player] or 0)then return end;steps[player]=step
    sessions[player]=sessions[player] or Http:GenerateGUID(false)
    Forge.Telemetry.funnel("aetherworks.onboarding",step,tostring(player.UserId))
    if Run:IsStudio()then return end
    task.spawn(function()
        local ok,err=pcall(function()Analytics:LogFunnelStepEvent(player,"AetherworksOnboarding",sessions[player],step,name)end)
        if not ok and not warned then warned=true;warn("[Aetherworks] Analytics delivery failed: "..tostring(err))end
    end)
end
function A.event(player,name,value)
    Forge.Telemetry.event(name,{value=value or 1})
    if not Run:IsStudio()then task.spawn(function()local ok,err=pcall(function()Analytics:LogCustomEvent(player,name,value or 1)end);if not ok and not warned then warned=true;warn("[Aetherworks] Analytics delivery failed: "..tostring(err))end end)end
end
Players.PlayerRemoving:Connect(function(player)sessions[player]=nil;steps[player]=nil end)
return A
