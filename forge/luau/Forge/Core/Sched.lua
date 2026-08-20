--!strict
--[[
	Sched — how work gets spread across frames.

	Two failure modes this exists to prevent:

	1. One `RunService.Heartbeat:Connect` per entity. Two hundred wolves become
	   two hundred connections, each paying dispatch overhead, none of them
	   aware of the frame budget. Use a `group` and tick them together.

	2. Generation loops that run to completion and freeze the server for eight
	   seconds. Use `budgeted` and the work yields when the frame gets expensive.
]]

local RunService = game:GetService("RunService")

local Sched = {}

-- ============================ throttled groups ==============================
-- A set of subscribers ticked at a fixed rate, off one connection.
-- Members are spread across ticks so 200 actors never all think on one frame.

local Group = {}
Group.__index = Group

function Sched.group(rate: number, phase: string?): any
	local self = setmetatable({
		interval = 1 / math.max(rate, 0.01),
		members = {},
		_accum = 0,
		_cursor = 1,
		_slices = 1,
	}, Group)

	local signal = if phase == "render" then RunService.RenderStepped else RunService.Heartbeat
	self._conn = signal:Connect(function(dt)
		self:_tick(dt)
	end)
	return self
end

-- slices > 1 spreads the group over N frames: 4 slices means each member is
-- updated every 4th tick, and each frame only pays a quarter of the cost.
function Group:setSlices(n: number)
	self._slices = math.max(1, math.floor(n))
end

function Group:add(key: any, fn: (dt: number, key: any) -> ())
	self.members[key] = fn
end

function Group:remove(key: any)
	self.members[key] = nil
end

function Group:count(): number
	local n = 0
	for _ in self.members do
		n += 1
	end
	return n
end

function Group:_tick(dt: number)
	self._accum += dt
	if self._accum < self.interval then
		return
	end
	local elapsed = self._accum
	self._accum = 0

	local slices = self._slices
	if slices <= 1 then
		for key, fn in self.members do
			local ok, err = pcall(fn, elapsed, key)
			if not ok then
				warn("[Sched] group member error: " .. tostring(err))
				self.members[key] = nil
			end
		end
		return
	end

	-- deterministic round-robin over a stable ordering of keys
	local keys = {}
	for key in self.members do
		table.insert(keys, key)
	end
	local slice = self._cursor
	self._cursor = (self._cursor % slices) + 1
	for i = slice, #keys, slices do
		local key = keys[i]
		local fn = self.members[key]
		if fn then
			local ok, err = pcall(fn, elapsed * slices, key)
			if not ok then
				warn("[Sched] group member error: " .. tostring(err))
				self.members[key] = nil
			end
		end
	end
end

function Group:destroy()
	if self._conn then
		self._conn:Disconnect()
	end
	table.clear(self.members)
end

-- ============================= budgeted work ================================
-- Runs `fn(i)` for i = 1..count, yielding whenever the frame budget is spent.
-- Terrain generation, prop scattering, save migration — anything long.

function Sched.budgeted(count: number, fn: (index: number) -> (), budgetMs: number?)
	local budget = (budgetMs or 2) / 1000
	local start = os.clock()
	for i = 1, count do
		fn(i)
		if os.clock() - start > budget then
			task.wait()
			start = os.clock()
		end
	end
end

-- Same idea for an unbounded producer: `step` returns false when finished.
function Sched.drain(step: () -> boolean, budgetMs: number?)
	local budget = (budgetMs or 2) / 1000
	local start = os.clock()
	while step() do
		if os.clock() - start > budget then
			task.wait()
			start = os.clock()
		end
	end
end

-- ============================== rate limiting ===============================
function Sched.debounce(seconds: number): (any?) -> boolean
	local last: { [any]: number } = {}
	return function(key: any?): boolean
		local k = key == nil and "__default" or key
		local now = os.clock()
		if now - (last[k] or -math.huge) < seconds then
			return false
		end
		last[k] = now
		return true
	end
end

-- Token bucket: allows short bursts, caps sustained rate. What every
-- client->server action should sit behind.
function Sched.bucket(ratePerSecond: number, burst: number?): (any?) -> boolean
	local capacity = burst or ratePerSecond
	local state: { [any]: { tokens: number, last: number } } = {}
	return function(key: any?): boolean
		local k = key == nil and "__default" or key
		local now = os.clock()
		local s = state[k]
		if not s then
			s = { tokens = capacity, last = now }
			state[k] = s
		end
		s.tokens = math.min(capacity, s.tokens + (now - s.last) * ratePerSecond)
		s.last = now
		if s.tokens < 1 then
			return false
		end
		s.tokens -= 1
		return true
	end
end

-- Coalesces bursts into one call at the end of the frame. For "state changed,
-- resync the client" paths that would otherwise fire twelve times in a tick.
function Sched.deferred(fn: (...any) -> ()): (...any) -> ()
	local queued = false
	local lastArgs: { any } = {}
	return function(...)
		lastArgs = table.pack(...)
		if queued then
			return
		end
		queued = true
		task.defer(function()
			queued = false
			fn(table.unpack(lastArgs, 1, lastArgs.n))
		end)
	end
end

return Sched
