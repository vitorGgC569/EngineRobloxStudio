--!strict
--[[
	Net — a typed, validated, rate-limited bus between client and server.

	Roblox gives you RemoteEvent, which is a hole in your server. Every exploit
	that matters in a Roblox game goes through one: the client sends
	`{ price = 0 }` and the server believes it. The defence is not vigilance,
	it is making the unsafe path harder to write than the safe one.

	So: an event that is not declared does not exist, every client->server
	packet is shape-checked before your handler sees it, and every one is rate
	limited whether you remembered to think about it or not.

		Net.define({
			Attack    = { dir = "c2s", rate = 6, shape = { dir = "Vector3" } },
			BuyItem   = { dir = "c2s", rate = 4, shape = { shop = "string", item = "string" } },
			StateSync = { dir = "s2c" },
			GetShop   = { dir = "c2s", kind = "function", shape = { shop = "string" } },
		})

	Server:
		Net.on("Attack", function(player, payload) ... end)
		Net.fire(player, "StateSync", state)
		Net.fireNear(position, 120, "Effect", fx)

	Client:
		Net.send("Attack", { dir = look })
		Net.on("StateSync", function(state) ... end)
		local stock = Net.request("GetShop", { shop = "smith" })

	Nothing here decides what your events mean. It only decides that they are
	declared, shaped and throttled.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Signal = require(script.Parent.Core.Signal)
local Sched = require(script.Parent.Core.Sched)

local Net = {}

local IS_SERVER = RunService:IsServer()
local FOLDER_NAME = "ForgeNet"

export type Definition = {
	dir: string, -- "c2s" | "s2c"
	kind: string?, -- "event" (default) | "function"
	rate: number?, -- c2s: allowed calls per second
	burst: number?, -- c2s: burst allowance
	shape: { [string]: string }?, -- c2s: declarative payload shape
	check: ((any) -> boolean)?, -- c2s: custom validator, runs after shape
	unreliable: boolean?, -- s2c: use an UnreliableRemoteEvent
}

local definitions: { [string]: Definition } = {}
local buckets: { [string]: (any?) -> boolean } = {}
local remotes: { [string]: Instance } = {}

-- Fired whenever a packet is rejected. The validation half listens to this to
-- prove that the server actually refuses malformed input.
-- (player: Player, event: string, reason: string)
Net.violated = Signal.new()

local folder: Instance

local function ensureFolder(): Instance
	if folder then
		return folder
	end
	if IS_SERVER then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if existing then
			folder = existing
		else
			local f = Instance.new("Folder")
			f.Name = FOLDER_NAME
			f.Parent = ReplicatedStorage
			folder = f
		end
	else
		folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, 30)
	end
	return folder
end

-- ============================ shape checking ================================
-- "Vector3", "number", "string", "boolean", "table", "Instance", "any"
-- A trailing "?" makes the field optional: { note = "string?" }

local function matches(value: any, spec: string): boolean
	local optional = string.sub(spec, -1) == "?"
	local expected = optional and string.sub(spec, 1, -2) or spec

	if value == nil then
		return optional
	end
	if expected == "any" then
		return true
	end
	if expected == "number" then
		-- reject NaN and absurd magnitudes: both are exploit primitives
		return type(value) == "number" and value == value and math.abs(value) < 1e9
	end
	if expected == "string" then
		return type(value) == "string" and #value <= 256
	end
	if expected == "boolean" or expected == "table" then
		return type(value) == expected
	end
	if expected == "Vector3" then
		return typeof(value) == "Vector3" and value.X == value.X and value.Magnitude < 1e5
	end
	return typeof(value) == expected
end

function Net.shape(spec: { [string]: string }): (any) -> boolean
	return function(payload: any): boolean
		if type(payload) ~= "table" then
			return false
		end
		for field, fieldSpec in spec do
			if not matches(payload[field], fieldSpec) then
				return false
			end
		end
		-- an undeclared field is either a typo or an injection attempt
		for field in payload do
			if spec[field] == nil then
				return false
			end
		end
		return true
	end
end

-- ============================== definition ==================================
function Net.define(defs: { [string]: Definition })
	for name, def in defs do
		assert(def.dir == "c2s" or def.dir == "s2c", string.format("[Net] '%s': dir must be 'c2s' or 's2c'", name))
		def = table.clone(def)
		if def.shape then
			def.shape = table.clone(def.shape)
		end
		definitions[name] = def

		if def.dir == "c2s" then
			buckets[name] = Sched.bucket(def.rate or 8, def.burst)
		end

		if IS_SERVER then
			local parent = ensureFolder()
			if not parent:FindFirstChild(name) then
				local className = if def.kind == "function"
					then "RemoteFunction"
					elseif def.unreliable then "UnreliableRemoteEvent"
					else "RemoteEvent"
				local remote = Instance.new(className)
				remote.Name = name
				remote.Parent = parent
			end
		end
	end
end

--: Names that have a handler attached. See `Net.handles`.
local listening: { [string]: boolean } = {}

function Net.defined(name: string): boolean
	return definitions[name] ~= nil
end

--[[
	Whether anything is actually listening.

	`defined` says the remote instance exists; this says somebody called
	`Net.on` for it. The gap between those two is the hardest failure in a
	Roblox codebase to see: firing into a defined remote with no handler raises
	nothing anywhere, and the client simply hangs until it times out -- which
	looks exactly like a broken button.

	A game can now assert it in a live scenario instead of discovering it by
	pressing every control.
]]
function Net.handles(name: string): boolean
	return listening[name] == true
end

function Net.listening(): { string }
	local out = {}
	for name in listening do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

function Net.manifest(): { [string]: any }
	local out: { [string]: any } = {}
	for name, def in definitions do
		out[name] = { dir = def.dir, kind = def.kind or "event", rate = def.rate, shape = def.shape }
	end
	return out
end

local function remoteFor(name: string): any
	local cached = remotes[name]
	if cached then
		return cached
	end
	local def = definitions[name]
	if not def then
		error(string.format("[Net] '%s' was never defined. Add it to Net.define.", tostring(name)), 3)
	end
	--[[
		Wait, but say so if it never arrives.

		Remotes are created by the server; a client asking for one before the
		server has defined it waits here. Returning nil silently made the next
		line index a nil value and blamed the caller — and, worse, a timeout
		looked exactly like a listener that had simply never fired.
	]]
	local instance = ensureFolder():WaitForChild(name, 20)
	if not instance then
		error(string.format(
			"[Net] '%s' never appeared. The server defines remotes; a client "
			.. "listening for one the server has not defined yet waits 20s and "
			.. "then fails. Define shared channels at module load, not inside "
			.. "a system that starts late.", name), 3)
	end
	remotes[name] = instance
	return instance
end

-- =============================== server =====================================
local function assertServer(fn: string)
	if not IS_SERVER then
		error(string.format("[Net] %s is server-only", fn), 3)
	end
end

function Net.fire(player: Player, name: string, payload: any?)
	assertServer("fire")
	remoteFor(name):FireClient(player, payload)
end

function Net.fireAll(name: string, payload: any?)
	assertServer("fireAll")
	remoteFor(name):FireAllClients(payload)
end

function Net.fireExcept(excluded: Player, name: string, payload: any?)
	assertServer("fireExcept")
	local remote = remoteFor(name)
	for _, plr in Players:GetPlayers() do
		if plr ~= excluded then
			remote:FireClient(plr, payload)
		end
	end
end

-- Only players within `radius` of `position` receive it. In an open world this
-- is the difference between 20 KB/s and 400 KB/s per client, and it is the
-- single highest-leverage networking decision in the whole engine.
function Net.fireNear(position: Vector3, radius: number, name: string, payload: any?)
	assertServer("fireNear")
	local remote = remoteFor(name)
	local r2 = radius * radius
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and ((root :: BasePart).Position - position).Magnitude ^ 2 <= r2 then
			remote:FireClient(plr, payload)
		end
	end
end

function Net.fireList(players: { Player }, name: string, payload: any?)
	assertServer("fireList")
	local remote = remoteFor(name)
	for _, plr in players do
		remote:FireClient(plr, payload)
	end
end

-- =============================== client =====================================
function Net.send(name: string, payload: any?)
	if IS_SERVER then
		error("[Net] send is client-only; use fire", 2)
	end
	remoteFor(name):FireServer(payload)
end

function Net.request(name: string, payload: any?): any
	if IS_SERVER then
		error("[Net] request is client-only", 2)
	end
	return remoteFor(name):InvokeServer(payload)
end

-- ============================== listening ===================================
-- One `on` for both sides. On the server the handler receives (player, payload)
-- and only runs if the packet passed the gate; on the client it receives
-- (payload).

function Net.on(name: string, handler: (...any) -> ...any): RBXScriptConnection?
	local def = definitions[name]
	if not def then
		error(string.format("[Net] '%s' was never defined", tostring(name)), 2)
	end
	local remote = remoteFor(name)
	listening[name] = true

	if IS_SERVER then
		if def.dir ~= "c2s" then
			error(string.format("[Net] '%s' is s2c; the server cannot listen to it", name), 2)
		end
		local allow = buckets[name]
		local check = def.check
		local shapeCheck = def.shape and Net.shape(def.shape)

		local function gate(player: Player, payload: any): (boolean, any)
			if not allow(player) then
				Net.violated:Fire(player, name, "rate")
				return false, nil
			end
			if shapeCheck and not shapeCheck(payload) then
				Net.violated:Fire(player, name, "shape")
				warn(string.format("[Net] %s sent a malformed '%s'", player.Name, name))
				return false, nil
			end
			if check then
				local ok, accepted = pcall(check, payload)
				if not ok or accepted ~= true then
					Net.violated:Fire(player, name, if ok then "check" else "validator-error")
					return false, nil
				end
			end
			return true, payload
		end

		if def.kind == "function" then
			local remoteFunction = remote :: RemoteFunction
			remoteFunction.OnServerInvoke = function(player, payload)
				local ok, checked = gate(player, payload)
				if not ok then
					return nil
				end
				local success, result = pcall(handler, player, checked)
				if not success then
					error(string.format("[Net] handler '%s' errored: %s", name, tostring(result)), 0)
					return nil
				end
				return result
			end
			return nil
		end

		return (remote :: RemoteEvent).OnServerEvent:Connect(function(player, payload)
			local ok, checked = gate(player, payload)
			if not ok then
				return
			end
			local success, err = pcall(handler, player, checked)
			if not success then
				error(string.format("[Net] handler '%s' errored: %s", name, tostring(err)), 0)
			end
		end)
	end

	-- client
	if def.dir ~= "s2c" and def.kind ~= "function" then
		error(string.format("[Net] '%s' is c2s; the client cannot listen to it", name), 2)
	end
	return (remote :: RemoteEvent).OnClientEvent:Connect(function(payload)
		local ok, err = pcall(handler, payload)
		if not ok then
			error(string.format("[Net] client handler '%s' errored: %s", name, tostring(err)), 0)
		end
	end)
end

-- What a validator reads: the whole wire contract, plus how many handlers are
-- actually attached. A declared event with no listener is a wiring bug.
function Net.describe(): { [string]: any }
	local c2s, s2c = 0, 0
	for _, def in definitions do
		if def.dir == "c2s" then
			c2s += 1
		else
			s2c += 1
		end
	end
	return {
		context = IS_SERVER and "server" or "client",
		events = Net.manifest(),
		clientToServer = c2s,
		serverToClient = s2c,
	}
end


--[[
	Siblings, resolved on the first thing that asks for one.

	This family holds modules beside this file, and until now the only way to
	reach them was to require the instance directly — so `Forge.Net.RateLimit`
	was nil while `require(ReplicatedStorage.Forge.Net.RateLimit)` worked. Two
	conventions in one engine, and the inconsistency is the defect: the first
	game written against `Forge.Core.Boot` died on `attempt to index nil`.

	Lazy rather than eager, matching `Forge` itself. Touching one family must
	not drag in every module it contains — several of them build tables and
	open connections at load, and paying for all of that to read one constant
	is how a require graph becomes a frame budget.
]]
return setmetatable(Net, {
	__index = function(self, key: string): any
		local child = script:FindFirstChild(key)
		if not child or not child:IsA("ModuleScript") then
			return nil
		end
		local module = require(child) :: any
		rawset(self, key, module)
		return module
	end,
})
