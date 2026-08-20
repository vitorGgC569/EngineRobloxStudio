--!strict
-- Cross-cutting player feedback, from authoritative fact to client presentation.
--
-- Gameplay decides that a purchase happened. This module may tell a client that
-- fact; it can never make the purchase happen. The RemoteEvent is created only
-- by the server, has no OnServerEvent mutation path, and carries semantic event
-- names rather than sound ids, prices, grants or ownership data.

local RunService = game:GetService("RunService")

local Feedback = {}

local CHANNEL_NAME = "RQEFeedback"
local CHANNEL_VERSION = 1
local MAX_PER_SECOND = 12
local COALESCE_SECONDS = 0.08

-- Fields are deliberately narrow. Adding a presentation detail is a conscious
-- schema change; passing an arbitrary gameplay table could leak prices, asset ids
-- or private state into a client-facing packet without anyone noticing.
local EVENT_FIELDS: { [string]: { [string]: string } } = {
	success = { itemName = "string", position = "Vector3" },
	error = { reasonKey = "string", itemName = "string", position = "Vector3" },
	purchase = { itemName = "string", position = "Vector3" },
	reward = { amount = "number", itemName = "string", position = "Vector3" },
	build = { itemName = "string", position = "Vector3" },
	upgrade = { itemName = "string", position = "Vector3" },
	unlock = { itemName = "string" },
	damage = { amount = "number", position = "Vector3" },
	wave = { round = "number" },
	victory = { round = "number" },
	defeat = { round = "number" },
}

export type Detail = { [string]: any }
export type Payload = {
	event: string,
	sequence: number,
	[string]: any,
}

export type Receipt = {
	status: string,
	event: string,
	sequence: number?,
	reason: string?,
}

local function fail(message: string): never
	error("[GameKit.Feedback] " .. message, 3)
end

function Feedback.events(): { string }
	local names = {}
	for name in pairs(EVENT_FIELDS) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

function Feedback.isEvent(name: any): boolean
	return type(name) == "string" and EVENT_FIELDS[name] ~= nil
end

local function validNumber(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) <= 1e12
end

--- Validate and copy only presentation-safe fields.
---
--- Unknown fields reject the whole packet instead of being silently stripped.
--- Silent stripping would let a caller believe its asset id or price reached the
--- client, and that disagreement is precisely what the schema is meant to stop.
function Feedback.sanitize(event: any, detail: any): (Detail?, { string })
	local fields = if type(event) == "string" then EVENT_FIELDS[event] else nil
	if fields == nil then
		return nil, { "unknown feedback event " .. tostring(event) }
	end
	if detail ~= nil and type(detail) ~= "table" then
		return nil, { "feedback detail must be a table" }
	end

	local clean: Detail = {}
	local problems: { string } = {}
	for key, value in pairs(detail or {}) do
		local expected = fields[key]
		if expected == nil then
			table.insert(problems, string.format(
				"field %q is not allowed for feedback event %q", tostring(key), event))
		elseif expected == "string" then
			if type(value) ~= "string" or #value == 0 or #value > 80 then
				table.insert(problems, string.format("field %q must be 1-80 characters", key))
			else
				clean[key] = value
			end
		elseif expected == "number" then
			if not validNumber(value) then
				table.insert(problems, string.format("field %q must be a finite bounded number", key))
			else
				clean[key] = value
			end
		elseif expected == "Vector3" then
			if typeof(value) ~= "Vector3" then
				table.insert(problems, string.format("field %q must be a Vector3", key))
			else
				clean[key] = value
			end
		end
	end
	if #problems > 0 then
		return nil, problems
	end
	return clean, problems
end

local function enabledSet(config: { [string]: any }?): { [string]: boolean }
	local enabled: { [string]: boolean } = {}
	local declared = if config ~= nil then config.events else nil
	if declared == nil then
		for name in pairs(EVENT_FIELDS) do
			enabled[name] = true
		end
		return enabled
	end
	if type(declared) ~= "table" then
		fail("config.events must be an array of semantic event names")
	end
	for _, name in ipairs(declared) do
		if not Feedback.isEvent(name) then
			fail("config enables unknown event " .. tostring(name))
		end
		enabled[name] = true
	end
	return enabled
end

