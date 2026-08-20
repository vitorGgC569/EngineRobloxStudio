--!strict
--- Time: delays, intervals, cooldowns, debounce, and a shared clock.
---
--- `task.wait` in a loop is how most Roblox timing is written and it drifts:
--- each iteration costs the wait plus whatever the body took, so an "every
--- second" loop runs every 1.03s and is a minute behind after half an hour.
--- Wave timers, respawns and day/night cycles all show it.
---
--- **One heartbeat drives everything here.** Twenty systems each with their own
--- `RunService` connection is twenty dispatches a frame; this is one, and every
--- timer is a row in a table. It also means a paused game pauses every timer
--- consistently rather than each one deciding for itself.

local RunService = game:GetService("RunService")

local Timer = {}

export type Handle = {
	cancel: (Handle) -> (),
	id: number,
}

local entries: { [number]: any } = {}
local nextId = 0
local connection: RBXScriptConnection? = nil
local paused = false

local function tick(delta: number)
	if paused then
		return
	end
	local now = os.clock()
	-- Snapshot: a callback that schedules or cancels a timer must not disturb
	-- the walk.
	local due = {}
	for id, entry in pairs(entries) do
		if now >= entry.at then
			table.insert(due, id)
		end
	end
	for _, id in ipairs(due) do
		local entry = entries[id]
		if entry ~= nil then
			if entry.every ~= nil then
				-- Advance from the scheduled time, not from now. Adding the
				-- interval to `now` is what makes a repeating timer drift.
				entry.at += entry.every
				if entry.at <= now then
					entry.at = now + entry.every
				end
			else
				entries[id] = nil
			end
			local ok, err = pcall(entry.body, delta)
			if not ok then
				warn(("[Timer] %s errored: %s"):format(entry.label, tostring(err)))
				entries[id] = nil
			end
		end
	end
	if next(entries) == nil and connection ~= nil then
		connection:Disconnect()
		connection = nil
	end
end

local function ensureClock()
	if connection == nil then
		connection = RunService.Heartbeat:Connect(tick)
	end
end

local function schedule(seconds: number, body: (number) -> (), every: number?, label: string?): Handle
	nextId += 1
	local id = nextId
	entries[id] = {
		at = os.clock() + seconds,
		every = every,
		body = body,
		label = label or ("timer#" .. id),
	}
	ensureClock()
	local handle = {
		id = id,
		cancel = function()
			entries[id] = nil
		end,
	}
	return (handle :: any) :: Handle
end

--- Run once, later.
function Timer.after(seconds: number, body: (number) -> (), label: string?): Handle
	return schedule(math.max(seconds, 0), body, nil, label)
end

--- Run forever, on a beat that does not drift.
function Timer.every(seconds: number, body: (number) -> (), label: string?): Handle
	if seconds <= 0 then
		error("Timer.every needs a positive interval", 2)
	end
	return schedule(seconds, body, seconds, label)
end

--- Run every frame until it returns true, or until cancelled.
function Timer.each(body: (number) -> boolean?, label: string?): Handle
	local handle
	handle = schedule(0, function(delta)
		local ok, done = pcall(body, delta)
		if not ok or done == true then
			if not ok then
				warn(("[Timer] %s errored: %s"):format(label or "each", tostring(done)))
			end
			handle:cancel()
		end
	end, 1 / 60, label)
	return handle
end

--- Run `count` times at `seconds` apart, then stop. Waves, volleys, bursts.
function Timer.repeated(count: number, seconds: number, body: (number, number) -> (), label: string?): Handle
	local fired = 0
	local handle
	handle = Timer.every(seconds, function()
		fired += 1
		body(fired, count)
		if fired >= count then
			handle:cancel()
		end
	end, label)
	return handle
end

--- A gate that only opens once per interval.
---
--- Returns a function: call it, and it answers whether this call is allowed.
--- The commonest shape in a game -- a weapon that fires, a door that will not
--- re-trigger, a prompt that cannot be spammed.
function Timer.cooldown(seconds: number): (() -> boolean, () -> number)
	local last = -math.huge
	local function try(): boolean
		local now = os.clock()
		if now - last < seconds then
			return false
		end
		last = now
		return true
	end
	local function remaining(): number
		return math.max(seconds - (os.clock() - last), 0)
	end
	return try, remaining
end

--- Wrap a function so it runs at most once per interval, on the leading edge.
function Timer.throttle<T...>(seconds: number, body: (T...) -> ()): (T...) -> ()
	local allow = Timer.cooldown(seconds)
	return function(...)
		if allow() then
			body(...)
		end
	end
end

--- Wrap a function so it runs after things go quiet, on the trailing edge.
---
--- Throttle fires first and ignores the rest; debounce ignores everything until
--- the storm ends and then fires once. Search-as-you-type wants debounce; a
--- weapon wants throttle. Confusing them is the usual bug.
function Timer.debounce<T...>(seconds: number, body: (T...) -> ()): (T...) -> ()
	local pending: Handle? = nil
	return function(...)
		local packed = table.pack(...)
		if pending ~= nil then
			pending:cancel()
		end
		pending = Timer.after(seconds, function()
			pending = nil
			body(table.unpack(packed, 1, packed.n) :: any)
		end)
	end
end

--- Yield for a duration, respecting the shared pause.
function Timer.wait(seconds: number)
	local finished = false
	Timer.after(seconds, function()
		finished = true
	end)
	while not finished do
		RunService.Heartbeat:Wait()
	end
end

function Timer.pause()
	paused = true
end

function Timer.resume()
	paused = false
end

function Timer.cancelAll(): number
	local count = 0
	for _ in pairs(entries) do
		count += 1
	end
	table.clear(entries)
	return count
end

function Timer.report(): { [string]: any }
	local live = {}
	for id, entry in pairs(entries) do
		table.insert(live, {
			id = id,
			label = entry.label,
			inSeconds = math.max(entry.at - os.clock(), 0),
			repeating = entry.every ~= nil,
		})
	end
	table.sort(live, function(a, b)
		return a.inSeconds < b.inSeconds
	end)
	return { timers = live, paused = paused, running = connection ~= nil }
end

return Timer
