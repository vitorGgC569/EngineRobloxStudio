--!strict
-- Thin wrapper over Roblox's native AnalyticsService so round/engagement/economy events
-- show up on the Creator Hub analytics dashboards (the "sink you can read"). Every call is
-- pcall-guarded and no-ops if analytics isn't enabled for the universe, so this can never
-- affect gameplay. Other services call these semantic methods; the Roblox API shape stays
-- contained here.

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")

local Analytics = {}
Analytics.__index = Analytics

function Analytics.new()
	return setmetatable({}, Analytics)
end

function Analytics:_custom(player: Player?, name: string, value: number?, fields: { [string]: string }?)
	local target = player or Players:GetPlayers()[1]
	if target == nil then
		return
	end
	pcall(function()
		AnalyticsService:LogCustomEvent(target, name, value, fields)
	end)
end

function Analytics:onRoundStart(playerCount: number, modifierId: string?)
	self:_custom(nil, "RoundStart", playerCount, modifierId and { modifier = modifierId } or nil)
end

function Analytics:onRoundEnd(winner: string, conversions: number)
	self:_custom(nil, "RoundEnd", conversions, { winner = winner })
end

function Analytics:onConversion(killer: Player?)
	if killer then
		self:_custom(killer, "Conversion", 1)
	end
end

function Analytics:onLevelUp(player: Player, level: number)
	self:_custom(player, "LevelUp", level)
end

-- Onboarding funnel: which tutorial step a new player reached (1-based).
function Analytics:onTutorialStep(player: Player, step: number, stepName: string)
	pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, stepName)
	end)
end

-- Economy: a crate open (source flow). currency is "Coins" | "Keys" | "Robux".
function Analytics:onCrateOpen(player: Player, currency: string)
	self:_custom(player, "CrateOpen", 1, { currency = currency })
end

return Analytics
