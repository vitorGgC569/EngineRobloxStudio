--!strict
--[[
	Netcode — prediction, reconciliation, lag compensation and interpolation.

	`Net` is the transport: typed, validated, rate limited. It says nothing about
	*time*, and time is the whole problem in an action game.

	Without this layer the loop is:

		input -> server -> authoritative state -> client sees it

	which means every action costs a round trip. At 50ms nobody notices. At
	150ms the swing lags the click. At 200ms it reads as rubber.

	With it:

		input -> predicted locally -> server authorises -> reconcile or roll back
		                           -> remote entities interpolated behind time

	Four pieces, and each solves a different symptom:

	  prediction      your own actions feel instant
	  reconciliation  a rejected action is undone, not left desynced
	  rewind          a hit that looked good on your screen counts
	  interpolation   other people and enemies move smoothly, not in steps

	What this is not
	----------------
	It is not rollback netcode for a fighting game and does not pretend to be.
	Roblox owns the physics step and does not expose a deterministic rewind of
	the whole simulation. What it does is make *gameplay actions* feel local and
	*hit detection* fair, which is the part players feel.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Net = require(script.Parent.Net)
local Signal = require(script.Parent.Core.Signal)
local Sched = require(script.Parent.Core.Sched)

local Netcode = {}

local IS_SERVER = RunService:IsServer()

Netcode.rejected = Signal.new() -- (name, sequence, reason)
Netcode.confirmed = Signal.new() -- (name, sequence)

Netcode.config = {
	-- How far back the server will rewind for a client. Capped hard: a client
	-- claiming 2s of lag would otherwise get to shoot two seconds into the past.
	maxRewindSeconds = 0.4,
	historySeconds = 0.6,
	historyRate = 20,

	-- Render behind the newest snapshot by this much. Interpolation needs a
	-- buffer to interpolate *within*; without it every hitch becomes a jump.
	interpolationDelay = 0.1,

	pingInterval = 2,
	predictionTimeout = 2,

	-- Artificial latency, for the only test that matters: does this still feel
	-- right at 200ms? Studio has none, so without injecting it every measurement
	-- is taken under conditions no player will ever have.
	simulatedLatency = 0,
	simulatedLoss = 0, -- 0..1, fraction of commands dropped outright
	-- Off by default. A shipped game must not let a client ask the server
	-- to make everyone laggy.
	allowSimulationRequests = false,
}

--[[
	Timing samples.

	Four numbers answer whether the netcode works:

	  predictMs    input to something visible. Should not move with latency.
	  ackMs        input to the server's answer. Moves with latency, by design.
	  corrections  predictions the server refused. Should stay near zero.
	  rewindMs     how far back hits were judged. Should track latency and cap.
]]
local samples = {
	predict = {} :: { number },
	ack = {} :: { number },
	rewind = {} :: { number },
}
local counters = { sent = 0, confirmed = 0, corrected = 0, timedOut = 0, dropped = 0 }

local function record(bucket: { number }, value: number)
	table.insert(bucket, value)
	if #bucket > 400 then
		table.remove(bucket, 1)
	end
end

local function percentile(bucket: { number }, fraction: number): number
	if #bucket == 0 then
		return 0
	end
	local sorted = table.clone(bucket)
	table.sort(sorted)
	return sorted[math.max(1, math.ceil(#sorted * fraction))]
end

-- ================================== ping ====================================
local rtt: { [Player]: number } = {}
local clientStats: { [Player]: any } = {}
local localRtt = 0
local pingSent: { [number]: number } = {}
local pingSequence = 0

function Netcode.rtt(player: Player?): number
	if IS_SERVER then
		return player and rtt[player] or 0
	end
	return localRtt
end

-- One-way latency estimate. Half the round trip, which is the standard
-- approximation and wrong only when the route is asymmetric.
function Netcode.latency(player: Player?): number
	--[[
	Test controls. Deliberately public: the whole point is being able to set
	200ms from outside and watch what happens, without a build.
]]
function Netcode.simulate(latencyMs: number?, lossFraction: number?)
	Netcode.config.simulatedLatency = math.max(0, (latencyMs or 0) / 1000)
	Netcode.config.simulatedLoss = math.clamp(lossFraction or 0, 0, 1)
end

-- Broadcast a simulation setting to every client. Server-side entry point for
-- a latency sweep driven from outside the game.
function Netcode.broadcastSimulation(latencyMs: number?, loss: number?, reset: boolean?)
	if not IS_SERVER then
		return
	end
	Net.fireAll("NetcodeSim", { latencyMs = latencyMs or 0, loss = loss or 0, reset = reset ~= false })
end

function Netcode.resetStats()
	table.clear(samples.predict)
	table.clear(samples.ack)
	table.clear(samples.rewind)
	for key in counters do
		counters[key] = 0
	end
end

return Netcode.rtt(player) / 2
end

-- ============================ position history ==============================
--[[
	Every tracked model's recent positions, so a hit can be judged against where
	things *were* on the shooter's screen rather than where they are now.

	Without this, a player with 150ms of latency must lead every target by a
	body width, which reads as the game being unresponsive rather than as
	physics.
]]
local history: { [Model]: { { t: number, cf: CFrame } } } = {}
local historyGroup = nil

function Netcode.track(model: Model)
	if not IS_SERVER or history[model] then
		return
	end
	history[model] = {}
	Netcode.startHistory()
end

function Netcode.untrack(model: Model)
	history[model] = nil
end

function Netcode.startHistory()
	if historyGroup or not IS_SERVER then
		return
	end
	historyGroup = Sched.group(Netcode.config.historyRate)
	historyGroup:add("netcode-history", function()
		local now = os.clock()
		local cutoff = now - Netcode.config.historySeconds

		for model, samples in history do
			if not model.Parent then
				history[model] = nil
				continue
			end
			table.insert(samples, { t = now, cf = model:GetPivot() })
			while #samples > 0 and samples[1].t < cutoff do
				table.remove(samples, 1)
			end
		end
	end)
end

-- Where a model was at `when`, interpolated between the two nearest samples.
function Netcode.positionAt(model: Model, when: number): CFrame?
	local samples = history[model]
	if not samples or #samples == 0 then
		return nil
	end
	if when >= samples[#samples].t then
		return samples[#samples].cf
	end
	if when <= samples[1].t then
		return samples[1].cf
	end
	for index = 1, #samples - 1 do
		local a, b = samples[index], samples[index + 1]
		if when >= a.t and when <= b.t then
			local span = b.t - a.t
			local alpha = span > 0 and (when - a.t) / span or 0
			return a.cf:Lerp(b.cf, alpha)
		end
	end
	return samples[#samples].cf
end

--[[
	Run `fn` with every tracked model moved to where it was on `player`'s
	screen, then put everything back.

		Netcode.rewind(player, function()
			local hits = Combat.arc(origin, direction, { range = 9 })
		end)

	The restore happens in a `pcall`-protected path: a handler that errors must
	not leave the world rewound, because the next frame would then simulate
	physics from a stale position.
]]
function Netcode.rewind(player: Player, fn: () -> (), overrideSeconds: number?)
	if not IS_SERVER then
		fn()
		return
	end

	local back = math.clamp(
		overrideSeconds or Netcode.latency(player),
		0,
		Netcode.config.maxRewindSeconds
	)
	if back <= 0 then
		fn()
		return
	end

	record(samples.rewind, back * 1000)
	local when = os.clock() - back
	local restored: { { model: Model, cf: CFrame } } = {}

	for model in history do
		if not model.Parent then
			continue
		end
		local past = Netcode.positionAt(model, when)
		if past then
			table.insert(restored, { model = model, cf = model:GetPivot() })
			model:PivotTo(past)
		end
	end

	local ok, err = pcall(fn)

	for _, entry in restored do
		if entry.model.Parent then
			entry.model:PivotTo(entry.cf)
		end
	end

	if not ok then
		error(err, 0)
	end
end

-- ========================== predicted commands ==============================
--[[
	A command the client runs immediately and the server may refuse.

		Netcode.define("attack", {
			predict = function(data) playSwing(data.dir) end,
			authorize = function(player, data) return cooldownOk(player) end,
			apply = function(player, data) dealDamage(player, data.dir) end,
			rollback = function(data) cancelSwing() end,
		})

		Netcode.perform("attack", { dir = look })   -- client

	`predict` runs on the client with no round trip. `authorize` and `apply` run
	on the server. If `authorize` refuses, the client's `rollback` runs.

	The sequence number is what makes reconciliation possible: without it a late
	rejection cannot be matched to the prediction that caused it, and the client
	would roll back the wrong action.
]]
type Command = {
	predict: ((data: any) -> any)?,
	authorize: ((player: Player, data: any) -> (boolean, string?))?,
	apply: ((player: Player, data: any) -> ())?,
	rollback: ((data: any, reason: string) -> ())?,
	rewind: boolean?, -- run `apply` inside a lag-compensated rewind
	shape: { [string]: string }?,
	rate: number?,
}

local commands: { [string]: Command } = {}
local pending: { [number]: { name: string, data: any, at: number, predicted: any } } = {}
local sequence = 0
local wired = false

function Netcode.define(name: string, command: Command)
	commands[name] = command
	Netcode.wire()
end

function Netcode.defineMany(table_: { [string]: Command })
	for name, command in table_ do
		Netcode.define(name, command)
	end
end

function Netcode.wire()
	if wired then
		return
	end
	wired = true

	--[[
		The ping is server-initiated on purpose.

		A client-measured RTT has to be reported to the server to be useful, and
		a reported number is a number a client can inflate — which buys extra
		rewind, which means shooting further into the past. Measuring from the
		server costs the same one round trip and cannot be forged.
	]]
	Net.define({
		NetcodeCmd = { dir = "c2s", rate = 40, shape = { name = "string", seq = "number", data = "table" } },
		NetcodeAck = { dir = "s2c" },
		NetcodePing = { dir = "s2c" },
		NetcodePong = { dir = "c2s", rate = 4, shape = { seq = "number" } },
		-- Test channel: the server tells clients to pretend they are far away.
		-- Studio has no latency, so without this every measurement is taken
		-- under conditions no player will ever have.
		NetcodeSim = { dir = "s2c" },
		-- Prediction timing lives on the client; the server cannot see it.
		-- Reporting it up is what makes the numbers readable from outside.
		NetcodeStats = { dir = "c2s", rate = 2, shape = { timing = "table", counters = "table" } },
		-- A c2s trigger for the sweep. `instance.update` cannot write in a
		-- play session's server context, so the Debug string channel is not
		-- reachable there; firing a remote is.
		NetcodeSimRequest = { dir = "c2s", rate = 4, shape = { latencyMs = "number", loss = "number" } },
	})

	if IS_SERVER then
		Net.on("NetcodeCmd", function(player, payload)
			local command = commands[payload.name]
			if not command then
				Net.fire(player, "NetcodeAck", { seq = payload.seq, ok = false, reason = "unknown" })
				return
			end

			local allowed, reason = true, nil
			if command.authorize then
				allowed, reason = command.authorize(player, payload.data)
			end
			if not allowed then
				Net.fire(player, "NetcodeAck", { seq = payload.seq, ok = false, reason = reason or "refused" })
				return
			end

			if command.apply then
				if command.rewind then
					Netcode.rewind(player, function()
						(command.apply :: any)(player, payload.data)
					end)
				else
					command.apply(player, payload.data)
				end
			end
			Net.fire(player, "NetcodeAck", { seq = payload.seq, ok = true })
		end)

		-- server measures: send, wait for the echo, halve
		local outstanding: { [Player]: { [number]: number } } = {}

		Net.on("NetcodePong", function(player, payload)
			local perPlayer = outstanding[player]
			local sentAt = perPlayer and perPlayer[payload.seq]
			if not sentAt then
				return
			end
			perPlayer[payload.seq] = nil
			local sample = os.clock() - sentAt
			local previous = rtt[player] or sample
			-- Smoothed: one bad sample must not swing the rewind window.
			rtt[player] = previous * 0.7 + sample * 0.3
		end)

		Net.on("NetcodeSimRequest", function(_player, payload)
			if not Netcode.config.allowSimulationRequests then
				return -- test-only channel; off unless a game opts in
			end
			Netcode.broadcastSimulation(payload.latencyMs, payload.loss, true)
		end)

		Net.on("NetcodeStats", function(player, payload)
			clientStats[player] = { timing = payload.timing, counters = payload.counters, at = os.clock() }
		end)

		Players.PlayerRemoving:Connect(function(player)
			outstanding[player] = nil
			clientStats[player] = nil
		end)

		task.spawn(function()
			local seq = 0
			while true do
				task.wait(Netcode.config.pingInterval)
				seq += 1
				local now = os.clock()
				for _, player in Players:GetPlayers() do
					local perPlayer = outstanding[player]
					if not perPlayer then
						perPlayer = {}
						outstanding[player] = perPlayer
					end
					-- drop anything old enough to be a lost packet
					for oldSeq, at in perPlayer do
						if now - at > 10 then
							perPlayer[oldSeq] = nil
						end
					end
					perPlayer[seq] = now
					Net.fire(player, "NetcodePing", { seq = seq })
				end
			end
		end)
	else
		Net.on("NetcodeAck", function(payload)
			-- The answer takes the same simulated trip home.
			if Netcode.config.simulatedLatency > 0 then
				local copy = payload
				task.delay(Netcode.config.simulatedLatency, function()
					Netcode.handleAck(copy)
				end)
				return
			end
			Netcode.handleAck(payload)
		end)

		function Netcode.handleAck(payload: any)
			local entry = pending[payload.seq]
			if not entry then
				return
			end
			pending[payload.seq] = nil
			record(samples.ack, (os.clock() - entry.at) * 1000)

			if payload.ok then
				counters.confirmed += 1
				Netcode.confirmed:Fire(entry.name, payload.seq)
				return
			end
			counters.corrected += 1

			local command = commands[entry.name]
			if command and command.rollback then
				local ok, err = pcall(command.rollback, entry.data, payload.reason or "refused")
				if not ok then
					warn(string.format("[Netcode] rollback for '%s' errored: %s", entry.name, tostring(err)))
				end
			end
			Netcode.rejected:Fire(entry.name, payload.seq, payload.reason or "refused")
		end

		Net.on("NetcodeSim", function(payload)
			Netcode.simulate(payload.latencyMs, payload.loss)
			if payload.reset then
				Netcode.resetStats()
			end
		end)

		-- Echo the server's ping, and keep a local estimate for UI purposes.
		-- The server does not trust this value; it has its own.
		Net.on("NetcodePing", function(payload)
			local previous = pingSent[payload.seq]
			if previous then
				localRtt = localRtt > 0 and (localRtt * 0.7 + (os.clock() - previous) * 0.3) or (os.clock() - previous)
			end
			pingSent[payload.seq] = os.clock()

			--[[
				The echo takes the simulated trip too.

				Without this the sweep measured nothing: commands and acks were
				delayed but the ping was not, so the server kept measuring the
				real 45ms and the rewind window never moved off 22ms at any
				setting. The simulation looked wired and simulated nothing.
			]]
			local delay = Netcode.config.simulatedLatency
			if delay > 0 then
				task.delay(delay, function()
					Net.send("NetcodePong", { seq = payload.seq })
				end)
			else
				Net.send("NetcodePong", { seq = payload.seq })
			end
		end)

		task.spawn(function()
			while true do
				task.wait(1)
				local report = Netcode.describe()
				-- carry the client's effective simulation setting, so a sweep can
				-- tell "the broadcast never arrived" from "the delay does nothing"
				local counters = table.clone(report.counters)
				counters.simulatedLatencyMs = report.simulatedLatencyMs
				Net.send("NetcodeStats", { timing = report.timing, counters = counters })
			end
		end)

		-- A prediction the server never answered is a lost packet or a dropped
		-- handler. Rolling back on timeout is better than leaving the client
		-- showing something that never happened.
		task.spawn(function()
			while true do
				task.wait(0.5)
				local now = os.clock()
				for seq, entry in pending do
					if now - entry.at > Netcode.config.predictionTimeout then
						pending[seq] = nil
						local command = commands[entry.name]
						if command and command.rollback then
							pcall(command.rollback, entry.data, "timeout")
						end
						counters.timedOut += 1
						Netcode.rejected:Fire(entry.name, seq, "timeout")
					end
				end
			end
		end)
	end
end

function Netcode.perform(name: string, data: any?): number?
	if IS_SERVER then
		error("[Netcode] perform is client-side; the server applies", 2)
	end
	local command = commands[name]
	if not command then
		warn(string.format("[Netcode] '%s' was never defined", name))
		return nil
	end

	sequence += 1
	local payload = data or {}
	local started = os.clock()

	local predicted = nil
	if command.predict then
		local ok, result = pcall(command.predict, payload)
		if ok then
			predicted = result
		else
			warn(string.format("[Netcode] predict for '%s' errored: %s", name, tostring(result)))
		end
	end

	local predictedAt = os.clock()
	record(samples.predict, (predictedAt - started) * 1000)

	pending[sequence] = { name = name, data = payload, at = predictedAt, predicted = predicted }
	counters.sent += 1

	-- Loss is simulated before the send, not after: a dropped command must look
	-- to the client exactly like one the server never received, which is a
	-- prediction that times out rather than one that is refused.
	if Netcode.config.simulatedLoss > 0 and math.random() < Netcode.config.simulatedLoss then
		counters.dropped += 1
		return sequence
	end

	local delay = Netcode.config.simulatedLatency
	if delay > 0 then
		task.delay(delay, function()
			Net.send("NetcodeCmd", { name = name, seq = sequence, data = payload })
		end)
	else
		Net.send("NetcodeCmd", { name = name, seq = sequence, data = payload })
	end
	return sequence
end

function Netcode.pendingCount(): number
	local n = 0
	for _ in pending do
		n += 1
	end
	return n
end

-- ============================== interpolation ===============================
--[[
	Smooth a model the server drives.

	Roblox replicates a server-owned model's CFrame at its own cadence. At a low
	tick rate that arrives as steps, and the eye reads steps as lag even when
	latency is fine. Buffering the last few states and rendering slightly behind
	turns them back into motion.

	The cost is `interpolationDelay` of extra visual latency on *other* things —
	never on your own character, which you own and predict.
]]
local interpolated: { [Model]: any } = {}
local interpolationConn: RBXScriptConnection? = nil

function Netcode.interpolate(model: Model, options: any?)
	if IS_SERVER then
		return
	end
	interpolated[model] = {
		buffer = {},
		last = model:GetPivot(),
		delay = (options and options.delay) or Netcode.config.interpolationDelay,
	}
	Netcode.startInterpolation()
end

function Netcode.stopInterpolating(model: Model)
	interpolated[model] = nil
end

function Netcode.startInterpolation()
	if interpolationConn or IS_SERVER then
		return
	end
	interpolationConn = RunService.RenderStepped:Connect(function()
		local now = os.clock()
		for model, state in interpolated do
			if not model.Parent then
				interpolated[model] = nil
				continue
			end

			local current = model:GetPivot()
			if (current.Position - state.last.Position).Magnitude > 0.001 then
				table.insert(state.buffer, { t = now, cf = current })
				state.last = current
			end
			while #state.buffer > 2 and state.buffer[1].t < now - state.delay * 3 do
				table.remove(state.buffer, 1)
			end

			-- A large jump is a teleport, not motion: interpolating it would
			-- slide the model across the map.
			if #state.buffer >= 2 then
				local a, b = state.buffer[#state.buffer - 1], state.buffer[#state.buffer]
				if (b.cf.Position - a.cf.Position).Magnitude > 60 then
					table.clear(state.buffer)
				end
			end
		end
	end)
end

-- ================================= describe =================================
function Netcode.describe(): { [string]: any }
	local names = {}
	for name in commands do
		table.insert(names, name)
	end
	table.sort(names)

	local tracked = 0
	for _ in history do
		tracked += 1
	end
	local smoothing = 0
	for _ in interpolated do
		smoothing += 1
	end

	local pings: { [string]: number } = {}
	if IS_SERVER then
		for player, value in rtt do
			pings[player.Name] = math.floor(value * 1000)
		end
	end

	return {
		context = IS_SERVER and "server" or "client",
		commands = names,
		simulatedLatencyMs = math.floor(Netcode.config.simulatedLatency * 1000),
		simulatedLoss = Netcode.config.simulatedLoss,
		counters = table.clone(counters),
		timing = {
			predictP50 = percentile(samples.predict, 0.5),
			predictP95 = percentile(samples.predict, 0.95),
			ackP50 = percentile(samples.ack, 0.5),
			ackP95 = percentile(samples.ack, 0.95),
			rewindP50 = percentile(samples.rewind, 0.5),
			rewindMax = percentile(samples.rewind, 1),
			samples = #samples.ack,
		},
		trackedForRewind = tracked,
		interpolating = smoothing,
		pendingPredictions = Netcode.pendingCount(),
		rttMs = math.floor(localRtt * 1000),
		playerPingMs = pings,
		maxRewindMs = math.floor(Netcode.config.maxRewindSeconds * 1000),
		clients = (function()
			if not IS_SERVER then
				return nil
			end
			local out: { [string]: any } = {}
			for player, entry in clientStats do
				out[player.Name] = { timing = entry.timing, counters = entry.counters }
			end
			return out
		end)(),
	}
end

if IS_SERVER then
	Players.PlayerRemoving:Connect(function(player)
		rtt[player] = nil
	end)
end

return Netcode
