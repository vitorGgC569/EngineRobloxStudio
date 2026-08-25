--!strict
--[[
	IncomeTracker — a moving window of per-sample deltas for rate displays.

	Feed it income snapshots (`:sample(balance)`) and read `:average()` to show
	"$X per tick" without ever storing full history; only the last
	`windowSize` deltas are kept. The first sample is a baseline and
	contributes no delta.

		local tracker = IncomeTracker.new({ windowSize = 20 })
		RunService.Heartbeat:Connect(function()
			tracker:sample(getBalance())
			label.Text = math.floor(tracker:average()) .. " /s"
		end)

	Pure bookkeeping: no clock, no scheduling — sampling cadence belongs to
	the caller, so the window means "per sample", whatever that sample is.
]]

local IncomeTracker = {}
IncomeTracker.__index = IncomeTracker

export type TrackerConfig = {
	windowSize: number?,
}

type Internal = {
	windowSize: number,
	deltas: { number },
	hasPrevious: boolean,
	previous: number,
}

export type Tracker = typeof(setmetatable({} :: Internal, IncomeTracker))

local DEFAULT_WINDOW_SIZE = 20

function IncomeTracker.new(config: TrackerConfig?): Tracker
	local settings = config or {}
	local windowSize = settings.windowSize or DEFAULT_WINDOW_SIZE
	assert(windowSize >= 1, "[IncomeTracker] windowSize must be at least 1")
	return setmetatable({
		windowSize = windowSize,
		deltas = {},
		hasPrevious = false,
		previous = 0,
	}, IncomeTracker) :: any
end

function IncomeTracker.sample(self: Tracker, value: number)
	if self.hasPrevious then
		table.insert(self.deltas, value - self.previous)
		while #self.deltas > self.windowSize do
			table.remove(self.deltas, 1)
		end
	end
	self.hasPrevious = true
	self.previous = value
end

function IncomeTracker.average(self: Tracker): number
	local count = #self.deltas
	if count == 0 then
		return 0
	end
	local sum = 0
	for _, delta in self.deltas do
		sum += delta
	end
	return sum / count
end

function IncomeTracker.reset(self: Tracker)
	self.deltas = {}
	self.hasPrevious = false
	self.previous = 0
end

return IncomeTracker
