--!strict
--[[
	DailyRewardCalendar — login streaks over absolute UTC days, no Instances.

	Mined from minershaven DailyRewards: a claim counts as consecutive only
	when it lands on the day right after the last one (rawday == day() - 1);
	anything older resets the streak to 1. Rewards cycle through fixed slots,
	the way Berezaa's handler hands out crates on streak positions.

		local calendar = DailyRewardCalendar.new({
			milestones = { [3] = "unreal_box", [5] = "inferno_box", [7] = "spectral_box" },
			cycleLength = 7,
			now = os.time,
		})

		local newState, reward, info = calendar:claim(state)
		local upcoming = calendar:preview(state)

	State is `{ lastClaimDay = number?, streak = number }` — plain data, safe
	to serialize. Days are `math.floor(timestamp / 86400)`; passing an explicit
	timestamp to `claim` keeps the module deterministic under tests.
]]

local DailyRewardCalendar = {}
DailyRewardCalendar.__index = DailyRewardCalendar

export type CalendarConfig = {
	milestones: { [number]: any },
	cycleLength: number?,
	now: (() -> number)?,
}

export type CalendarState = {
	lastClaimDay: number?,
	streak: number,
}

export type StreakInfo = {
	streak: number,
	cycleDay: number,
	granted: boolean,
}

type Internal = {
	milestones: { [number]: any },
	cycleLength: number,
	now: () -> number,
}

export type Calendar = typeof(setmetatable({} :: Internal, DailyRewardCalendar))

local SECONDS_PER_DAY = 86400
local DEFAULT_CYCLE_LENGTH = 7

local function dayNumber(timestamp: number): number
	return math.floor(timestamp / SECONDS_PER_DAY)
end

function DailyRewardCalendar.new(config: CalendarConfig): Calendar
	assert(type(config.milestones) == "table", "[DailyRewardCalendar] milestones table is required")
	local self: Internal = setmetatable({}, DailyRewardCalendar)
	self.cycleLength = config.cycleLength or DEFAULT_CYCLE_LENGTH
	self.now = config.now or os.time
	self.milestones = {}
	for cycleDay, reward in pairs(config.milestones) do
		assert(cycleDay >= 1 and cycleDay <= self.cycleLength, string.format("[DailyRewardCalendar] milestone day %d outside cycle 1..%d", cycleDay, self.cycleLength))
		self.milestones[cycleDay] = reward
	end
	return self :: any
end

function DailyRewardCalendar.cycleDayFor(self: Calendar, streak: number): number
	return ((streak - 1) % self.cycleLength) + 1
end

function DailyRewardCalendar.claim(self: Calendar, state: CalendarState, timestamp: number?): (CalendarState, any?, StreakInfo)
	local today = dayNumber(timestamp or self.now())

	if state.lastClaimDay == today then
		return state, nil, {
			streak = state.streak,
			cycleDay = self:cycleDayFor(state.streak),
			granted = false,
		}
	end

	local streak = 1
	if state.lastClaimDay == today - 1 then
		streak = state.streak + 1
	end

	local cycleDay = ((streak - 1) % self.cycleLength) + 1
	local newState: CalendarState = {
		lastClaimDay = today,
		streak = streak,
	}

	return newState, self.milestones[cycleDay], {
		streak = streak,
		cycleDay = cycleDay,
		granted = true,
	}
end

function DailyRewardCalendar.preview(self: Calendar, state: CalendarState, timestamp: number?): { StreakInfo }
	local today = dayNumber(timestamp or self.now())

	local nextStreak = 1
	if state.lastClaimDay == today then
		nextStreak = state.streak + 1
	elseif state.lastClaimDay == today - 1 then
		nextStreak = state.streak + 1
	end

	local upcoming = {}
	for offset = 0, self.cycleLength - 1 do
		local streak = nextStreak + offset
		table.insert(upcoming, {
			streak = streak,
			cycleDay = ((streak - 1) % self.cycleLength) + 1,
			granted = false,
		})
	end
	return upcoming
end

return DailyRewardCalendar
