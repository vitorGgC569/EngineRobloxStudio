--!strict
--[[
	RebirthLoop — prestige arithmetic stripped of every side effect.

	Mined from minershaven: RebirthHandler charges MoneyLib.RebornPrice for the
	current life, jumps 1 + MoneyLib.LifeSkips lives when the balance dwarfs the
	price, then wipes the tycoon, rolls awards per crossed life and announces
	"born into their Nth life". All ceremony stays with the caller; this module
	only produces a plan.

		local loop = RebirthLoop.new({
			price = function(life) return 2.5e19 ^ (1 + life * 0.00024) end,
			rewardsOnLife = { [10] = { "inferno_box" }, [100] = { "final_upgrader" } },
		})

		if loop:canRebirth(state.balance, state.life) then
			local plan = loop:execute(state)
			if plan then
				state.balance = 0
				state.life = plan.newLife
				grant(plan.awards)
				broadcast(player.name .. " " .. plan.announce)
			end
		end

	Lives are 1-based: `{ life = 1, balance = ... }` is a fresh save. Skipping
	follows MoneyLib.LifeSkips exactly — each extra life costs the base price
	times another 10^3, probed from 20 skips down to 1.
]]

local RebirthLoop = {}
RebirthLoop.__index = RebirthLoop

export type PriceCurve = (life: number) -> number

export type LoopConfig = {
	price: PriceCurve,
	rewardsOnLife: { [number]: { any } }?,
}

export type RebirthState = {
	life: number,
	balance: number,
}

export type RebirthPlan = {
	wipe: boolean,
	newLife: number,
	skipped: number,
	awards: { any },
	announce: string,
}

type Internal = {
	price: PriceCurve,
	rewardsOnLife: { [number]: { any } },
}

export type RebirthLoop = typeof(setmetatable({} :: Internal, RebirthLoop))

local MAX_SKIP_DEPTH = 20
local SKIP_RATIO_STEP = 1e3

-- The caller keeps the tables it passed in, and a plan's awards must not be
-- the stored tables either. Editing a count after new, or on a previous plan,
-- would change the next execute.
local function deepCopy(value: any, seen: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in value :: { [any]: any } do
		copy[key] = deepCopy(item, seen)
	end
	return copy
end

function RebirthLoop.new(config: LoopConfig): RebirthLoop
	assert(type(config.price) == "function", "[RebirthLoop] price function is required")
	local self: Internal = setmetatable({}, RebirthLoop)
	self.price = config.price
	self.rewardsOnLife = deepCopy(config.rewardsOnLife or {}, {})
	return self :: any
end

local function ordinal(value: number): string
	local lastTwo = value % 100
	if lastTwo >= 11 and lastTwo <= 13 then
		return value .. "th"
	end
	local lastDigit = value % 10
	if lastDigit == 1 then
		return value .. "st"
	elseif lastDigit == 2 then
		return value .. "nd"
	elseif lastDigit == 3 then
		return value .. "rd"
	end
	return value .. "th"
end

function RebirthLoop.quote(self: RebirthLoop, life: number): number
	return self.price(life)
end

function RebirthLoop.canRebirth(self: RebirthLoop, balance: number, life: number): boolean
	return balance >= self.price(life)
end

function RebirthLoop.skipsAffordable(self: RebirthLoop, life: number, balance: number): number
	local basePrice = self.price(life)
	for depth = MAX_SKIP_DEPTH, 1, -1 do
		if balance > basePrice * (SKIP_RATIO_STEP ^ depth) then
			return depth
		end
	end
	return 0
end

function RebirthLoop.execute(self: RebirthLoop, state: RebirthState): RebirthPlan?
	if not self:canRebirth(state.balance, state.life) then
		return nil
	end

	local skipped = self:skipsAffordable(state.life, state.balance)
	local newLife = state.life + 1 + skipped

	local awards = {}
	for life = state.life + 1, newLife do
		for _, reward in (self.rewardsOnLife[life] or {}) do
			table.insert(awards, deepCopy(reward, {}))
		end
	end

	return {
		wipe = true,
		newLife = newLife,
		skipped = skipped,
		awards = awards,
		announce = string.format("was born into their %s life", ordinal(newLife)),
	}
end

return RebirthLoop
