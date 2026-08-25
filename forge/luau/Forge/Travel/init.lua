--!strict
--[[
	Travel — moving players between places, and arriving with something.

	A Roblox experience is many places: a lobby, a match, a hub. Forge has only
	ever known one, so a game built on it could only ever be one room. This is
	the layer that makes a game an experience.

	Three things `TeleportService` does badly on its own, and this fixes each:

	  **It fails.** Teleports fail for reasons nobody controls — a full server,
	  a place still updating, a flood check. Roblox raises `TeleportInitFailed`
	  and the player is left standing there with no explanation. Every teleport
	  here retries with backoff and reports what happened.

	  **It loses the party.** Teleporting four friends individually sends them
	  to four different servers. `TeleportPartyAsync` and reserved servers exist
	  precisely to avoid that and are easy to forget.

	  **It forgets why.** Teleport data is the only thing that survives the
	  trip, and it is unsigned — a modified client can rewrite it. So anything
	  that matters travels through `MemoryStore` keyed by a token, and the
	  teleport carries only the token.

		Travel.define("match", { placeId = 0, reserved = true, party = true })
		Travel.send(players, "match", { mode = "ranked", seed = 41 })

		-- on arrival, in the destination place
		local arrival = Travel.arrival(player)
		if arrival then print(arrival.mode) end

	--- On trusting what arrives -------------------------------------------

	`TeleportService:GetLocalPlayerTeleportData` is client-supplied. Reading a
	match's difficulty, a reward, or a permission out of it is the same as
	letting the player choose them. The token pattern below costs one
	MemoryStore read and removes the entire class of exploit.
]]

