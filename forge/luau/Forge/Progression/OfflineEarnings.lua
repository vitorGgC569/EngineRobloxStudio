--!strict
--[[
	OfflineEarnings — how much an absent earner collects when they return.

	Standard idle-economy policy, in the spirit of minershaven's big-number
	balances: short absences pay nothing, long ones are clipped to a temporal
	ceiling, and the payout is ceilinged against current wealth so a hoarder
	cannot farm absence for more than `relativeCapMultiple` times their balance.

		local result = OfflineEarnings.compute(incomePerSec, os.time() - lastSeen, {
			currentBalance = state.balance,
		})
		if result.amount > 0 then
			state.balance += result.amount
		end

	Pure: no clock of its own, the caller supplies `awaySeconds`. The result
	reports which cap bound via `capped`.
]]

local OfflineEarnings = {}

export type Config = {
	minSeconds: number?,
	temporalCap: number?,
	relativeCapMultiple: number?,
	currentBalance: number?,
}

export type Result = {
	secondsPaid: number,
	amount: number,
	capped: boolean,
}

local DEFAULT_MIN_SECONDS = 600
local DEFAULT_TEMPORAL_CAP = 259200
local DEFAULT_RELATIVE_CAP_MULTIPLE = 500

function OfflineEarnings.compute(incomePerSec: number, awaySeconds: number, config: Config?): Result
	local settings = config or {}
	local minSeconds = settings.minSeconds or DEFAULT_MIN_SECONDS
	local temporalCap = settings.temporalCap or DEFAULT_TEMPORAL_CAP
	local relativeCapMultiple = settings.relativeCapMultiple or DEFAULT_RELATIVE_CAP_MULTIPLE
	local currentBalance = settings.currentBalance or math.huge

	if incomePerSec <= 0 or awaySeconds < minSeconds then
		return {
			secondsPaid = 0,
			amount = 0,
			capped = false,
		}
	end

	local secondsPaid = math.min(awaySeconds, temporalCap)
	local capped = secondsPaid < awaySeconds
	local amount = math.floor(incomePerSec * secondsPaid)

	local ceiling = math.floor(relativeCapMultiple * currentBalance)
	if amount > ceiling then
		amount = ceiling
		capped = true
	end

	return {
		secondsPaid = secondsPaid,
		amount = amount,
		capped = capped,
	}
end

return OfflineEarnings
