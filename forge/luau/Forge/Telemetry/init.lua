--!strict
--[[
	Telemetry — what actually happened, in a live game.

	`Debug.expose` answers questions in a Studio session. It cannot tell you that
	3% of players never finish spawning, that the tutorial loses a third of
	people at step four, or that one error fires eleven thousand times a day
	from one line.

	This is the module that substitutes for judgement. An agent proposing a
	balance change is guessing; a funnel showing where players stop is evidence.

		Telemetry.sink(function(batch) ... end)     -- you choose the destination
		Telemetry.event("salvage.opened", { kind = "hull", player = id })
		Telemetry.funnel("onboarding", 3, subject)
		Telemetry.mark(subject, "first_kill")

	Forge does not pick a destination. Open Cloud, an HTTP endpoint, a DataStore,
	or `print` in development — you register a sink and the buffering, batching,
	retry and error aggregation are handled.
]]

local Players = game:GetService("Players")
local ScriptContext = game:GetService("ScriptContext")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Stats = game:GetService("Stats")

local Signal = require(script.Parent.Core.Signal)

local Telemetry = {}

Telemetry.flushed = Signal.new() -- (count)

type Entry = { name: string, at: number, props: any }

local buffer: { Entry } = {}
local sinks: { (batch: { Entry }) -> boolean? } = {}
local funnels: { [string]: { [string]: number } } = {} -- funnel -> subject -> furthest step
local funnelCounts: { [string]: { [number]: number } } = {}
local marks: { [string]: { [string]: number } } = {}
local errorCounts: { [string]: { count: number, first: number, last: number, sample: string } } = {}
local sessions: { [Player]: { started: number, events: number } } = {}
local totals = { events = 0, flushed = 0, dropped = 0, batches = 0 }
local started = os.clock()
local wired = false

Telemetry.config = {
	bufferLimit = 500, -- hard cap; beyond this the oldest go
	flushInterval = 30,
	flushAt = 100, -- flush early once the buffer reaches this
	captureErrors = true,
	sampleRate = 1, -- 0..1, for very hot events
	enabled = true,
}

-- ================================== sinks ===================================
--[[
	A sink returns true if it accepted the batch. A sink that returns false or
	errors keeps the batch buffered for the next flush, which is what stops a
	transient HTTP failure from silently deleting an hour of data.
]]
function Telemetry.sink(fn: (batch: { Entry }) -> boolean?)
	table.insert(sinks, fn)
end

function Telemetry.clearSinks()
	table.clear(sinks)
end

-- ================================= events ===================================
function Telemetry.event(name: string, props: any?)
	if not Telemetry.config.enabled then
		return
	end
	if Telemetry.config.sampleRate < 1 and math.random() > Telemetry.config.sampleRate then
		return
	end

	table.insert(buffer, { name = name, at = os.time(), props = props or {} })
	totals.events += 1

	if #buffer > Telemetry.config.bufferLimit then
		table.remove(buffer, 1)
		totals.dropped += 1
	end
	if #buffer >= Telemetry.config.flushAt then
		task.spawn(Telemetry.flush)
	end
end

-- ================================= funnels ==================================
--[[
	A funnel records the furthest step each subject reached. Recording every
	step transition instead would answer the same question with fifty times the
	volume, and the question is always "where do they stop".
]]
function Telemetry.funnel(name: string, step: number, subject: string)
	local perSubject = funnels[name]
	if not perSubject then
		perSubject = {}
		funnels[name] = perSubject
		funnelCounts[name] = {}
	end

	local previous = perSubject[subject] or 0
	if step <= previous then
		return
	end
	perSubject[subject] = step

	local counts = funnelCounts[name]
	for reached = previous + 1, step do
		counts[reached] = (counts[reached] or 0) + 1
	end

	Telemetry.event("funnel." .. name, { step = step, subject = subject })
end

-- Drop-off per step: the shape a designer actually reads.
function Telemetry.funnelReport(name: string): { [string]: any }
	local counts = funnelCounts[name] or {}
	local steps = {}
	for step in counts do
		table.insert(steps, step)
	end
	table.sort(steps)

	local report = {}
	local previousCount = nil
	for _, step in steps do
		local count = counts[step]
		table.insert(report, {
			step = step,
			reached = count,
			dropFromPrevious = previousCount and (previousCount - count) or 0,
			retention = previousCount and previousCount > 0 and (count / previousCount) or 1,
		})
		previousCount = count
	end
	return { funnel = name, steps = report }
