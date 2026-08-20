--!strict
--- Events of your own, with the same shape as Roblox's.
---
--- `BindableEvent` works and costs an Instance, a parent, and a round trip
--- through the engine for every fire. A game with a hundred custom events
--- built that way is a hundred Instances nobody can see in the explorer and a
--- measurable cost on every dispatch.
---
--- This is the plain Lua version: connect, fire, wait, once, disconnect. It is
--- deliberately API-compatible with `RBXScriptSignal` so a caller can swap one
--- for the other without rewriting the call sites.
---
--- **Firing must survive a bad handler.** One listener that errors must not
--- stop the others from being called, and must not stop the fire from
--- returning. Roblox's own signals behave that way and code written against
--- them assumes it.

local Signal = {}
Signal.__index = Signal

export type Connection = {
	connected: boolean,
	disconnect: (Connection) -> (),
	Disconnect: (Connection) -> (),
}

export type Class = {
	connect: (Class, (...any) -> ()) -> Connection,
	Connect: (Class, (...any) -> ()) -> Connection,
	once: (Class, (...any) -> ()) -> Connection,
	Once: (Class, (...any) -> ()) -> Connection,
	fire: (Class, ...any) -> (),
	Fire: (Class, ...any) -> (),
	wait: (Class) -> ...any,
	Wait: (Class) -> ...any,
	disconnectAll: (Class) -> (),
	count: (Class) -> number,
	destroy: (Class) -> (),
}

local Connection = {}
Connection.__index = Connection

function Connection.disconnect(self)
	if not self.connected then
		return
	end
	self.connected = false
	local listeners = self._signal._listeners
	for index, entry in ipairs(listeners) do
		if entry == self then
			table.remove(listeners, index)
			break
		end
	end
end
Connection.Disconnect = Connection.disconnect

--- A new signal. `name` is only ever used in warnings, and is worth passing:
--- "a listener errored" is much less useful than knowing which signal.
function Signal.new(name: string?): Class
	return (setmetatable({
		_listeners = {},
		_name = name or "signal",
		_waiting = {},
	}, Signal) :: any) :: Class
end

function Signal.connect(self, handler: (...any) -> ()): Connection
	if type(handler) ~= "function" then
		error("Signal:connect expects a function, got " .. typeof(handler), 2)
	end
	local connection = setmetatable({
		connected = true,
		_signal = self,
		_handler = handler,
		_once = false,
	}, Connection)
	table.insert(self._listeners, connection)
	return (connection :: any) :: Connection
end
Signal.Connect = Signal.connect

function Signal.once(self, handler: (...any) -> ()): Connection
	local connection = self:connect(handler)
	;(connection :: any)._once = true
	return connection
end
Signal.Once = Signal.once

function Signal.fire(self, ...)
	-- Copied before iterating: a handler that disconnects itself -- or connects
	-- something new -- must not corrupt the walk. This is the single most
	-- common way a hand-rolled signal breaks.
	local snapshot = table.clone(self._listeners)
	for _, connection in ipairs(snapshot) do
		if connection.connected then
			if connection._once then
				connection:disconnect()
			end
			-- One bad listener must not silence the rest.
			local ok, err = pcall(connection._handler, ...)
			if not ok then
				warn(("[Signal:%s] listener errored: %s"):format(self._name, tostring(err)))
			end
		end
	end

	local waiting = self._waiting
	if #waiting > 0 then
		self._waiting = {}
		local packed = table.pack(...)
		for _, thread in ipairs(waiting) do
			task.spawn(thread, table.unpack(packed, 1, packed.n))
		end
	end
end
Signal.Fire = Signal.fire

--- Yield until the next fire, and return what it carried.
function Signal.wait(self)
	table.insert(self._waiting, coroutine.running())
	return coroutine.yield()
end
Signal.Wait = Signal.wait

function Signal.disconnectAll(self)
	for _, connection in ipairs(table.clone(self._listeners)) do
		connection.connected = false
	end
	table.clear(self._listeners)
end

function Signal.count(self): number
	return #self._listeners
end

function Signal.destroy(self)
	self:disconnectAll()
	table.clear(self._waiting)
end

return Signal
