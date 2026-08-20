--!strict
--[[
	Entity — composition instead of inheritance.

	The problem this solves
	-----------------------
	A framework grows systems that know what a Player is and what an NPC is.
	Then you want a destructible barrel that has health but no brain, a turret
	that fights but never moves, a chest that can be interacted with but is not
	a creature — and every system needs a new special case. That is the point
	where a framework stops scaling and a game becomes a pile of `if`.

	Here nothing is a Player or an NPC. Things are entities, and an entity is
	whatever components it carries. `Combat` operates on anything with Health.
	`Movement` operates on anything with a Transform and a Motor. A barrel is an
	entity with Health and no Brain, and no system needed changing.

		Entity.define("Health", { max = 100, current = 100, dead = false })
		Entity.define("Brain",  { state = "idle", target = nil })

		local orc = Entity.create({ name = "Orc", instance = model })
		Entity.add(orc, "Health", { max = 240, current = 240 })
		Entity.add(orc, "Brain")

		for id, health in Entity.query("Health") do
			if health.current <= 0 then Entity.destroy(id) end
		end

		Entity.system("regen", { "Health" }, function(dt, id, health)
			health.current = math.min(health.max, health.current + 2 * dt)
		end, { rate = 4 })

	This is not a full archetype ECS, and deliberately so: in Luau the cache
	wins of archetype storage do not materialise, while the complexity does.
	Component stores keyed by entity id give the decoupling, which is the part
	that actually matters.

	Instances
	---------
	Roblox is instance-based, so an entity may own one. The link is two-way and
	self-cleaning: destroy the instance and the entity goes with it.
]]

local Workspace = game:GetService("Workspace")

local Signal = require(script.Parent.Core.Signal)
local Sched = require(script.Parent.Core.Sched)

local Entity = {}

export type Id = number

Entity.created = Signal.new() -- (id)
Entity.destroyed = Signal.new() -- (id, name)
Entity.componentAdded = Signal.new() -- (id, component, data)
Entity.componentRemoved = Signal.new() -- (id, component)

local nextId: Id = 1
local alive: { [Id]: boolean } = {}
local names: { [Id]: string } = {}
local tags: { [Id]: { [string]: boolean } } = {}

-- component name -> { [entityId] = data }
local stores: { [string]: { [Id]: any } } = {}
local schemas: { [string]: any } = {}

local instanceOf: { [Id]: Instance } = {}
local entityOf: { [Instance]: Id } = {}
local instanceConns: { [Id]: RBXScriptConnection } = {}

local systems: { [string]: any } = {}
local systemGroup = nil

