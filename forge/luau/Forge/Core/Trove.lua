--!strict
-- Trove — one object owns everything it created, and releases all of it at once.
--
-- Leaked `:Connect` handles are the number one cause of a Roblox project getting
-- slower the longer a session runs. The fix is not discipline, it is making the
-- cleanup path shorter than the leak path. Anything a system creates goes in a
-- trove; the system's destroy is one line.

export type Trove = {
	add: (Trove, any, string?) -> any,
	remove: (Trove, any) -> boolean,
	connect: (Trove, RBXScriptSignal, (...any) -> ()) -> RBXScriptConnection,
	task: (Trove, (dt: number) -> (), string?) -> RBXScriptConnection,
	extend: (Trove) -> Trove,
	clean: (Trove) -> (),
	destroy: (Trove) -> (),
}

local RunService = game:GetService("RunService")

local Trove = {}
Trove.__index = Trove

local function disposalFor(object: any, explicit: string?): string
	if explicit then
		return explicit
	end
	local t = typeof(object)
	if t == "RBXScriptConnection" then
		return "Disconnect"
	elseif t == "Instance" then
		return "Destroy"
	elseif t == "function" then
		return "call"
	elseif t == "thread" then
		return "cancel"
	elseif t == "table" then
		if type(object.destroy) == "function" then
			return "destroy"
		elseif type(object.Destroy) == "function" then
			return "Destroy"
		elseif type(object.Disconnect) == "function" then
			return "Disconnect"
		end
	end
	error("[Trove] do not know how to release a " .. t, 3)
end

function Trove.new(): any
	return setmetatable({ _items = {} }, Trove)
end

-- add(object [, methodName]) -> object   (returns what you passed, so it chains)
function Trove:add(object: any, method: string?): any
	assert(object ~= nil, "[Trove] cannot add nil")
	table.insert(self._items, { object = object, method = disposalFor(object, method) })
	return object
end

function Trove:remove(object: any): boolean
	for i, item in self._items do
		if item.object == object then
			table.remove(self._items, i)
			return true
		end
	end
	return false
end

function Trove:connect(signal: RBXScriptSignal, fn: (...any) -> ()): RBXScriptConnection
	return self:add(signal:Connect(fn))
end

-- A per-frame job that dies with the trove. `phase` is "render" (client only),
-- "stepped" or "heartbeat" (default).
function Trove:task(fn: (dt: number) -> (), phase: string?): RBXScriptConnection
	local signal: RBXScriptSignal
	if phase == "render" then
		assert(RunService:IsClient(), "[Trove] render phase is client-only")
		signal = RunService.RenderStepped
	elseif phase == "stepped" then
		signal = RunService.Stepped
	else
		signal = RunService.Heartbeat
	end
	return self:connect(signal, fn)
end

function Trove:extend(): any
	return self:add(Trove.new())
end

local function release(item)
	local object, method = item.object, item.method
	if method == "call" then
		task.spawn(object)
	elseif method == "cancel" then
		pcall(task.cancel, object)
	else
		local ok, err = pcall(function()
			object[method](object)
		end)
		if not ok then
			warn("[Trove] release failed: " .. tostring(err))
		end
	end
end

-- Releases in reverse order of addition, so a thing always outlives what it
-- depends on.
function Trove:clean()
	for i = #self._items, 1, -1 do
		local item = self._items[i]
		self._items[i] = nil
		release(item)
	end
end

Trove.destroy = Trove.clean

return Trove
