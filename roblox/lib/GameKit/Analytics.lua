--!strict
-- L6: analytics.
--
-- The engine can prove the conveyor moves and the purchase persists. It cannot
-- say the second upgrade is priced wrong. `AnalyticsService` is the platform's
-- own answer to that, and it is the only instrument here that reports on whether
-- anyone is actually enjoying the thing:
--
--   funnel   -- where players drop out of onboarding, progression and the shop
--   economy  -- which sinks and sources move currency, and what a wallet holds
--   custom   -- anything else, segmented by custom fields
--
-- Wrapped rather than called directly for two reasons. First, every event gets
-- emitted from one place, so a game built on this SDK is instrumented whether or
-- not whoever wrote the feature remembered. Second, the service silently drops
-- malformed events -- a step index of zero, an empty funnel name, a currency
-- delta of nil -- and a dropped event is indistinguishable from a player who
-- never got there. The validation here turns that into a loud local error during
-- development instead of a hole in a dashboard three weeks later.

local AnalyticsService = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")

local Analytics = {}

export type Recorder = {
	--- False when the service is unavailable, so callers can assert rather than
	--- assume their dashboards are filling up.
	live: boolean,
	emitted: number,
	rejected: { string },
}

local state: Recorder = {
	live = false,
	emitted = 0,
	rejected = {},
}

local serviceAvailable: boolean? = nil

local function available(): boolean
	if serviceAvailable == nil then
		-- Studio without API access, and the Open Cloud Luau sandbox, both have
		-- the service present and non-functional. Probing the method is the only
		-- reliable signal.
		serviceAvailable = pcall(function()
			return AnalyticsService.LogCustomEvent ~= nil
		end)
	end
	return serviceAvailable :: boolean
end

local function reject(message: string)
	table.insert(state.rejected, message)
	if RunService:IsStudio() then
		-- Loud in Studio, quiet in production. A malformed event is a bug in the
		-- caller, and the only moment anyone can act on it is now.
		warn("[GameKit.Analytics] rejected event: " .. message)
	end
end

local function requireText(value: any, label: string): string?
	if type(value) ~= "string" or value == "" then
		reject(label .. " must be a non-empty string")
		return nil
	end
	return value
end

local function requirePlayer(player: any): Player?
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		reject("event needs a Player")
		return nil
	end
	return player
end

function Analytics.recorder(): Recorder
	state.live = available()
	return state
end

function Analytics._reset()
	state = { live = false, emitted = 0, rejected = {} }
	serviceAvailable = nil
end

-- -------------------------------------------------------------------- funnel

--- One step of a linear funnel: onboarding, a tutorial, a purchase flow.
---
--- `step` is one-based and must increase. Roblox reports funnels by step index,
--- so a zero or a repeat silently corrupts the chart rather than erroring.
function Analytics.funnelStep(player: Player, funnelName: string, step: number, stepName: string, sessionId: string?)
	local subject = requirePlayer(player)
	local funnel = requireText(funnelName, "funnelName")
	local label = requireText(stepName, "stepName")
	if subject == nil or funnel == nil or label == nil then
		return
	end
	if type(step) ~= "number" or step < 1 or step % 1 ~= 0 then
		reject(string.format("funnel %q step must be a positive integer, got %s", funnel, tostring(step)))
		return
	end
	if not available() then
		return
	end
	local ok, failure = pcall(function()
		AnalyticsService:LogFunnelStepEvent(subject, funnel, sessionId, step, label)
	end)
	if ok then
		state.emitted += 1
	else
		reject(tostring(failure))
	end
end

--- A funnel that a player can be in more than once, keyed by an instance id.
function Analytics.onboardingStep(player: Player, step: number, stepName: string)
	Analytics.funnelStep(player, "onboarding", step, stepName)
end

-- ------------------------------------------------------------------- economy

local FLOW = {
	source = Enum.AnalyticsEconomyFlowType.Source,
	sink = Enum.AnalyticsEconomyFlowType.Sink,
}

--- Record currency moving. `flow` is "source" (earned) or "sink" (spent).
---
--- `endingBalance` is not optional in practice even though the API tolerates
--- sloppiness: without it the wallet-balance chart is empty, and wallet balance
--- is the single number that tells you whether an economy is inflating.
function Analytics.economy(
	player: Player,
	flow: string,
	currency: string,
	amount: number,
	endingBalance: number,
	transactionType: string,
	itemSku: string?
)
	local subject = requirePlayer(player)
	local currencyName = requireText(currency, "currency")
	local transaction = requireText(transactionType, "transactionType")
	if subject == nil or currencyName == nil or transaction == nil then
		return
	end
	local flowType = FLOW[flow]
	if flowType == nil then
		reject(string.format('economy flow must be "source" or "sink", got %q', tostring(flow)))
		return
	end
	if type(amount) ~= "number" or amount <= 0 then
		reject("economy amount must be positive; direction is carried by flow, not by sign")
		return
	end
	if type(endingBalance) ~= "number" or endingBalance < 0 then
		reject("economy endingBalance must be a non-negative number")
		return
	end
	if not available() then
		return
	end
	local ok, failure = pcall(function()
		AnalyticsService:LogEconomyEvent(
			subject,
			flowType,
			currencyName,
			amount,
			endingBalance,
			transaction,
			itemSku
		)
	end)
	if ok then
		state.emitted += 1
	else
		reject(tostring(failure))
	end
end

-- -------------------------------------------------------------------- custom

--- Anything the built-in event types do not cover.
---
--- Roblox allows three custom fields. More than that is silently dropped, so the
--- limit is enforced here where it can be seen.
function Analytics.custom(player: Player, eventName: string, value: number?, fields: { [string]: string }?)
	local subject = requirePlayer(player)
	local name = requireText(eventName, "eventName")
	if subject == nil or name == nil then
		return
	end

	local customFields: { [any]: any } = {}
	local count = 0
	local keys = {}
	for key in pairs(fields or {}) do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		count += 1
		if count > 3 then
			reject(string.format(
				"custom event %q supplied %d fields; Roblox accepts three and drops the rest",
				name, #keys
			))
			break
		end
		local slot = (Enum.AnalyticsCustomFieldKeys :: any)["CustomField0" .. tostring(count)]
		if slot ~= nil then
			customFields[slot.Name] = (fields :: { [string]: string })[key]
		end
	end

	if not available() then
		return
	end
	local ok, failure = pcall(function()
		AnalyticsService:LogCustomEvent(subject, name, value, customFields)
	end)
	if ok then
		state.emitted += 1
	else
		reject(tostring(failure))
	end
end

-- ----------------------------------------------------------------- reporting

--- What was emitted and what was refused, for a measurement run to assert on.
function Analytics.report(): { [string]: any }
	return {
		live = available(),
		emitted = state.emitted,
		rejected = table.clone(state.rejected),
		rejectedCount = #state.rejected,
	}
end

return Analytics
