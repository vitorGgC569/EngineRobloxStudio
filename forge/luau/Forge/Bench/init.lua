--!strict
--[[
	Bench — measured cost, instead of a number from an empty room.

	Every performance figure this engine had came from a Studio session with one
	player standing still. That is not evidence about a server with thirty
	people and four thousand entities; it is evidence about an empty room.

	What this can and cannot measure
	--------------------------------
	Roblox refuses to conjure a Player: `Players:CreateLocalPlayer` and
	`Instance.new("Player")` both fail on capability, which is measured and
	recorded in the platform notes. So this does not simulate clients.

	It simulates *load*: N moving anchors, N entities, N receivers for a
	proximity broadcast — the server-side costs that actually scale. Replication
	bandwidth and client frame time still need real players, and this module
	says so rather than implying otherwise.

		Bench.run("entity.query.2000", function() ... end, 200)
		Bench.suite()          -- the standard set
		Bench.report()
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local Bench = {}

local results: { [string]: any } = {}

Bench.notMeasured = {
	"replication bandwidth per client",
	"client frame time",
	"input latency under real network conditions",
	"DataStore throughput at production request rates",
}

--[[
	Run `fn` `iterations` times and report the distribution.

	Reports the median and the 95th percentile, not the mean. A mean hides the
	frame that took 40ms, and the frame that took 40ms is the one the player
	felt.
]]
function Bench.run(name: string, fn: () -> (), iterations: number?): any
	local count = iterations or 100
	local samples = table.create(count)

	-- one untimed pass so the first call's compilation is not in the sample
	local ok, err = pcall(fn)
	if not ok then
		results[name] = { error = tostring(err) }
		return results[name]
	end

	for index = 1, count do
		local started = os.clock()
		fn()
		samples[index] = (os.clock() - started) * 1000
	end
	table.sort(samples)

	local total = 0
	for _, sample in samples do
		total += sample
	end

	local result = {
		name = name,
		iterations = count,
		medianMs = samples[math.ceil(count * 0.5)],
		p95Ms = samples[math.ceil(count * 0.95)],
		maxMs = samples[count],
		meanMs = total / count,
	}
	results[name] = result
	return result
end

--[[
	Synthetic anchors, for streaming and proximity work.

	They move on separate circles at different speeds, because the interesting
	case is not "thirty players in one place" — it is thirty players spread out,
	each pulling a different chunk set, which is when a streamer thrashes.
]]
function Bench.anchors(count: number, radius: number?): () -> { Vector3 }
	local spread = radius or 240
	return function()
		local now = os.clock()
		local out = table.create(count)
		for index = 1, count do
			local phase = now * (0.2 + index * 0.03) + index
			local distance = spread * (0.3 + (index % 5) * 0.16)
			out[index] = Vector3.new(math.cos(phase) * distance, 30, math.sin(phase) * distance)
		end
		return out
	end
end

-- ============================== standard suite ==============================
--[[
	The questions the engine could not answer before this existed. Each one
	names a real doubt rather than benchmarking something convenient.
]]
function Bench.suite(options: any?): { [string]: any }
	local opts = options or {}
	local Entity = require(script.Parent.Entity)
	local Net = require(script.Parent.Net)

	local entityCount = opts.entities or 2000
	local anchorCount = opts.anchors or 30

	-- 1. Entity queries at scale --------------------------------------------
	Entity.define("BenchA", { value = 0 })
	Entity.define("BenchB", { value = 0 })

	local created = {}
	for index = 1, entityCount do
		local id = Entity.create({ name = "bench" })
		Entity.add(id, "BenchA", { value = index })
		if index % 3 == 0 then
			Entity.add(id, "BenchB", { value = index })
		end
		table.insert(created, id)
	end

	Bench.run(string.format("entity.query.single.%d", entityCount), function()
		local sum = 0
		for _, a in Entity.query("BenchA") do
			sum += a.value
		end
	end, 40)

	Bench.run(string.format("entity.query.pair.%d", entityCount), function()
		local sum = 0
		for _, a, b in Entity.query("BenchA", "BenchB") do
			sum += a.value + b.value
		end
	end, 40)

	-- 2. Proximity broadcast -------------------------------------------------
	-- `fireNear` walks every player and measures a distance. With no real
	-- clients the send itself costs nothing, so this measures the filter, which
	-- is the part that scales with player count.
	if Net.defined("BenchPing") then
		Bench.run("net.fireNear.filter", function()
			Net.fireNear(Vector3.zero, 160, "BenchPing", { t = 1 })
		end, 200)
	end

	-- 3. Streaming with spread-out anchors -----------------------------------
	local Streaming = require(script.Parent.Streaming)
	local streamers = Streaming.describe()
	local sceneName = nil
	for name in streamers do
		sceneName = name
		break
	end
	if sceneName then
		local streamer = Streaming.get(sceneName)
		local realAnchors = streamer.anchors
		streamer.anchors = Bench.anchors(anchorCount)

		Bench.run(string.format("streaming.tick.%dAnchors", anchorCount), function()
			streamer:_tick(1 / 4)
		end, 60)

		streamer.anchors = realAnchors
		results[string.format("streaming.tick.%dAnchors", anchorCount)].chunks = streamer:chunkCount()
		results[string.format("streaming.tick.%dAnchors", anchorCount)].live = streamer.stats.live
	end

	-- clean up so the world is not left holding two thousand bench entities
	for _, id in created do
		Entity.destroy(id)
	end

	return Bench.report()
end

function Bench.report(): { [string]: any }
	local out: { [string]: any } = {
		results = results,
		context = RunService:IsServer() and "server" or "client",
		players = #Players:GetPlayers(),
		heartbeatMs = Stats.HeartbeatTimeMs,
		memoryMb = math.floor(Stats:GetTotalMemoryUsageMb()),
		notMeasured = Bench.notMeasured,
	}
	return out
end

function Bench.clear()
	table.clear(results)
end

function Bench.describe(): { [string]: any }
	local names = {}
	for name in results do
		table.insert(names, name)
	end
	table.sort(names)
	return { ran = names, notMeasured = Bench.notMeasured }
end

return Bench
