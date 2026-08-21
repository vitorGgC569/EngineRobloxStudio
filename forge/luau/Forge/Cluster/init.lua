--!strict
--[[
	Cluster — the engine stops assuming there is one server.

	Everything Forge did before this ended at the edge of a session. `Save` had
	a session lock but nothing to coordinate with; `LiveOps` polled a DataStore
	on a timer because it had no way to be *told*; a leaderboard could only ever
	rank the twelve people in the room. None of that reads as a bug from inside
	one server, which is exactly why it survived: a single-server assumption is
	invisible until the day the game has two.

	Two Roblox services do the work, and they are for different things:

	  `MessagingService` is a shout. Fire-and-forget, roughly a second of
	  latency, no history, no delivery guarantee. Right for "a boss just spawned
	  in server 12" and for pushing a config change that would otherwise wait a
	  minute for the next poll.

	  `MemoryStoreService` is shared *state*. Fast, transactional, and it
	  expires. Right for a matchmaking queue, a global counter, a live-event
	  total that every server contributes to.

	Using one where the other belongs is the classic mistake. A queue built on
	messages loses players; a shout built on a memory store polls forever.

		Cluster.on("boss.spawned", function(payload, fromServer) ... end)
		Cluster.shout("boss.spawned", { name = "Hollowed King" })

		Cluster.queue("ranked"):push(player.UserId, { rating = 1400 })
		local party = Cluster.queue("ranked"):take(4)

		Cluster.counter("event.shards"):add(12)

	--- Limits that are real ------------------------------------------------

	Roblox rate-limits both services per universe, and exceeding the limit
	drops calls rather than erroring. So every publish here goes through a
	token bucket sized under the documented ceiling, and a message that cannot
	be sent now is queued rather than lost. A cross-server layer that silently
	drops under load is worse than none, because it works in testing.
]]

