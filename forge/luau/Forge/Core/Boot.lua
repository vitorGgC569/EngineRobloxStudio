--!strict
--[[
	Boot — a startup that waits for things instead of hoping about them.

	The bug this exists to make impossible
	--------------------------------------

	Every startup race has one shape: a system starts, needs something that is
	not ready, and instead of *waiting for that thing* it does one of three
	losing moves — waits on a fire-once event that has already fired and hangs
	for ever, polls an attribute on a timer, or looks for a child and gives up
	if it is missing.

	All three are timing-driven, and timing-driven startups do not fail when
	you write them. They fail later, on a slower machine or a faster one, and
	the symptom is never where the cause is. This project has already paid for
	that twice: a `SubscribeAsync` called inline stopped a server's bootstrap
	dead *after* the world was built, so `CharacterAutoLoads` was never
	re-enabled and no player ever got a body — with no error anywhere.

	Two pieces, and the second is worth as much as the first:

		Boot.signal("world_ready")            -- idempotent; second call is a no-op
		Boot.await("world_ready", 30)         -- instant if already signalled

		Boot.declare("crystals", {
			producedBy = "BreakableSpawner",
			requires = { "world_ready", "models_ready" },
		})
		Boot.validate()                       -- loud now, not silently racy later

	Why `await` returning instantly matters
	---------------------------------------

	It is the whole difference between this and a `BindableEvent`. A late
	subscriber to a fire-once event waits for a signal that already happened,
	which is a hang rather than an error, and a hang in startup looks exactly
	like a slow machine. A latch has no such state: it is either set, in which
	case you continue, or it is not, in which case you wait for it to be.

	The usage rule
	--------------

	Never `await` inside a system's `start()`. That blocks the loader and turns
	one slow milestone into a dead server. Await inside a `task.spawn`:

		task.spawn(function()
			Boot.await("models_ready")
			dressTheWorld()
			Boot.signal("world_dressed")
		end)
]]

local RunService = game:GetService("RunService")

local Boot = {}

type Milestone = {
	producedBy: string,
	requires: { string },
}

local latched: { [string]: number } = {}
local waiters: { [string]: { thread } } = {}
local declared: { [string]: Milestone } = {}
local startedAt = os.clock()

--[[
	How long a milestone may take before the wait is reported as a problem.

	Not a hard failure: a startup that kills itself at thirty seconds is worse
	than one that says "this is taking longer than expected" and keeps going.
	The number exists so a hang has a voice.
]]
Boot.patience = 30

-- ================================== latch ===================================
--[[
	Mark a milestone reached. Idempotent, on purpose.

	Startup code gets called twice more often than anyone expects — a retry, a
	second consumer, a system that starts itself defensively. A signal that
	throws or double-fires on the second call turns that into a bug; one that
	shrugs turns it into nothing.
]]
function Boot.signal(name: string): boolean
	if latched[name] then
		return false
	end
	latched[name] = os.clock() - startedAt

	local queued = waiters[name]
	waiters[name] = nil
	if queued then
		for _, thread in queued do
			-- Resumed on their own thread, so one slow waiter cannot delay the
			-- next, and an error in one cannot swallow the signal for the rest.
			task.spawn(thread)
		end
	end
	return true
end

function Boot.isSignalled(name: string): boolean
	return latched[name] ~= nil
end

--[[
	Wait for a milestone, or return immediately if it has already happened.

	Returns whether it was reached. A false means the timeout ran out, which
	the caller can act on — the point of a bounded wait is that "it never
	happened" is an answer rather than a hang.
]]
function Boot.await(name: string, timeout: number?): boolean
	if latched[name] then
		return true
	end

	local thread = coroutine.running()
	local list = waiters[name]
	if not list then
		list = {}
		waiters[name] = list
	end
	table.insert(list, thread)

	local limit = timeout or Boot.patience
	local resumed = false
	task.delay(limit, function()
		if resumed or latched[name] then
			return
		end
		-- Drop this waiter and wake it, so a milestone that never arrives
		-- produces a false rather than a thread parked for the session.
		local queued = waiters[name]
		if queued then
			local index = table.find(queued, thread)
			if index then
				table.remove(queued, index)
			end
		end
		warn(string.format(
			"[Boot] '%s' did not arrive within %ds; continuing without it", name, limit))
		task.spawn(thread)
	end)

	coroutine.yield()
	resumed = true
	return latched[name] ~= nil
end

--[[
	Do something once a milestone lands, without blocking the caller.

	The safe form of `await`, and the one a system's `start()` should use. It
	is `task.spawn` plus the wait, which is the pattern everybody writes by
	hand and half of them write wrong.
]]
function Boot.onReady(name: string, fn: () -> (), timeout: number?)
	task.spawn(function()
		if Boot.await(name, timeout) then
			fn()
		end
	end)
