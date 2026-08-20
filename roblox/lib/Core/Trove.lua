--!strict
--- One place to put everything that has to be cleaned up.
---
--- The commonest leak in a Roblox game is not a big one: it is a `Heartbeat`
--- connection made when a door opened and never disconnected, times two hundred
--- doors, times an hour. Nothing errors. The frame rate just goes.
---
--- A trove holds connections, Instances, threads, tweens and plain functions,
--- and `clean()` disposes of each by its own rules. Every system that connects
--- to anything should own one, and every system that can be destroyed should
--- clean it.
---
--- **It knows how to dispose of each kind.** A connection is disconnected, an
--- Instance destroyed, a thread cancelled, a table with `destroy` or `Destroy`
--- called. Passing something it cannot dispose of is an error at `add` time --
--- when the stack still says where it came from -- rather than a silent no-op
--- at `clean` time, when it does not.

local Trove = {}
Trove.__index = Trove

export type Class = {
	add: <T>(Class, T, string?) -> T,
	remove: (Class, any) -> boolean,
	connect: (Class, RBXScriptSignal, (...any) -> ()) -> RBXScriptConnection,
	task: (Class, (...any) -> ()) -> thread,
	clean: (Class) -> number,
	destroy: (Class) -> number,
	extend: (Class) -> Class,
	size: (Class) -> number,
}

local function disposerFor(item: any, explicit: string?): (string?, string?)
	if explicit ~= nil then
		return explicit, nil
	end
	local kind = typeof(item)
	if kind == "RBXScriptConnection" then
		return "Disconnect", nil
	end
	if kind == "Instance" then
		return "Destroy", nil
	end
	if kind == "function" then
		return "call", nil
	end
	if kind == "thread" then
		return "cancel", nil
	end
	if kind == "table" then
		if type((item :: any).destroy) == "function" then
			return "destroy", nil
		end
		if type((item :: any).Destroy) == "function" then
			return "Destroy", nil
		end
		if type((item :: any).disconnect) == "function" then
			return "disconnect", nil
		end
		return nil, "a table with no destroy, Destroy or disconnect"
	end
	return nil, kind
end

function Trove.new(): Class
	return (setmetatable({ _items = {} }, Trove) :: any) :: Class
end

--- Hold something. Returns it, so `local part = trove:add(Instance.new("Part"))`
--- reads naturally.
function Trove.add(self, item: any, method: string?)
	local disposer, why = disposerFor(item, method)
	if disposer == nil then
		error(("Trove cannot dispose of %s; pass the method name as the second "
			.. "argument if it has one"):format(why or typeof(item)), 2)
	end
	table.insert(self._items, { item = item, disposer = disposer })
	return item
end

function Trove.remove(self, item: any): boolean
	for index, entry in ipairs(self._items) do
		if entry.item == item then
			table.remove(self._items, index)
			return true
		end
	end
	return false
end

--- Connect and hold in one call, which is the shape that stops the leak.
function Trove.connect(self, signal: any, handler: (...any) -> ()): any
	local connection = signal:Connect(handler)
	self:add(connection)
	return connection
end

--- Spawn and hold, so a loop dies with its owner.
function Trove.task(self, body: (...any) -> ()): thread
	local thread = task.spawn(body)
	self:add(thread)
	return thread
end

--- A child trove, cleaned when this one is.
function Trove.extend(self): Class
	local child = Trove.new()
	self:add(child)
	return child
end

--- Dispose of everything, newest first, and report how many.
---
--- Reverse order matters: later items often depend on earlier ones, and
--- destroying a parent Instance before disconnecting a connection to its child
--- produces warnings that look like bugs elsewhere.
function Trove.clean(self): number
	local count = #self._items
	for index = count, 1, -1 do
		local entry = self._items[index]
		local ok, err = pcall(function()
			if entry.disposer == "call" then
				entry.item()
			elseif entry.disposer == "cancel" then
				task.cancel(entry.item)
			else
				entry.item[entry.disposer](entry.item)
			end
		end)
		if not ok then
			warn("[Trove] disposing failed: " .. tostring(err))
		end
	end
	table.clear(self._items)
	return count
end

Trove.destroy = Trove.clean

function Trove.size(self): number
	return #self._items
end

return Trove