local TeleportService = game:GetService("TeleportService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Core).Signal

local Travel = {}

export type Destination = {
	placeId: number,
	reserved: boolean?,
	party: boolean?,
	--: Seconds a sealed payload survives. Long enough for a slow load.
	ttl: number?,
}

Travel.config = {
	attempts = 3,
	backoff = 2,
	ttl = 300,
	storeName = "forge_travel",
}

Travel.departed = Signal.new() -- (players, destinationName)
Travel.failed = Signal.new() -- (player, destinationName, reason)
Travel.arrived = Signal.new() -- (player, payload)

local destinations: { [string]: Destination } = {}
local arrivals: { [Player]: any } = {}
local reservedCodes: { [string]: string } = {}
local stats = { sent = 0, failed = 0, arrived = 0, sealed = 0 }

local function store(): any
	local ok, map = pcall(function()
		return MemoryStoreService:GetSortedMap(Travel.config.storeName)
	end)
	return ok and map or nil
end

local function serverOnly(what: string): boolean
	if RunService:IsServer() then
		return true
	end
	warn(string.format("[Travel] %s is server-only", what))
	return false
end

-- ================================= define ===================================
function Travel.define(name: string, destination: Destination)
	destinations[name] = destination
end

function Travel.defineMany(table_: { [string]: Destination })
	for name, destination in table_ do
		destinations[name] = destination
	end
end

function Travel.names(): { string }
	local out = {}
	for name in destinations do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- ================================= sealing ==================================
--[[
	Put the payload somewhere the player cannot reach, and carry a token.

	The token is meaningless on its own: a player who rewrites it gets a key to
	nothing. Everything that decides difficulty, rewards or permissions lives
	behind it, in a store only servers can read.
]]
local function seal(payload: any, ttl: number): string?
	local map = store()
	if not map then
		return nil
	end
	local token = HttpService:GenerateGUID(false)
	local ok = pcall(function()
		map:SetAsync(token, payload, ttl)
	end)
	if not ok then
		return nil
	end
	stats.sealed += 1
	return token
end

local function unseal(token: string): any?
	local map = store()
	if not map then
		return nil
	end
	local ok, value = pcall(function()
		return map:GetAsync(token)
	end)
	if not ok then
		return nil
	end
	--[[
		Read once and remove.

		A token that survives its use is a token that can be replayed — the
		same match entry claimed twice, the same reward granted twice. Removing
		on read is what makes it a ticket rather than a password.
	]]
	pcall(function()
		map:RemoveAsync(token)
	end)
	return value
end

-- ================================== send ====================================
local function reserveFor(name: string, destination: Destination): string?
	if not destination.reserved then
		return nil
	end
	if reservedCodes[name] then
		return reservedCodes[name]
	end
	local ok, code = pcall(function()
		return TeleportService:ReserveServer(destination.placeId)
	end)
	if not ok then
		warn(string.format("[Travel] could not reserve a server for '%s': %s",
			name, tostring(code)))
		return nil
	end
	return code
end

--[[
	Send one player or a party.

	A party goes together or not at all: teleporting four friends with four
	separate calls is four different servers, and the whole reason they pressed
	the button was to be in one.

	Retries with backoff, because teleport failures are routine rather than
	exceptional — a full destination, a place mid-update, a flood check. A
	player left standing with no explanation is the default behaviour this
	exists to replace.
]]
function Travel.send(who: Player | { Player }, name: string, payload: any?): boolean
	if not serverOnly("send") then
		return false
	end
	local destination = destinations[name]
	if not destination then
		warn(string.format("[Travel] no destination named '%s'", tostring(name)))
		return false
	end

	local group: { Player } = typeof(who) == "table" and who :: { Player } or { who :: Player }
	if #group == 0 then
		return false
	end

	local token = payload and seal(payload, destination.ttl or Travel.config.ttl) or nil
	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({ token = token })

	local code = reserveFor(name, destination)
	if code then
		options.ReservedServerAccessCode = code
	end
	if destination.party and #group > 1 then
		options.ShouldReserveServer = destination.reserved == true
	end

	for attempt = 1, Travel.config.attempts do
		local ok, err = pcall(function()
			TeleportService:TeleportAsync(destination.placeId, group, options)
		end)
		if ok then
			stats.sent += #group
			Travel.departed:Fire(group, name)
			return true
		end

		if attempt == Travel.config.attempts then
			stats.failed += #group
			for _, player in group do
				Travel.failed:Fire(player, name, tostring(err))
			end
			warn(string.format("[Travel] '%s' failed after %d attempts: %s",
				name, attempt, tostring(err)))
			return false
		end
		task.wait(Travel.config.backoff * attempt)
	end
	return false
end

-- ================================= arrival ==================================
--[[
	What a player arrived with, if anything.

	Read on the server from the sealed store, never from the teleport data
	itself. The teleport data carries only the token; the payload was never in
	the player's hands.
]]
function Travel.arrival(player: Player): any?
	return arrivals[player]
end

--[[
	Start listening for arrivals.

	Called once in a destination place's bootstrap. Every joining player's
	teleport data is checked for a token and, if one is there, the sealed
	payload is fetched and handed to `Travel.arrived`.
]]
function Travel.start()
	if not serverOnly("start") then
		return
	end

	local function receive(player: Player)
		local ok, data = pcall(function()
			return player:GetJoinData()
		end)
		if not ok or typeof(data) ~= "table" then
			return
		end
		local teleportData = data.TeleportData
		if typeof(teleportData) ~= "table" or typeof(teleportData.token) ~= "string" then
			return
		end
		local payload = unseal(teleportData.token)
		if payload ~= nil then
			arrivals[player] = payload
			stats.arrived += 1
			Travel.arrived:Fire(player, payload)
		end
	end

	Players.PlayerAdded:Connect(receive)
	for _, player in Players:GetPlayers() do
		task.spawn(receive, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		arrivals[player] = nil
	end)

	--[[
		A failed teleport leaves the player here, not there.

		Roblox reports this on the *origin* server, and doing nothing with it
		means a player who pressed a button and stayed put with no message —
		which reads as the button being broken.
	]]
	TeleportService.TeleportInitFailed:Connect(function(player, result, message)
		stats.failed += 1
		Travel.failed:Fire(player, "unknown", string.format("%s: %s",
			tostring(result), tostring(message)))
	end)
end

function Travel.describe(): { [string]: any }
	local waiting = 0
	for _ in arrivals do
		waiting += 1
	end
	return {
		context = RunService:IsServer() and "server" or "client",
		destinations = Travel.names(),
		arrivalsHeld = waiting,
		stats = table.clone(stats),
	}
end


--[[
	Siblings, resolved on the first thing that asks for one.

	This family holds modules beside this file, and until now the only way to
	reach them was to require the instance directly — so `Forge.Travel.CarryData`
	was nil while `require(ReplicatedStorage.Forge.Travel.CarryData)` worked. Two
	conventions in one engine, and the inconsistency is the defect: the first
	game written against `Forge.Core.Boot` died on `attempt to index nil`.

	Lazy rather than eager, matching `Forge` itself. Touching one family must
	not drag in every module it contains — several of them build tables and
	open connections at load, and paying for all of that to read one constant
	is how a require graph becomes a frame budget.
]]
return setmetatable(Travel, {
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
