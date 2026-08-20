--!strict
--- Reusing instances instead of making them.
---
--- `Instance.new` and `Destroy` are cheap once and expensive in a loop. A
--- tower-defense game firing thirty projectiles a second creates and destroys
--- 1800 parts a minute, and the cost is not the creation -- it is the garbage
--- and the replication churn, which shows up as stutter rather than as a number
--- anybody is watching.
---
--- **A pooled object is not a fresh one.** Whatever the last user changed is
--- still changed. That is the whole trap, and it is why `reset` is a required
--- argument rather than an optional one: a pool without it hands out a
--- projectile that is still on fire from the previous shot.

local Pool = {}
Pool.__index = Pool

export type Class = {
	get: (Class, ...any) -> any,
	give: (Class, any) -> (),
	preload: (Class, number) -> (),
	size: (Class) -> number,
	live: (Class) -> number,
	clear: (Class) -> number,
	report: (Class) -> { [string]: any },
}

--- `make` builds one. `reset` returns one to a known state before reuse.
function Pool.new(make: () -> any, reset: (any) -> (), options: { [string]: any }?): Class
	if type(make) ~= "function" then
		error("Pool.new needs a function that makes one", 2)
	end
	if type(reset) ~= "function" then
		error("Pool.new needs a reset function: a reused object keeps whatever "
			.. "the last user did to it, which is the entire hazard", 2)
	end
	local opts = options or {}
	return (setmetatable({
		_make = make,
		_reset = reset,
		_idle = {},
		_live = 0,
		_made = 0,
		_reused = 0,
		_cap = tonumber(opts.cap) or 256,
		_parent = opts.parent,
	}, Pool) :: any) :: Class
end

--- A pool of parts, the common case.
function Pool.ofPart(template: BasePart, options: { [string]: any }?): Class
	local opts = options or {}
	local parent = opts.parent or workspace
	return Pool.new(function()
		local copy = template:Clone()
		copy.Parent = parent
		return copy
	end, function(part: BasePart)
		part.Anchored = template.Anchored
		part.CanCollide = template.CanCollide
		part.Transparency = template.Transparency
		part.Size = template.Size
		part.Color = template.Color
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
		part.CFrame = template.CFrame
		part.Parent = nil
	end, opts)
end

function Pool.get(self, ...)
	local item = table.remove(self._idle)
	if item == nil then
		item = self._make(...)
		self._made += 1
	else
		self._reused += 1
	end
	self._live += 1
	if typeof(item) == "Instance" and self._parent ~= nil then
		item.Parent = self._parent
	end
	return item
end

function Pool.give(self, item: any)
	if item == nil then
		return
	end
	local ok, err = pcall(self._reset, item)
	if not ok then
		warn("[Pool] reset failed, discarding: " .. tostring(err))
		if typeof(item) == "Instance" then
			item:Destroy()
		end
		self._live = math.max(self._live - 1, 0)
		return
	end
	self._live = math.max(self._live - 1, 0)
	-- Past the cap, let it go. An unbounded pool that grows to a peak and never
	-- shrinks is a memory leak with good intentions.
	if #self._idle >= self._cap then
		if typeof(item) == "Instance" then
			item:Destroy()
		end
		return
	end
	table.insert(self._idle, item)
end

function Pool.preload(self, count: number)
	for _ = 1, count do
		local item = self._make()
		self._made += 1
		local ok = pcall(self._reset, item)
		if ok then
			table.insert(self._idle, item)
		end
	end
end

function Pool.size(self): number
	return #self._idle
end

function Pool.live(self): number
	return self._live
end

function Pool.clear(self): number
	local count = #self._idle
	for _, item in ipairs(self._idle) do
		if typeof(item) == "Instance" then
			item:Destroy()
		end
	end
	table.clear(self._idle)
	return count
end

function Pool.report(self): { [string]: any }
	return {
		idle = #self._idle,
		live = self._live,
		made = self._made,
		reused = self._reused,
		cap = self._cap,
		-- The number that says whether pooling is earning its keep.
		reuseRate = if self._made + self._reused > 0
			then self._reused / (self._made + self._reused) else 0,
	}
end

return Pool