end

-- One-off milestones: first kill, first purchase, tutorial complete.
function Telemetry.mark(subject: string, milestone: string)
	local perSubject = marks[subject]
	if not perSubject then
		perSubject = {}
		marks[subject] = perSubject
	end
	if perSubject[milestone] then
		return false
	end
	perSubject[milestone] = os.time()
	Telemetry.event("mark." .. milestone, { subject = subject })
	return true
end

function Telemetry.hasMark(subject: string, milestone: string): boolean
	return marks[subject] ~= nil and marks[subject][milestone] ~= nil
end

-- ================================== errors ==================================
--[[
	Errors are aggregated by signature, not logged individually. One broken line
	in a Heartbeat produces thousands of identical messages; what you need is
	"this one, 11,402 times, since 09:14".
]]
local function signatureOf(message: string): string
	-- strip numbers and addresses so the same fault collapses to one key
	local signature = string.gsub(message, "%d+", "#")
	signature = string.gsub(signature, "0x%x+", "@")
	return string.sub(signature, 1, 160)
end

function Telemetry.error(message: string, context: any?)
	local signature = signatureOf(message)
	local entry = errorCounts[signature]
	if entry then
		entry.count += 1
		entry.last = os.time()
	else
		errorCounts[signature] = { count = 1, first = os.time(), last = os.time(), sample = message }
		-- Only the first of a kind goes to the sink; the rest ride the count.
		Telemetry.event("error", { signature = signature, message = message, context = context })
	end
end

function Telemetry.errorReport(): { any }
	local out = {}
	for signature, entry in errorCounts do
		table.insert(out, {
			signature = signature,
			count = entry.count,
			first = entry.first,
			last = entry.last,
			sample = entry.sample,
		})
	end
	table.sort(out, function(a, b)
		return a.count > b.count
	end)
	return out
end

-- ================================= sessions =================================
local function beginSession(player: Player)
	sessions[player] = { started = os.clock(), events = 0 }
	Telemetry.event("session.start", {
		subject = "player:" .. player.UserId,
		accountAge = player.AccountAge,
		device = "unknown", -- the client reports this once it knows
	})
end

local function endSession(player: Player)
	local session = sessions[player]
	if not session then
		return
	end
	Telemetry.event("session.end", {
		subject = "player:" .. player.UserId,
		seconds = math.floor(os.clock() - session.started),
	})
	sessions[player] = nil
end