--- Create the one-way server channel.
---
--- There is intentionally no client request API. A client can call FireServer
--- on any RemoteEvent it can see, but this event has no OnServerEvent listener,
--- so doing so reaches no code and mutates no game state.
function Feedback.server(config: { [string]: any }?): any
	if not RunService:IsServer() then
		fail("server() can only create the channel on the server")
	end

	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Players = game:GetService("Players")
	local enabled = enabledSet(config)
	local remote = ReplicatedStorage:FindFirstChild(CHANNEL_NAME)
	if remote ~= nil then
		if not remote:IsA("RemoteEvent") then
			fail(CHANNEL_NAME .. " exists but is not a RemoteEvent")
		end
		if remote:GetAttribute("RQEServerOwned") ~= true
			or remote:GetAttribute("RQEFeedbackVersion") ~= CHANNEL_VERSION then
			fail(CHANNEL_NAME .. " exists without the expected server ownership receipt")
		end
	else
		remote = Instance.new("RemoteEvent")
		remote.Name = CHANNEL_NAME
		remote:SetAttribute("RQEServerOwned", true)
		remote:SetAttribute("RQEFeedbackVersion", CHANNEL_VERSION)
		remote.Parent = ReplicatedStorage
	end

	local sequence = 0
	local traffic: { [Player]: { window: number, count: number, recent: { [string]: number } } } =
		setmetatable({}, { __mode = "k" }) :: any
	local channel = {}

	function channel:emit(player: Player, event: string, detail: Detail?): Receipt
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return { status = "INVALID", event = tostring(event), reason = "target is not a Player" }
		end
		if not enabled[event] then
			return { status = "DISABLED", event = tostring(event), reason = "event is not enabled for this game" }
		end
		local clean, problems = Feedback.sanitize(event, detail)
		if clean == nil then
			return { status = "INVALID", event = tostring(event), reason = table.concat(problems, "; ") }
		end

		local now = os.clock()
		local state = traffic[player]
		if state == nil or now - state.window >= 1 then
			state = { window = now, count = 0, recent = {} }
			traffic[player] = state
		end
		local last = state.recent[event]
		if last ~= nil and now - last < COALESCE_SECONDS then
			return { status = "COALESCED", event = event }
		end
		if state.count >= MAX_PER_SECOND then
			return { status = "RATE_LIMITED", event = event }
		end

		state.count += 1
		state.recent[event] = now
		sequence += 1
		local payload: Payload = clean :: any
		payload.event = event
		payload.sequence = sequence
		local serverRemote = remote :: RemoteEvent
		serverRemote:FireClient(player, payload)
		return { status = "SENT", event = event, sequence = sequence }
	end

	function channel:broadcast(event: string, detail: Detail?): { Receipt }
		local receipts = {}
		for _, player in ipairs(Players:GetPlayers()) do
			table.insert(receipts, self:emit(player, event, detail))
		end
		return receipts
	end

	function channel:events(): { string }
		local names = {}
		for name in pairs(enabled) do
			table.insert(names, name)
		end
		table.sort(names)
		return names
	end

	return channel
end

--- Bind a presenter on the client without creating any client-to-server path.
function Feedback.bindClient(config: { [string]: any }?, present: (Payload) -> ()): RBXScriptConnection
	if not RunService:IsClient() then
		fail("bindClient() can only run on the client")
	end
	if type(present) ~= "function" then
		fail("bindClient needs a presentation callback")
	end
	local enabled = enabledSet(config)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local remote = ReplicatedStorage:WaitForChild(CHANNEL_NAME, 10)
	if remote == nil or not remote:IsA("RemoteEvent") then
		fail("the server did not create " .. CHANNEL_NAME)
	end
	if remote:GetAttribute("RQEServerOwned") ~= true then
		fail(CHANNEL_NAME .. " has no server ownership receipt")
	end

	local clientRemote = remote :: RemoteEvent
	return clientRemote.OnClientEvent:Connect(function(payload: any)
		if type(payload) ~= "table" or not enabled[payload.event] or not validNumber(payload.sequence) then
			return
		end
		local detail: Detail = {}
		for key, value in pairs(payload) do
			if key ~= "event" and key ~= "sequence" then
				detail[key] = value
			end
		end
		local clean = Feedback.sanitize(payload.event, detail)
		if clean == nil then
			return
		end
		clean.event = payload.event
		clean.sequence = payload.sequence
		present(clean :: Payload)
	end)
end

Feedback.CHANNEL_NAME = CHANNEL_NAME
Feedback.PROTOCOL_VERSION = CHANNEL_VERSION

return Feedback