local MessagingService = game:GetService("MessagingService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Core).Signal

local Cluster = {}

--: This server's identity, stable for its lifetime.
Cluster.serverId = game.JobId ~= "" and game.JobId or ("studio-" .. HttpService:GenerateGUID(false))

Cluster.config = {
	--[[
		Roblox allows roughly 600 + 200×players messages per minute per
		universe, shared by every server. Sizing well under it is not caution:
		over the limit, calls are dropped rather than refused, so the failure
		mode is silence.
	]]
	messagesPerMinute = 120,
	burst = 20,
	--: How long a queued message waits before it is not worth sending.
	staleAfter = 30,
	--: Default expiry for shared state. MemoryStore requires one.
	memoryTtl = 3600,
	queueTimeout = 300,
}

Cluster.received = Signal.new() -- (topic, payload, fromServerId)
Cluster.dropped = Signal.new() -- (topic, reason)

local subscriptions: { [string]: RBXScriptConnection } = {}
local handlers: { [string]: { (payload: any, from: string) -> () } } = {}
local outbox: { { topic: string, payload: any, at: number } } = {}
local tokens = Cluster.config.burst
local lastRefill = os.clock()
local pump: thread? = nil
local stats = { sent = 0, received = 0, dropped = 0, queued = 0, failures = 0 }

local function serverOnly(what: string): boolean
	if RunService:IsServer() then
		return true
	end
	warn(string.format(
		"[Cluster] %s is server-only. A client that could shout to every server "
		.. "is a client that can shout anything to every server.", what))
	return false
end

-- ================================= messaging ================================
local function refill()
	local now = os.clock()
	local elapsed = now - lastRefill
	lastRefill = now
	tokens = math.min(
		Cluster.config.burst,
		tokens + elapsed * (Cluster.config.messagesPerMinute / 60))
end

local function trySend(topic: string, payload: any): boolean
	local ok, err = pcall(function()
		MessagingService:PublishAsync(topic, {
			from = Cluster.serverId,
			at = os.time(),
			body = payload,
		})
	end)
	if ok then
		stats.sent += 1
		return true
	end
	stats.failures += 1
	warn(string.format("[Cluster] publish to '%s' failed: %s", topic, tostring(err)))
	return false
end

local function startPump()
	if pump then
		return
	end
	pump = task.spawn(function()
		while true do
			task.wait(0.25)
			refill()

			while #outbox > 0 and tokens >= 1 do
				local entry = table.remove(outbox, 1)
				--[[
					A stale shout is worse than a missing one.

					"The boss spawned" delivered ninety seconds late tells every
					player something that is no longer true, and they act on it.
					Dropping loudly beats delivering a lie quietly.
				]]
				if os.clock() - entry.at > Cluster.config.staleAfter then
					stats.dropped += 1
					Cluster.dropped:Fire(entry.topic, "stale")
					continue
				end
				tokens -= 1
				trySend(entry.topic, entry.payload)
			end

			if #outbox == 0 then
				-- Nothing waiting; sleep until something is queued.
				pump = nil
				break
			end
		end
	end)
end

--[[
	Tell every other server something.

	Rate-limited and queued rather than sent immediately, because Roblox drops
	calls past the limit instead of refusing them. Returns whether it went out
	now; either way it is either delivered or reported dropped, never silently
	lost.
]]
function Cluster.shout(topic: string, payload: any?): boolean
	if not serverOnly("shout") then
		return false
	end
	refill()
	if tokens >= 1 then
		tokens -= 1
		return trySend(topic, payload)
	end

	table.insert(outbox, { topic = topic, payload = payload, at = os.clock() })
	stats.queued += 1
	startPump()
	return false
end

--[[
	Listen for what other servers shout.

	One Roblox subscription per topic no matter how many handlers register:
	subscriptions are a limited resource and a module that opens one per
	listener runs out on a busy game.

	A server never hears its own shout — Roblox delivers it back, and a handler
	that acts on its own message double-counts everything.
]]
--: Topics whose subscription is in flight, so a second caller does not start
--: a second one while the first is still waiting on the service.
local subscribing: { [string]: boolean } = {}

function Cluster.on(topic: string, fn: (payload: any, from: string) -> ()): () -> ()
	if not serverOnly("on") then
		return function() end
	end

	handlers[topic] = handlers[topic] or {}
	table.insert(handlers[topic], fn)

	--[[
		Subscribe off the bootstrap path, never on it.

		`SubscribeAsync` yields, and on a place that is not published it does
		not fail quickly — it waits. Called inline this stopped a game's whole
		server bootstrap dead: the world was built, the systems were up, and
		the line after this one never ran, so `CharacterAutoLoads` was never
		re-enabled and no player ever got a body. From the outside it looked
		like a game with no characters and no error.

		A `pcall` was already here and did nothing about it: it catches a
		failure and has no opinion about a call that simply does not return.

		The handler is registered above, synchronously, so the API contract
		holds the instant this returns. The transport catches up when it can,
		and a game that never gets one still runs — it just does not hear from
		other servers, which is the correct behaviour for a place that has no
		other servers.
	]]
	if not subscriptions[topic] and not subscribing[topic] then
		subscribing[topic] = true
		task.spawn(function()
		local ok, connection = pcall(function()
			return MessagingService:SubscribeAsync(topic, function(message)
				local data = message.Data
				if typeof(data) ~= "table" then
					return
				end
				if data.from == Cluster.serverId then
					return -- our own shout, echoed back
				end
				stats.received += 1
				Cluster.received:Fire(topic, data.body, data.from)
				for _, handler in handlers[topic] or {} do
					task.spawn(handler, data.body, data.from)
				end
			end)
		end)
		subscribing[topic] = nil
		if ok and connection then
			subscriptions[topic] = connection
		else
			stats.failures += 1
			warn(string.format("[Cluster] could not subscribe to '%s': %s",
				topic, tostring(connection)))
		end
		end)
	end

	return function()
		local list = handlers[topic]
		if not list then
			return
		end
		local index = table.find(list, fn)
		if index then
			table.remove(list, index)
		end
		if #list == 0 and subscriptions[topic] then
			subscriptions[topic]:Disconnect()
			subscriptions[topic] = nil
		end
	end
end

-- =============================== shared state ===============================
local maps: { [string]: any } = {}

local function mapFor(name: string): any
	if not maps[name] then
		local ok, map = pcall(function()
			return MemoryStoreService:GetSortedMap(name)
		end)
		maps[name] = ok and map or false
	end
	return maps[name] or nil
end

--[[
	A counter every server contributes to.

	`UpdateAsync` rather than get-then-set, for the same reason it matters in
	`Save`: two servers adding to a live-event total at the same moment must
	both count. A read followed by a write loses one of them, and the number
	that is wrong is the one the whole event is scored on.
]]
local Counter = {}
Counter.__index = Counter

function Counter:add(amount: number): number?
	local map = mapFor(self.name)
	if not map then
		return nil
	end
	local result
	local ok, err = pcall(function()
		map:UpdateAsync(self.key, function(old)
			result = (old or 0) + amount
			return result
		end, Cluster.config.memoryTtl)
	end)
	if not ok then
		stats.failures += 1
		warn(string.format("[Cluster] counter '%s' failed: %s", self.name, tostring(err)))
		return nil
	end
	return result
end

function Counter:get(): number
	local map = mapFor(self.name)
	if not map then
		return 0
	end
	local ok, value = pcall(function()
		return map:GetAsync(self.key)
	end)
	return (ok and typeof(value) == "number") and value or 0
end

function Cluster.counter(name: string, key: string?): any
	return setmetatable({ name = "counter_" .. name, key = key or "total" }, Counter)
end

--[[
	A matchmaking queue that spans servers.

	Built on `MemoryStoreQueue`, which is the only thing here that is genuinely
	a queue: entries are claimed by exactly one reader and re-appear if that
	reader dies without confirming. That last property is why this is not a
	sorted map with a lock — a server that crashes mid-match must not take four
	players' places with it.
]]
local Queue = {}
Queue.__index = Queue

function Queue:push(subject: any, payload: any?, priority: number?): boolean
	local ok, err = pcall(function()
		self.queue:AddAsync(
			{ subject = subject, payload = payload, from = Cluster.serverId, at = os.time() },
			Cluster.config.queueTimeout,
			priority or 0)
	end)
	if not ok then
		stats.failures += 1
		warn(string.format("[Cluster] queue '%s' push failed: %s", self.name, tostring(err)))
	end
	return ok
end

--[[
	Claim up to `count` entries.

	Returns the entries and a `confirm` function. Nothing is removed from the
	queue until `confirm` is called, so a server that fails to build the match
	releases the players back rather than losing them. Calling `confirm` is the
	promise that the match happened.
]]
function Queue:take(count: number, waitSeconds: number?): ({ any }, () -> ())
	local ok, entries, id = pcall(function()
		return self.queue:ReadAsync(count, false, waitSeconds or 0)
	end)
	if not ok or not entries then
		return {}, function() end
	end

	local claimed = entries :: { any }
	local claimId = id
	return claimed, function()
		pcall(function()
			self.queue:RemoveAsync(claimId)
		end)
	end
end

function Cluster.queue(name: string): any
	local ok, queue = pcall(function()
		return MemoryStoreService:GetQueue("queue_" .. name, 0)
	end)
	if not ok then
		warn(string.format("[Cluster] no memory store queue '%s': %s", name, tostring(queue)))
		return setmetatable({ name = name, queue = nil }, Queue)
	end
	return setmetatable({ name = name, queue = queue }, Queue)
end

--[[
	A leaderboard that ranks everyone, not just this server.

	A sorted map keyed by score. `GetRangeAsync` is what makes it a
	leaderboard rather than a table — reading the top ten costs one call and
	does not depend on how many servers wrote to it.
]]
local Board = {}
Board.__index = Board

function Board:submit(subject: string, score: number): boolean
	local map = mapFor(self.name)
	if not map then
		return false
	end
	local ok = pcall(function()
		map:SetAsync(subject, score, Cluster.config.memoryTtl, score)
	end)
	if not ok then
		stats.failures += 1
	end
	return ok
end

function Board:top(count: number?): { any }
	local map = mapFor(self.name)
	if not map then
		return {}
	end
	local ok, rows = pcall(function()
		return map:GetRangeAsync(Enum.SortDirection.Descending, count or 10)
	end)
	return (ok and rows) or {}
end

function Cluster.board(name: string): any
	return setmetatable({ name = "board_" .. name }, Board)
end

-- ================================== presence ================================
--[[
	How many servers are live, and how full they are.

	Each server writes its own row on a heartbeat and lets it expire; there is
	no deregistration, because a crashed server cannot deregister and a list
	that only shrinks when asked politely is a list of ghosts.
]]
function Cluster.announce(extra: any?)
	if not serverOnly("announce") then
		return
	end
	local map = mapFor("cluster_presence")
	if not map then
		return
	end
	pcall(function()
		map:SetAsync(Cluster.serverId, {
			players = #Players:GetPlayers(),
			placeId = game.PlaceId,
			at = os.time(),
			extra = extra,
		}, 90)
	end)
end

function Cluster.servers(limit: number?): { any }
	local map = mapFor("cluster_presence")
	if not map then
		return {}
	end
	local ok, rows = pcall(function()
		return map:GetRangeAsync(Enum.SortDirection.Ascending, limit or 50)
	end)
	return (ok and rows) or {}
end

function Cluster.start(announceEvery: number?)
	if not serverOnly("start") then
		return
	end
	task.spawn(function()
		while true do
			Cluster.announce()
			task.wait(announceEvery or 45)
		end
	end)
end

function Cluster.describe(): { [string]: any }
	local topics = {}
	for topic in handlers do
		table.insert(topics, topic)
	end
	table.sort(topics)
	return {
		serverId = Cluster.serverId,
		topics = topics,
		subscriptions = (function()
			local n = 0
			for _ in subscriptions do
				n += 1
			end
			return n
		end)(),
		queued = #outbox,
		tokens = math.floor(tokens * 10) / 10,
		stats = table.clone(stats),
	}
end

return Cluster
