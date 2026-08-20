--!strict
-- Signal — Lua-side event. Cheaper than BindableEvent and it does not serialise
-- values, so tables cross a Fire by reference and identity survives.

export type Connection = {
	Connected: boolean,
	Disconnect: (Connection) -> (),
}

export type Signal<T...> = {
	Connect: (Signal<T...>, (T...) -> ()) -> Connection,
	Once: (Signal<T...>, (T...) -> ()) -> Connection,
	Wait: (Signal<T...>) -> T...,
	Fire: (Signal<T...>, T...) -> (),
	DisconnectAll: (Signal<T...>) -> (),
	Destroy: (Signal<T...>) -> (),
}

local Signal = {}
Signal.__index = Signal

function Signal.new(): any
	return setmetatable({ _handlers = {}, _alive = true }, Signal)
end

function Signal.is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Signal
end

function Signal:Connect(fn: (...any) -> ()): Connection
	assert(type(fn) == "function", "[Signal] Connect expects a function")
	local conn = { Connected = true, _fn = fn, _signal = self }
	function conn.Disconnect()
		if not conn.Connected then
			return
		end
		conn.Connected = false
		local list = self._handlers
		for i = #list, 1, -1 do
			if list[i] == conn then
				table.remove(list, i)
				break
			end
		end
	end
	table.insert(self._handlers, conn)
	return (conn :: any) :: Connection
end

function Signal:Once(fn: (...any) -> ()): Connection
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal:Wait(): ...any
	local thread = coroutine.running()
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

-- Handlers run on their own threads: one erroring listener never stops the rest,
-- and a listener that yields never stalls the firer.
function Signal:Fire(...)
	if not self._alive then
		return
	end
	local snapshot = table.clone(self._handlers)
	for _, conn in snapshot do
		if conn.Connected then
			task.spawn(conn._fn, ...)
		end
	end
end

-- Same, but synchronous: use when order and completion matter more than
-- isolation (a damage pipeline, for instance).
function Signal:FireSync(...)
	if not self._alive then
		return
	end
	local snapshot = table.clone(self._handlers)
	for _, conn in snapshot do
		if conn.Connected then
			local ok, err = pcall(conn._fn, ...)
			if not ok then
				warn("[Signal] handler error: " .. tostring(err))
			end
		end
	end
end

function Signal:DisconnectAll()
	for _, conn in table.clone(self._handlers) do
		conn.Connected = false
	end
	table.clear(self._handlers)
end

function Signal:Destroy()
	self:DisconnectAll()
	self._alive = false
end

return Signal