end

--[[
	Wait for several milestones at once.

	Sequential rather than parallel because they are latches: waiting for A
	then B costs the same as waiting for both, and the sequential form is one
	loop instead of a counter and a signal.
]]
function Boot.awaitAll(names: { string }, timeout: number?): boolean
	local all = true
	for _, name in names do
		if not Boot.await(name, timeout) then
			all = false
		end
	end
	return all
end

-- ================================== graph ===================================
--[[
	Say which milestone depends on what, and who is supposed to produce it.

	The declaration is the value. Without it a missing producer is a race that
	shows up on someone else's machine; with it, `validate` says so at startup
	in one line naming the milestone and the system that owed it.
]]
function Boot.declare(name: string, milestone: Milestone)
	declared[name] = {
		producedBy = milestone.producedBy,
		requires = milestone.requires or {},
	}
end

function Boot.declareMany(table_: { [string]: Milestone })
	for name, milestone in table_ do
		Boot.declare(name, milestone)
	end
end

--[[
	Check the graph is honest before anything runs on it.

	Two faults, both of which are silent races at runtime and loud sentences
	here: a milestone that something requires and nobody produces, and a cycle.
	Returns the list of problems rather than throwing, so a caller can decide
	whether a half-declared graph is worth starting.
]]
function Boot.validate(): { string }
	local problems: { string } = {}

	for name, milestone in declared do
		for _, requirement in milestone.requires do
			if not declared[requirement] then
				table.insert(problems, string.format(
					"'%s' requires '%s', which nothing declares a producer for",
					name, requirement))
			end
		end
	end

	--[[
		Cycles, by depth-first search with a colour per node.

		`visiting` is the grey set: meeting a grey node again is a cycle, and
		meeting a black one is a path already known to be clean. Without the
		black set a wide graph is walked exponentially.
	]]
	local visiting: { [string]: boolean } = {}
	local done: { [string]: boolean } = {}

	local function walk(name: string, trail: { string })
		if done[name] then
			return
		end
		if visiting[name] then
			table.insert(problems, string.format(
				"cycle: %s -> %s", table.concat(trail, " -> "), name))
			return
		end
		visiting[name] = true
		local milestone = declared[name]
		if milestone then
			local next_ = table.clone(trail)
			table.insert(next_, name)
			for _, requirement in milestone.requires do
				walk(requirement, next_)
			end
		end
		visiting[name] = nil
		done[name] = true
	end

	for name in declared do
		walk(name, {})
	end

	for _, problem in problems do
		warn("[Boot] " .. problem)
	end
	return problems
end

-- ================================= reading ==================================
--[[
	Mirror the milestones where a client can read them.

	A loading screen that polls the world for symptoms — is the terrain there
	yet, are there any props — is guessing, and it guesses wrong the moment the
	world changes shape. Reading the server's own account of what is ready is
	the same information without the guess.
]]
function Boot.mirror(parent: Instance?): Folder?
	if not RunService:IsServer() then
		return nil
	end
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local root = (parent or ReplicatedStorage):FindFirstChild("ForgeBoot")
	if not root then
		local folder = Instance.new("Folder")
		folder.Name = "ForgeBoot"
		folder.Parent = parent or ReplicatedStorage
		root = folder
	end

	local function publish(name: string, seconds: number)
		local value = root:FindFirstChild(name)
		if not value then
			local created = Instance.new("NumberValue")
			created.Name = name
			created.Parent = root
			value = created
		end
		(value :: NumberValue).Value = seconds
	end

	for name, seconds in latched do
		publish(name, seconds)
	end
	return root :: Folder
end

function Boot.describe(): { [string]: any }
	local reached, pending = {}, {}
	for name, seconds in latched do
		table.insert(reached, { name = name, atSeconds = math.floor(seconds * 100) / 100 })
	end
	for name in declared do
		if not latched[name] then
			table.insert(pending, name)
		end
	end
	table.sort(reached, function(a, b)
		return a.atSeconds < b.atSeconds
	end)
	table.sort(pending)

	local waiting = {}
	for name, list in waiters do
		waiting[name] = #list
	end

	return {
		reached = reached,
		pending = pending,
		waiting = waiting,
		declared = (function()
			local n = 0
			for _ in declared do
				n += 1
			end
			return n
		end)(),
		uptimeSeconds = math.floor((os.clock() - startedAt) * 100) / 100,
	}
end

--: For tests, which need a startup that has not happened yet.
function Boot.reset()
	table.clear(latched)
	table.clear(waiters)
	table.clear(declared)
	startedAt = os.clock()
end

return Boot