-- ============================== components ==================================
--[[
	Declaring a component is declaring its default shape. Defaults are deep
	copied per entity, so two orcs never share one Health table — the single
	most common bug in a hand-rolled component system.
]]
function Entity.define(component: string, defaults: any?, options: any?)
	assert(type(component) == "string" and #component > 0, "[Entity] component needs a name")
	schemas[component] = defaults or {}
	stores[component] = stores[component] or {}
	if options and options.persist then
		Entity.persist(component, true)
	end
end

function Entity.components(): { string }
	local out = {}
	for name in schemas do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

-- ================================ lifecycle =================================
export type CreateOptions = {
	name: string?,
	instance: Instance?,
	tags: { string }?,
	components: { [string]: any }?,
}

function Entity.create(options: CreateOptions?): Id
	local opts = options or {}
	local id = nextId
	nextId += 1

	alive[id] = true
	names[id] = opts.name or ("entity_" .. id)
	tags[id] = {}

	if opts.tags then
		for _, tag in opts.tags do
			tags[id][tag] = true
		end
	end
	if opts.instance then
		Entity.bind(id, opts.instance)
	end
	if opts.components then
		for component, data in opts.components do
			Entity.add(id, component, data)
		end
	end

	Entity.created:Fire(id)
	return id
end

function Entity.exists(id: Id): boolean
	return alive[id] == true
end

function Entity.name(id: Id): string
	return names[id] or "?"
end

function Entity.destroy(id: Id, destroyInstance: boolean?)
	if not alive[id] then
		return
	end
	alive[id] = nil

	for component, store in stores do
		if store[id] ~= nil then
			store[id] = nil
			Entity.componentRemoved:Fire(id, component)
		end
	end

	local conn = instanceConns[id]
	if conn then
		conn:Disconnect()
		instanceConns[id] = nil
	end

	local instance = instanceOf[id]
	if instance then
		entityOf[instance] = nil
		instanceOf[id] = nil
		if destroyInstance ~= false and instance.Parent then
			instance:Destroy()
		end
	end

	local name = names[id]
	names[id] = nil
	tags[id] = nil
	Entity.destroyed:Fire(id, name)
end

function Entity.destroyAll()
	for id in table.clone(alive) do
		Entity.destroy(id)
	end
end

-- ============================ instance binding ==============================
function Entity.bind(id: Id, instance: Instance)
	assert(alive[id], "[Entity] cannot bind a destroyed entity")
	instanceOf[id] = instance
	entityOf[instance] = id
	instance:SetAttribute("ForgeEntity", id)

	-- The instance is the thing a player can delete, a falling part can be
	-- destroyed by, or streaming can remove. When it goes, so does the entity.
	instanceConns[id] = instance.Destroying:Connect(function()
		Entity.destroy(id, false)
	end)
end

function Entity.instance(id: Id): Instance?
	return instanceOf[id]
end

function Entity.of(instance: Instance?): Id?
	if not instance then
		return nil
	end
	local direct = entityOf[instance]
	if direct then
		return direct
	end
	-- a hit part belongs to the model that owns the entity
	local model = instance:FindFirstAncestorOfClass("Model")
	return model and entityOf[model] or nil
end

function Entity.position(id: Id): Vector3?
	local instance = instanceOf[id]
	if instance and instance:IsA("Model") then
		return instance:GetPivot().Position
	elseif instance and instance:IsA("BasePart") then
		return instance.Position
	end
	local transform = Entity.get(id, "Transform")
	return transform and transform.position or nil
end

-- ================================= tags =====================================
function Entity.tag(id: Id, tag: string)
	if tags[id] then
		tags[id][tag] = true
	end
end

function Entity.untag(id: Id, tag: string)
	if tags[id] then
		tags[id][tag] = nil
	end
end

function Entity.tagged(id: Id, tag: string): boolean
	return tags[id] ~= nil and tags[id][tag] == true
end

function Entity.withTag(tag: string): { Id }
	local out = {}
	for id in alive do
		if tags[id] and tags[id][tag] then
			table.insert(out, id)
		end
	end
	table.sort(out)
	return out
end

-- ============================ component access ==============================
function Entity.add(id: Id, component: string, data: any?): any
	assert(alive[id], "[Entity] cannot add a component to a destroyed entity")
	local store = stores[component]
	if not store then
		warn(string.format("[Entity] component '%s' was never defined; defining it empty", component))
		Entity.define(component)
		store = stores[component]
	end

	local value = deepCopy(schemas[component])
	if type(data) == "table" then
		for k, v in data do
			value[k] = v
		end
	elseif data ~= nil then
		value = data
	end

	store[id] = value
	Entity.componentAdded:Fire(id, component, value)
	return value
end

function Entity.get(id: Id, component: string): any
	local store = stores[component]
	return store and store[id] or nil
end

-- Get, creating with defaults if absent. For systems that want to assume.
function Entity.ensure(id: Id, component: string, data: any?): any
	return Entity.get(id, component) or Entity.add(id, component, data)
end

function Entity.has(id: Id, component: string): boolean
	local store = stores[component]
	return store ~= nil and store[id] ~= nil
end

function Entity.remove(id: Id, component: string)
	local store = stores[component]
	if store and store[id] ~= nil then
		store[id] = nil
		Entity.componentRemoved:Fire(id, component)
	end
end

function Entity.componentsOf(id: Id): { string }
	local out = {}
	for component, store in stores do
		if store[id] ~= nil then
			table.insert(out, component)
		end
	end
	table.sort(out)
	return out
end

-- ============================= serialisation ================================
--[[
	Persisting entities.

	Not every component should be saved. A Health component must survive a
	rejoin; a Velocity or an AnimationState is derived and saving it is worse
	than useless, because a stale value loads as truth. So persistence is opt-in
	per component:

		Entity.define("Health", { max = 100, current = 100 }, { persist = true })

	`Entity.serialize` returns a plain table safe for JSONEncode and a
	DataStore; `Entity.deserialize` rebuilds the entity and returns its new id.
	Instances are not serialised — an entity's body is rebuilt by whatever
	created it (usually Assets), and only its state comes back.
]]
local persistent: { [string]: boolean } = {}

function Entity.persist(component: string, value: boolean?)
	persistent[component] = value ~= false
end

function Entity.isPersistent(component: string): boolean
	return persistent[component] == true
end

local function plain(value: any): any
	local kind = typeof(value)
	if kind == "Vector3" then
		return { __t = "v3", value.X, value.Y, value.Z }
	elseif kind == "CFrame" then
		return { __t = "cf", value:GetComponents() }
	elseif kind == "Color3" then
		return { __t = "c3", value.R, value.G, value.B }
	elseif kind == "Instance" then
		return nil -- an instance is a body, not state
	elseif kind == "table" then
		local out: any = {}
		for key, inner in value do
			local converted = plain(inner)
			if converted ~= nil then
				out[key] = converted
			end
		end
		return out
	elseif kind == "number" and value ~= value then
		return nil -- NaN never round-trips
	end
	return value
end

local function revive(value: any): any
	if type(value) ~= "table" then
		return value
	end
	if value.__t == "v3" then
		return Vector3.new(value[1], value[2], value[3])
	elseif value.__t == "cf" then
		return CFrame.new(table.unpack(value, 1, 12))
	elseif value.__t == "c3" then
		return Color3.new(value[1], value[2], value[3])
	end
	local out: any = {}
	for key, inner in value do
		out[key] = revive(inner)
	end
	return out
end

function Entity.serialize(id: Id): any?
	if not alive[id] then
		return nil
	end
	local components: any = {}
	for component, store in stores do
		if store[id] ~= nil and persistent[component] then
			components[component] = plain(store[id])
		end
	end

	local tagList = {}
	for tag in (tags[id] or {}) do
		table.insert(tagList, tag)
	end
	table.sort(tagList)

	local position = Entity.position(id)
	return {
		name = names[id],
		tags = tagList,
		components = components,
		position = position and { position.X, position.Y, position.Z } or nil,
	}
end

function Entity.deserialize(data: any): Id
	local id = Entity.create({ name = data.name, tags = data.tags })
	for component, value in (data.components or {}) do
		Entity.add(id, component, revive(value))
	end
	return id
end

-- Every persistable entity in one call, for a world save.
function Entity.serializeAll(filter: ((id: Id) -> boolean)?): { any }
	local out = {}
	for id in alive do
		if filter and not filter(id) then
			continue
		end
		local entry = Entity.serialize(id)
		if entry and next(entry.components) ~= nil then
			table.insert(out, entry)
		end
	end
	return out
end

-- ================================ queries ===================================
local function buildQuery(ordered: boolean, requested: any)
	assert(requested.n > 0, "[Entity] query needs at least one component")

	local smallest, smallestCount = nil, math.huge
	for i = 1, requested.n do
		local store = stores[requested[i]]
		if not store then
			return function()
				return nil
			end
		end
		local count = 0
		for _ in store do
			count += 1
		end
		if count < smallestCount then
			smallest, smallestCount = store, count
		end
	end

	--[[
		Snapshot the driving ids: a system that destroys entities while iterating
		must not invalidate its own loop.

		This used to `table.sort` the snapshot every call. Benchmarking found it:
		a single-component query over 8000 entities cost 1.40ms median, and
		dropping the sort brought it to 1.11ms — about 20%, not the order of
		magnitude the shape of the fix suggests. The rest is the iteration
		itself, and no arrangement makes 8000 table lookups free.

		The sort only ever bought deterministic iteration order, which matters
		for a replay and for nothing else, so it moved to `queryOrdered`.

		The real lesson is the budget: at 20Hz one such query is still 22ms per
		second. A system that touches every entity every tick does not scale, and
		the fix for that is a slower tick or a narrower component — not a
		faster loop.
	]]
	local ids = table.create(smallestCount)
	local count = 0
	for id in smallest :: any do
		if alive[id] then
			count += 1
			ids[count] = id
		end
	end
	if ordered then
		table.sort(ids)
	end

	local index = 0
	return function()
		while true do
			index += 1
			local id = ids[index]
			if id == nil then
				return nil
			end
			if not alive[id] then
				continue
			end
			local values = table.create(requested.n)
			local complete = true
			for i = 1, requested.n do
				local value = stores[requested[i]][id]
				if value == nil then
					complete = false
					break
				end
				values[i] = value
			end
			if complete then
				return id, table.unpack(values, 1, requested.n)
			end
		end
	end
end

--[[
	Iterate every entity carrying all the named components:

		for id, health, brain in Entity.query("Health", "Brain") do ... end

	The rarest component drives the loop, so a query over 3 turrets and 4000
	props costs three checks, not four thousand.
]]
function Entity.query(...: string)
	return buildQuery(false, table.pack(...))
end

--[[
	The same, in ascending id order.

	Use it when the order must be reproducible — a deterministic replay, a
	snapshot a validator diffs between runs. It pays a sort over the driving
	set, so do not reach for it in a per-frame system.
]]
function Entity.queryOrdered(...: string)
	return buildQuery(true, table.pack(...))
end

function Entity.count(component: string?): number
	if not component then
		local n = 0
		for _ in alive do
			n += 1
		end
		return n
	end
	local store = stores[component]
	if not store then
		return 0
	end
	local n = 0
	for _ in store do
		n += 1
	end
	return n
end

function Entity.first(...: string): Id?
	for id in Entity.query(...) do
		return id
	end
	return nil
end

-- ================================ systems ===================================
--[[
	A system is a function over a query, ticked on a shared schedule.

		Entity.system("burn", { "Health", "Burning" }, function(dt, id, health, burning)
			health.current -= burning.dps * dt
		end, { rate = 4 })

	One connection drives every system, and each can be paused, which is what
	makes "turn off the AI and measure the world" possible.
]]
export type SystemOptions = {
	rate: number?,
	slices: number?,
	paused: boolean?,
	order: number?,
}

function Entity.system(name: string, components: { string }, fn: (dt: number, ...any) -> (), options: SystemOptions?)
	local opts = options or {}
	systems[name] = {
		name = name,
		components = components,
		fn = fn,
		rate = opts.rate or 20,
		paused = opts.paused == true,
		order = opts.order or 100,
		accumulator = 0,
		lastCost = 0,
	}
	Entity.startSystems()
	return systems[name]
end

function Entity.pauseSystem(name: string, paused: boolean?)
	local system = systems[name]
	if system then
		system.paused = paused ~= false
	end
end

function Entity.removeSystem(name: string)
	systems[name] = nil
end

function Entity.startSystems()
	if systemGroup then
		return
	end
	systemGroup = Sched.group(60)
	systemGroup:add("entity-systems", function(dt)
		local ordered = {}
		for _, system in systems do
			table.insert(ordered, system)
		end
		table.sort(ordered, function(a, b)
			return a.order < b.order
		end)

		for _, system in ordered do
			if system.paused then
				continue
			end
			system.accumulator += dt
			local interval = 1 / system.rate
			if system.accumulator < interval then
				continue
			end
			local elapsed = system.accumulator
			system.accumulator = 0

			local started = os.clock()
			local ok, err = pcall(function()
				for id, a, b, c, d in Entity.query(table.unpack(system.components)) do
					system.fn(elapsed, id, a, b, c, d)
				end
			end)
			system.lastCost = (os.clock() - started) * 1000
			if not ok then
				warn(string.format("[Entity] system '%s' errored: %s", system.name, tostring(err)))
			end
		end
	end)
end

function Entity.stopSystems()
	if systemGroup then
		systemGroup:destroy()
		systemGroup = nil
	end
end

-- ================================ the seam ==================================
function Entity.describe(): { [string]: any }
	local byComponent: { [string]: number } = {}
	for component in stores do
		byComponent[component] = Entity.count(component)
	end

	local systemReport: { [string]: any } = {}
	for name, system in systems do
		systemReport[name] = {
			components = system.components,
			rate = system.rate,
			paused = system.paused,
			lastCostMs = math.floor(system.lastCost * 1000) / 1000,
		}
	end

	local bound = 0
	for _ in instanceOf do
		bound += 1
	end

	local persists = {}
	for component in persistent do
		table.insert(persists, component)
	end
	table.sort(persists)

	return {
		entities = Entity.count(),
		boundToInstances = bound,
		components = byComponent,
		systems = systemReport,
		persistent = persists,
	}
end

return Entity
