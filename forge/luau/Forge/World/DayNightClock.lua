--!strict
--[[
	DayNightClock — server-authoritative day/night cycle.

	One clock for the whole server: a normalized cycle position drives
	lighting presets and gates time-sensitive perks (night bonuses).
	Deterministic from epoch, so any client can compute the same phase.
]]

local DayNightClock = {}

export type Phase = "dawn" | "day" | "dusk" | "night"

type Self = {
	cycleSeconds: number,
	startOffset: number,
	phaseBoundaries: { { at: number, phase: Phase } },
	clock: () -> number,
}

DayNightClock.__index = DayNightClock

function DayNightClock.new(config: { cycleSeconds: number?, startOffset: number?, clock: (() -> number)? }): Self
	return setmetatable({
		cycleSeconds = config.cycleSeconds or 1200,
		startOffset = config.startOffset or 0,
		phaseBoundaries = {
			{ at = 0.0, phase = "dawn" :: Phase },
			{ at = 0.15, phase = "day" :: Phase },
			{ at = 0.6, phase = "dusk" :: Phase },
			{ at = 0.75, phase = "night" :: Phase },
		},
		clock = config.clock or os.time,
	}, DayNightClock)
end

-- 0..1 position within the current cycle.
function DayNightClock.position(self: Self): number
	local t = (self.clock() + self.startOffset) % self.cycleSeconds
	return t / self.cycleSeconds
end

function DayNightClock.phase(self: Self): Phase
	local pos = self:position()
	local current: Phase = "night"
	for _, boundary in self.phaseBoundaries do
		if pos >= boundary.at then
			current = boundary.phase
		end
	end
	return current
end

function DayNightClock.isNight(self: Self): boolean
	return self:phase() == "night"
end

return DayNightClock
