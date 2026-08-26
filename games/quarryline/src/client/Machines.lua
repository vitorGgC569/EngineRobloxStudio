--!strict
--[[
	Machines — the half of the machinery that moves, run on the client.

	Why here and not on the server
	------------------------------

	A drill bit turning at four radians a second is, from the server, a CFrame
	written sixty times a second and replicated to everyone on the map, per
	drill. Forty machines on a busy plot row is a replication bill for a detail
	that is decoration.

	Run locally it costs one Heartbeat loop, replicates nothing at all, and
	looks *better*: it never waits on a packet, so it does not stutter when the
	network does.

	The contract is part names. `Machinery` on the server builds the geometry
	and names one or two children per role; this reads those names. Neither side
	imports the other, and adding a machine means naming its parts.

	What is animated and what is not
	--------------------------------

	Motion that means something: the bit spins and the belt scrolls only while
	the line is producing, and the smelter window is bright only when ore is
	moving through it. A machine that animates whether or not it works teaches
	the player the animation is decoration, and then they stop reading it —
	which throws away the one channel that could have told them their line is
	stalled without opening a panel.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Audio = Forge.Audio
local Net = Forge.Net
local Feel = Forge.Feel
local Mark = Forge.Mark

local Machines = {}

--: Set by `Machinery` on the server. Absent means "not one of ours".
local ROLE_ATTRIBUTE = "machineRole"
--: Set by the server each tick: is this machine's line actually producing?
local ACTIVE_ATTRIBUTE = "active"

--: Everything currently being animated, keyed by model.
local tracked: { [Model]: any } = {}

-- ================================ discovery =================================
--[[
	One named descendant, found once and remembered.

	Returns nil until the instance has replicated, and the caller simply does
	nothing that frame -- which is the correct behaviour for a machine that is
	still arriving.
]]
local function want(entry: any, name: string): Instance?
	local cached = entry.cache[name]
	if cached and cached.Parent then
		return cached
	end
	local found = entry.model:FindFirstChild(name, true)
	if found then
		entry.cache[name] = found
	end
	return found
end


local function adopt(model: Instance)
	if not model:IsA("Model") or tracked[model] then
		return
	end
	local role = model:GetAttribute(ROLE_ATTRIBUTE)
	if typeof(role) ~= "string" then
		return
	end

	--[[
		Parts are resolved lazily, not captured here.

		A replicated Model arrives before its children do. `adopt` runs the
		moment the tag appears, which is often a frame or two before `Bit`,
		`Surface` and `Window` exist on this client -- so capturing them now
		stores `nil` for each, permanently, and the machine is adopted and
		animates nothing for the rest of the session.

		That failure is completely silent: `tracked` is populated, the
		Heartbeat loop runs, `Machines.sold` still works because it only needs
		the model, and the payout numbers float correctly over machinery that
		never moves. It cost a pixel-diff of three screenshots to notice.

		`want` caches on first success, so the lookup happens once per part and
		then never again.
	]]
	local entry = {
		role = role,
		model = model,
		--: Randomised so twenty drills on a row are not one drill twenty times.
		--: The single most obvious tell of generated content is a rank of
		--: identical things moving in perfect lockstep.
		phase = math.random() * math.pi * 2,
		spin = 0,
		scroll = 0,
		pulse = 0,
		cache = {},
	}

	local machineId = model:GetAttribute("machineId")
	entry.machineId = typeof(machineId) == "string" and machineId or nil

	tracked[model] = entry
end

local function forget(model: Instance)
	local entry = tracked[model :: Model]
	if not entry then
		return
	end
	if entry.sound then
		entry.sound:Stop()
	end
	tracked[model :: Model] = nil
end

-- ================================ animation =================================
local function step(entry: any, model: Model, dt: number, now: number)
	--[[
		`active` absent is treated as active.

		A machine placed a moment ago has not been through a server tick yet,
		and a machine that sits dead for two seconds after you buy it reads as
		a broken purchase. Erring toward moving is the kinder default and the
		error corrects itself on the next tick.
	]]
	local active = model:GetAttribute(ACTIVE_ATTRIBUTE)
	local working = active ~= false

	if entry.role == "source" then
		local bit = want(entry, "Bit")
		if not bit then
			return
		end
		entry.spin += dt * (working and 7.5 or 0.6)
		-- Rebuilt from the stored pivot rather than accumulated onto the last
		-- CFrame: repeated multiplication drifts, and a drill that slowly
		-- leans over after ten minutes is a bug nobody would ever look for.
		local base = entry.bitPivot
		if not base then
			base = bit.CFrame * CFrame.Angles(0, 0, -math.rad(90))
			entry.bitPivot = base
		end
		local bob = working and math.sin(now * 6 + entry.phase) * 0.12 or 0
		bit.CFrame = (base * CFrame.new(0, bob, 0))
			* CFrame.Angles(0, entry.spin, 0) * CFrame.Angles(0, 0, math.rad(90))
		local tip = want(entry, "Tip")
		local dust = tip and tip:FindFirstChildOfClass("ParticleEmitter")
		if dust then
			dust.Enabled = working
		end
	end

	if entry.role == "carry" then
		local surface = want(entry, "Surface")
		local tread = surface and surface:FindFirstChildOfClass("Texture")
		if tread then
			entry.scroll = (entry.scroll + dt * (working and 3.2 or 0)) % 1
			tread.OffsetStudsV = entry.scroll * 2
		end
		for _, name in { "RollerA", "RollerB" } do
			local roller = want(entry, name)
			if roller and roller:IsA("BasePart") then
				roller.CFrame = roller.CFrame * CFrame.Angles(dt * (working and 9 or 0), 0, 0)
			end
		end
	end

	if entry.role == "refine" then
		local window = want(entry, "Window")
		if not window then
			return
		end
		--: Breathing, not blinking. A furnace glows unevenly; a light that
		--: switches reads as a status LED, which is a different object.
		local heat = working and (0.55 + math.sin(now * 2.4 + entry.phase) * 0.45) or 0.05
		window.Color = Color3.fromRGB(255, 150, 60):Lerp(
			Color3.fromRGB(90, 40, 20), 1 - heat)
		window.Transparency = 0.15 - heat * 0.15
		local chimney = want(entry, "Chimney")
		local smoke = chimney and chimney:FindFirstChildOfClass("ParticleEmitter")
		if smoke then
			smoke.Enabled = working
		end
	end

	if entry.role == "sell" then
		local beacon = want(entry, "Beacon")
		if not beacon or not beacon:IsA("BasePart") then
			return
		end
		entry.pulse = math.max(0, entry.pulse - dt * 2.2)
		local idle = working and (0.5 + math.sin(now * 1.6 + entry.phase) * 0.5) or 0.1
		local lift = math.max(idle, entry.pulse)
		beacon.Transparency = 0.55 - lift * 0.5
		beacon.Size = Vector3.one * (0.8 + lift * 0.5)
	end
end

-- ================================== sales ===================================
--[[
	A sale is the moment the game pays you, and it had no moment.

	The number was updated in a corner of the screen and nothing happened where
	the player was looking. This puts the payout at the depot that earned it:
	the beacon flares, a coin lands, and the figure floats off the crate.
]]
function Machines.sold(plotId: string, amount: number)
	for model, entry in tracked do
		if entry.role ~= "sell" then
			continue
		end
		if model:GetAttribute("plotId") ~= plotId then
			continue
		end
		entry.pulse = 1
		local at = model:GetPivot().Position
		Feel.number(at + Vector3.new(0, 3.2, 0), string.format("+%d", amount), {
			color = Color3.fromRGB(240, 214, 120),
			crit = amount >= 500,
		})
		if Audio.defined("cue.sell") then
			Audio.playAt("cue.sell", at)
		end
	end
end

--: Called when the local player places something, so the click has weight.
function Machines.built(position: Vector3)
	if Audio.defined("cue.build") then
		Audio.playAt("cue.build", position)
	end
	Feel.impact(position, { color = Color3.fromRGB(190, 178, 156) })
	Feel.shake(0.18)
end

-- =================================== start ==================================
function Machines.start()
	for _, tagged in CollectionService:GetTagged(Mark.TAGS.root) do
		adopt(tagged)
	end
	CollectionService:GetInstanceAddedSignal(Mark.TAGS.root):Connect(adopt)
	CollectionService:GetInstanceRemovedSignal(Mark.TAGS.root):Connect(forget)

	RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		for model, entry in tracked do
			if not model.Parent then
				forget(model)
				continue
			end
			step(entry, model, dt, now)
		end
	end)

	--: The bed. One looping ambience for the whole quarry, quiet enough to sit
	--: under the machines rather than compete with them.
	if Audio.defined("ambient.quarry") then
		Audio.play("ambient.quarry")
	end

	--[[
		Report what was bound, once the world has had a moment to replicate.

		Deferred rather than immediate: the machines arrive from the server
		after this script runs, so a count taken now is always zero and says
		nothing about whether adoption works.
	]]
	--[[
		Reported repeatedly, not once at join.

		The first version fired a single message six seconds in, which answers
		"did the animator bind anything at startup" and nothing else. The
		question that matters on a populated server is whether it picks up
		machines that appear *later* -- somebody else claiming a plot, somebody
		buying a drill across the map -- and a number frozen at join cannot
		answer it.

		Cheap enough to leave on: one small message every fifteen seconds, per
		client, carrying two integers.
	]]
	task.spawn(function()
		local lastReported = -1
		while true do
			task.wait(15)
			local n = 0
			for _ in tracked do
				n += 1
			end
			local tags = #CollectionService:GetTagged(Mark.TAGS.root)
			--: Only when it moves. A server log that repeats an unchanged
			--: number every fifteen seconds is a log nobody reads.
			if n ~= lastReported then
				lastReported = n
				Net.send("ClientReady", { adopted = n, tagged = tags })
			end
		end
	end)
end

return Machines
