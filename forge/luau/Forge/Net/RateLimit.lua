--!strict
--[[
	RateLimit — continuous token buckets keyed by arbitrary strings.

	Per-key ("userId:event") token bucket that refills continuously, so two
	half-windows cannot double-spend the way a fixed window allows (the
	roblox-infected convention). Pure: nothing here sleeps. The caller either
	injects a clock at construction (`{ now = fn }`) or passes `now` per call,
	which keeps every accept/reject decision replayable in tests.

		local rl = RateLimit.new({ rate = 6, burst = 4 })
		local allowed, retryAfter = rl:try("42:FireWeapon")

	`try` spends one token and returns `(true)`; when dry it returns
	`(false, secondsUntilNextToken)` and records a violation against the key.
	`violations` reports that cumulative tally (anti-cheat fodder); `reset`
	wipes both bucket and tally for a key. New buckets start full.
]]

local RateLimit = {}

export type Clock = () -> number

export type Options = {
	rate: number, -- tokens regained per second
	burst: number?, -- capacity; defaults to rate (one second's worth)
	now: Clock?, -- injectable clock; defaults to os.clock at call time
}

export type Self = {
	rate: number,
	burst: number,
	now: Clock,
	buckets: { [string]: { tokens: number, last: number } },
	violationLog: { [string]: number },
}

function RateLimit.new(options: Options): Self
	assert(typeof(options.rate) == "number" and options.rate > 0, "rate must be a positive number")
	assert(options.burst == nil or options.burst >= 1, "burst must be at least 1")
	local self: Self = {
		rate = options.rate,
		burst = options.burst or options.rate,
		now = options.now or os.clock,
		buckets = {},
		violationLog = {},
	}
	setmetatable(self, RateLimit)
	return self
end

function RateLimit.try(self: Self, key: string, now: number?): (boolean, number?)
	assert(type(key) == "string" and #key > 0, "key must be a non-empty string")

	local at = now or self.now()
	local bucket = self.buckets[key]
	if bucket == nil then
		bucket = { tokens = self.burst, last = at }
		self.buckets[key] = bucket
	end

	-- Continuous refill. Clamp elapsed time: an out-of-order timestamp from
	-- the injected clock must never mint tokens retroactively.
	local elapsed = at - bucket.last
	if elapsed < 0 then
		elapsed = 0
	end
	bucket.tokens = math.min(self.burst, bucket.tokens + elapsed * self.rate)
	bucket.last = at

	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true, nil
	end

	self.violationLog[key] = (self.violationLog[key] or 0) + 1
	return false, (1 - bucket.tokens) / self.rate
end

function RateLimit.violations(self: Self, key: string): number
	return self.violationLog[key] or 0
end

function RateLimit.reset(self: Self, key: string): ()
	self.buckets[key] = nil
	self.violationLog[key] = nil
end

return RateLimit
