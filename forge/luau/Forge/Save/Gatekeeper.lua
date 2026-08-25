--!strict
--[[
	Gatekeeper — the load lifecycle as a tiny state machine.

	A profile load is async and must not block a join, so every in-memory system
	starts blank. A save that runs before the load resolves would clobber the
	real saved profile with defaults; a save after a failed read would clobber
	it with blanks. Those sequencing rules live here, as data, so they can be
	tested outside Studio — the caller keeps the DataStore access.

	Statuses: Pending (read in flight), Loaded (authoritative, safe to write,
	including "new player"), Failed (remote state unknown — never write).

		local gate = Gatekeeper.new()
		gate:markFailed("GetDataStore timed out")
		gate:shouldSave() --> "skip" ; gate:readOnly() --> true

	The failure notice is delivered at most once and only after the client
	handshake: a notice fired before the client connects its handlers is
	silently dropped and the player would never learn why progress stopped.
]]

export type Status = "Pending" | "Loaded" | "Failed"
export type Decision = "save" | "wait" | "skip"

local Gatekeeper = {}
Gatekeeper.__index = Gatekeeper

export type Gate = typeof(setmetatable(
	{} :: {
		_status: Status,
		_data: any,
		_reason: string?,
		_readOnly: boolean,
		_clientReady: boolean,
		_noticeSent: boolean,
	},
	Gatekeeper
))

function Gatekeeper.new(): Gate
	local self = setmetatable({}, Gatekeeper)
	self._status = "Pending" :: Status
	self._data = nil :: any
	self._reason = nil :: string?
	self._readOnly = false
	self._clientReady = false
	self._noticeSent = false
	return self
end

-- The load resolved with authoritative data (a fresh player counts: nil is
-- "no saved profile yet", which is safe to build on).
function Gatekeeper:markLoaded(data: any)
	self._status = "Loaded"
	self._data = data
	self._readOnly = false
end

-- The load could not be read. Remote state is unknown for the rest of the
-- session; the blank in-memory copy must never reach the store.
function Gatekeeper:markFailed(reason: string?)
	self._status = "Failed"
	self._reason = reason
	self._readOnly = true
end

-- The client asked the server for its initial state: notices sent after this
-- point actually land.
function Gatekeeper:markClientReady()
	self._clientReady = true
end

-- What a save attempt should do right now.
--   "save": state is trustworthy, write it.
--   "wait": the load is still in flight, give it budget.
--   "skip": writing risks clobbering real saved data.
function Gatekeeper:shouldSave(): Decision
	if self._status == "Loaded" then
		return "save"
	end
	if self._status == "Failed" then
		self._readOnly = true
		return "skip"
	end
	return "wait"
end

-- True from the moment a load fails; sticky for the rest of the session.
function Gatekeeper:readOnly(): boolean
	return self._readOnly or self._status == "Failed"
end

function Gatekeeper:status(): Status
	return self._status
end

function Gatekeeper:data(): any
	return self._data
end

-- Deliver the load-failure notice exactly once, post-handshake. Returns the
-- failure reason when a notice should fire, nil otherwise (nothing to say,
-- client not listening yet, or already told).
function Gatekeeper:consumeNotice(): string?
	if self._status ~= "Failed" or not self._clientReady or self._noticeSent then
		return nil
	end
	self._noticeSent = true
	return self._reason
end

return Gatekeeper