-- ================================== flush ===================================
function Telemetry.flush(): number
	if #buffer == 0 or #sinks == 0 then
		return 0
	end
	local batch = table.clone(buffer)
	table.clear(buffer)

	local accepted = false
	for _, sink in sinks do
		local ok, result = pcall(sink, batch)
		if ok and result ~= false then
			accepted = true
		elseif not ok then
			warn("[Telemetry] sink errored: " .. tostring(result))
		end
	end

	if not accepted then
		-- Put it back at the front; the next flush tries again.
		for index = #batch, 1, -1 do
			table.insert(buffer, 1, batch[index])
		end
		while #buffer > Telemetry.config.bufferLimit do
			table.remove(buffer, 1)
			totals.dropped += 1
		end
		return 0
	end

	totals.flushed += #batch
	totals.batches += 1
	Telemetry.flushed:Fire(#batch)
	return #batch
end

function Telemetry.start()
	if wired then
		return
	end
	wired = true

	if RunService:IsServer() then
		Players.PlayerAdded:Connect(beginSession)
		for _, player in Players:GetPlayers() do
			beginSession(player)
		end
		Players.PlayerRemoving:Connect(endSession)

		game:BindToClose(function()
			for player in sessions do
				endSession(player)
			end
			Telemetry.flush()
		end)
	end

	if Telemetry.config.captureErrors then
		ScriptContext.Error:Connect(function(message, trace, _script)
			Telemetry.error(message, { trace = string.sub(trace or "", 1, 400) })
		end)
	end

	task.spawn(function()
		while true do
			task.wait(Telemetry.config.flushInterval)
			Telemetry.flush()

			-- A periodic health beat is what makes "the server got slow at
			-- 21:40" answerable after the fact.
			Telemetry.event("server.health", {
				players = #Players:GetPlayers(),
				heartbeatMs = Stats.HeartbeatTimeMs,
				memoryMb = math.floor(Stats:GetTotalMemoryUsageMb()),
				instances = Stats.InstanceCount,
				uptime = math.floor(os.clock() - started),
			})
		end
	end)
end

-- =============================== datastore sink =============================
--[[
	The sink most games want, and the one `forge analytics` reads.

	Lived as a private function inside one game until a second game needed it
	and got nothing instead — its events were counted and dropped for exactly
	as long as it had been running. That is the signature of something that
	should have been engine from the start.

	A DataStore rather than an HTTP endpoint on purpose. Sending player events
	to an outside service is a decision about someone else's data and not one
	an engine should quietly make; a DataStore keeps them durable, queryable
	and inside the account that produced them. Swapping in an external sink
	later is one call to `Telemetry.sink`.

	One key per day, so a month of play is thirty-one keys rather than a key
	per event. `forge analytics` reads this exact store and this exact key
	shape, so the reader and the writer cannot drift apart.
]]
Telemetry.STORE = "ForgeAnalytics"
Telemetry.KEY_PREFIX = "events/"

--: A day's key has a size limit; this is where the oldest start going.
Telemetry.rowsPerDay = 900

function Telemetry.dataStoreSink(storeName: string?): boolean
	if not RunService:IsServer() then
		return false
	end
	local DataStoreService = game:GetService("DataStoreService")
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(storeName or Telemetry.STORE)
	end)
	if not ok or not store then
		warn("[Telemetry] no analytics store; events will be counted and dropped")
		return false
	end

	Telemetry.sink(function(batch)
		if #batch == 0 then
			return true
		end
		local day = os.date("!%Y-%m-%d")
		local written = pcall(function()
			--[[
				`UpdateAsync`, not `SetAsync`.

				Several servers write the same day's key at once. `SetAsync`
				would have the last one win and silently discard every other
				server's events — which for analytics means numbers that are
				wrong in a way nobody can detect from the numbers.
			]]
			store:UpdateAsync(Telemetry.KEY_PREFIX .. day, function(existing)
				local rows = existing or {}
				for _, entry in batch do
					if #rows >= Telemetry.rowsPerDay then
						table.remove(rows, 1)
					end
					table.insert(rows, {
						t = entry.at or os.time(),
						n = entry.name,
						p = entry.props,
					})
				end
				return rows
			end)
		end)
		return written
	end)
	return true
end

-- A sink that prints, for development. Deliberately not the default: silently
-- printing telemetry in production is how a game ships with no analytics and
-- nobody noticing.
function Telemetry.printSink()
	Telemetry.sink(function(batch)
		print(string.format("[Telemetry] %d events", #batch))
		for _, entry in batch do
			print("  ", entry.name, HttpService:JSONEncode(entry.props))
		end
		return true
	end)
end

function Telemetry.describe(): { [string]: any }
	local funnelNames = {}
	for name in funnels do
		table.insert(funnelNames, name)
	end
	table.sort(funnelNames)

	local topErrors = {}
	for index, entry in Telemetry.errorReport() do
		if index > 5 then
			break
		end
		table.insert(topErrors, { count = entry.count, sample = string.sub(entry.sample, 1, 90) })
	end

	return {
		enabled = Telemetry.config.enabled,
		sinks = #sinks,
		buffered = #buffer,
		events = totals.events,
		flushed = totals.flushed,
		dropped = totals.dropped,
		batches = totals.batches,
		funnels = funnelNames,
		distinctErrors = (function()
			local n = 0
			for _ in errorCounts do
				n += 1
			end
			return n
		end)(),
		topErrors = topErrors,
		activeSessions = (function()
			local n = 0
			for _ in sessions do
				n += 1
			end
			return n
		end)(),
	}
end

return Telemetry
