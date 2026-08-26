--!strict
--[[
	IncomeTracker — a moving window of per-sample deltas for rate displays.

	Feed it income snapshots (`:sample(balance)`) and read `:average()` to show
	"$X per tick" without ever storing full history; only the last
	`windowSize` deltas are kept. The first sample is a baseline and
	contributes no delta.

		local tracker = IncomeTracker.new({ interval = 2, warmupSeconds = 60 })
		while task.wait(2) do
			tracker:sample(getBalance())
			label.Text = tracker:ready() and (math.floor(tracker:rate()) .. "/s") or "--"
		end

	Pure bookkeeping: no clock, no scheduling -- sampling cadence belongs to
	the caller, so the window means "per sample", whatever that sample is.

	What a shipped tycoon learned about this
	----------------------------------------

	A live simulator's income display samples every two seconds over a window of
	twenty, waits a full minute before showing anything, discards negative
	deltas, and wipes itself on several specific events. Each of those guards
	against a way this display goes wrong, and none of them are obvious until
	it does:

	  * **Spending is not negative income.** A player buying an upgrade drops
	    their balance, and a raw delta window reads that as earning less than
	    nothing. `ignoreNegative` (on by default) drops those samples rather
	    than averaging them in, so the number means "what I earn" rather than
	    "how my balance moved".

	  * **A fresh window lies.** The first few samples of a session -- or the
	    first after a layout change -- average over almost no history and swing
	    wildly. The shipped version waits sixty seconds before it will show a
	    number at all. `ready()` is that gate; a display that shows "--" for a
	    minute is better than one that shows a number that is wrong.

	  * **Some events invalidate the whole history.** Rebirth, prestige, a
	    gift, anything that discontinuously changes earning rate: the samples
	    from before it describe a player who no longer exists. Call `reset()`
	    on those. It is not enough to let the window age out, because a window
	    is forty seconds of a player being told the wrong thing.

	One deliberate divergence: the shipped version divides the delta by its
	sample interval and then divides the mean by that interval a second time, so
	the number it displays is a fraction of the true rate. `rate()` divides
	once. If you are porting from that code and the numbers look larger here,
	this is why, and the number here is the correct one.
]]

local IncomeTracker = {}
IncomeTracker.__index = IncomeTracker

export type TrackerConfig = {
	windowSize: number?,
	--: Seconds between samples. Only needed for `rate()`; `average()` is
	--: per-sample and does not care how far apart the samples were.
	interval: number?,
	--: Drop samples where the balance fell. On by default: a rate display
	--: almost always means earnings, not net balance movement.
	ignoreNegative: boolean?,
	--: How long before the average is trustworthy. Expressed in seconds when
	--: `interval` is set, otherwise in samples.
	warmupSeconds: number?,
	warmupSamples: number?,
}

type Internal = {
	windowSize: number,
	interval: number?,
	ignoreNegative: boolean,
	warmupSamples: number,
	deltas: { number },
	hasPrevious: boolean,
	previous: number,
	--: Counts every sample taken, including ones the window has since dropped
	--: and ones `ignoreNegative` discarded. Warmup is about elapsed time, not
	--: about how many samples happened to survive.
	seen: number,
}

export type Tracker = typeof(setmetatable({} :: Internal, IncomeTracker))

local DEFAULT_WINDOW_SIZE = 20

function IncomeTracker.new(config: TrackerConfig?): Tracker
	local settings = config or {}
	local windowSize = settings.windowSize or DEFAULT_WINDOW_SIZE
	assert(windowSize >= 1, "[IncomeTracker] windowSize must be at least 1")

	local warmup = settings.warmupSamples or 0
	if settings.warmupSeconds and settings.interval and settings.interval > 0 then
		warmup = math.ceil(settings.warmupSeconds / settings.interval)
	end

	return setmetatable({
		windowSize = windowSize,
		interval = settings.interval,
		ignoreNegative = settings.ignoreNegative ~= false,
		warmupSamples = warmup,
		deltas = {},
		hasPrevious = false,
		previous = 0,
		seen = 0,
	}, IncomeTracker) :: any
end

--[[
	Record a balance. Returns the delta that was kept, or nil if it was
	discarded -- which a caller can use to tell "earned nothing" from "spent".
]]
function IncomeTracker.sample(self: Tracker, value: number): number?
	local kept: number? = nil
	if self.hasPrevious then
		local delta = value - self.previous
		self.seen += 1
		--: A negative delta is a purchase, not a loss of earning power. Keeping
		--: it would make the rate dip every time the player spends, which is
		--: the opposite of what the number is for.
		if delta >= 0 or not self.ignoreNegative then
			table.insert(self.deltas, delta)
			while #self.deltas > self.windowSize do
				table.remove(self.deltas, 1)
			end
			kept = delta
		end
	end
	self.hasPrevious = true
	self.previous = value
	return kept
end

--: Mean delta per sample. Zero with no history, which reads the same as
--: "earning nothing" -- use `ready()` when the difference matters.
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

--[[
	Income per second.

	Requires `interval`; without one there is no way to know what a sample is
	worth in time, and guessing would produce a confidently wrong number.
]]
function IncomeTracker.rate(self: Tracker): number
	local interval = self.interval
	if not interval or interval <= 0 then
		error("[IncomeTracker] rate() needs an interval; use average() otherwise", 2)
	end
	return IncomeTracker.average(self) / interval
end

--[[
	Whether enough history exists for the average to mean anything.

	Separate from the average itself so a display can show "--" rather than a
	number it will have to contradict a few seconds later.
]]
function IncomeTracker.ready(self: Tracker): boolean
	return self.seen >= self.warmupSamples
end

--[[
	Throw the history away.

	Call this on anything that discontinuously changes earning rate: rebirth,
	prestige, a gift, a sacrifice, a layout wipe. The window is a description of
	a player's income, and after one of those it describes a player who no
	longer exists.

	The warmup restarts too, deliberately: the first samples after a rebirth are
	exactly as unrepresentative as the first samples after a join.
]]
function IncomeTracker.reset(self: Tracker)
	self.deltas = {}
	self.hasPrevious = false
	self.previous = 0
	self.seen = 0
end

return IncomeTracker
