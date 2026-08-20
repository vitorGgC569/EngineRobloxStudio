--!strict
--[[
	Assets — one way to name and produce content.

		Assets.spawn("Enemy.Orc", CFrame.new(0, 5, 0))
		Assets.spawn("Prop.Barrel", cframe)
		local sword = Assets.build("Weapon.Sword")

	Without this every game invents its own loading: one system clones from
	ReplicatedStorage, another builds a rig from a table, a third has ids baked
	into an `if` chain. Then nothing can be listed, nothing can be preloaded,
	and a missing asset is a nil three frames later instead of a named error.

	Three things an asset id can resolve to, and Assets does not care which:

	  a definition   a plain table (stats, config)
	  a template     an Instance in the tree, cloned on demand
	  a builder      a function that constructs it (procedural rigs, props)

	Namespaces
	----------
	An id is `Namespace.Name`, or `Namespace.Group.Name`. The namespace picks
	the producer, so registering a producer once teaches the engine how to make
	every asset of that kind:

		Assets.producer("Enemy", function(id, def) return Rig.build(def.rig) end)
		Assets.register("Enemy.Orc", { rig = { scale = 1.2, shape = "biped" } })

	Missing assets never crash. They log once, and `spawn` returns a visible
	magenta placeholder — because a silent nil is how a level ends up with
	invisible holes nobody notices until a player falls through one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Signal = require(script.Parent.Core.Signal)

local Assets = {}

Assets.registered = Signal.new() -- (id)
Assets.missing = Signal.new() -- (id)

local definitions: { [string]: any } = {}
local producers: { [string]: (id: string, definition: any, options: any) -> any } = {}
local templates: { [string]: Instance } = {}
local warned: { [string]: boolean } = {}
local stats = { built = 0, cloned = 0, missing = 0 }

Assets.config = {
	placeholderColor = Color3.fromRGB(255, 0, 200),
	placeholderSize = Vector3.new(3, 3, 3),
	warnOnMissing = true,
}

local function namespaceOf(id: string): string
	local dot = string.find(id, ".", 1, true)
	return dot and string.sub(id, 1, dot - 1) or id
end

-- ============================== registration ================================
function Assets.register(id: string, definition: any)
	assert(type(id) == "string" and #id > 0, "[Assets] id must be a non-empty string")
	definitions[id] = definition
	Assets.registered:Fire(id)
	return definition
end

function Assets.registerMany(namespace: string, entries: { [string]: any })
	for name, definition in entries do
		Assets.register(namespace .. "." .. name, definition)
	end
end

function Assets.producer(namespace: string, fn: (id: string, definition: any, options: any) -> any)
	producers[namespace] = fn
end

--[[
	Register an Instance tree as templates. Every descendant becomes an id built
	from its path relative to the root:

		ReplicatedStorage.Content.Prop.Barrel  ->  "Prop.Barrel"

	This is how hand-modelled content enters the engine without any code.
]]
function Assets.mountInstances(root: Instance, namespace: string?)
	local prefix = namespace and (namespace .. ".") or ""
	for _, child in root:GetChildren() do
		local id = prefix .. child.Name
		if child:IsA("Folder") then
			Assets.mountInstances(child, id)
		else
			templates[id] = child
			Assets.registered:Fire(id)
		end
	end
end

--[[
	Register a tree of ModuleScripts as definitions:

		content/Enemy/Orc.lua  ->  "Enemy.Orc"

	A module that errors is skipped and named, rather than taking the whole
	load down with it.
]]
function Assets.mountModules(root: Instance, namespace: string?)
	local prefix = namespace and (namespace .. ".") or ""
	for _, child in root:GetChildren() do
		local id = prefix .. child.Name
		if child:IsA("ModuleScript") then
			local ok, definition = pcall(require, child)
			if ok then
				Assets.register(id, definition)
			else
				warn(string.format("[Assets] '%s' failed to load: %s", id, tostring(definition)))
			end
		elseif child:IsA("Folder") then
			Assets.mountModules(child, id)
		end
	end
end

-- ================================ lookup ====================================
function Assets.exists(id: string): boolean
	return definitions[id] ~= nil or templates[id] ~= nil
end

function Assets.get(id: string): any
	return definitions[id]
end

-- Like get, but a missing id is an error with the id in the message rather
-- than a nil that fails somewhere else entirely.
function Assets.expect(id: string): any
	local definition = definitions[id]
	if definition == nil then
		error(string.format("[Assets] no definition registered for '%s'", id), 2)
	end
	return definition
end

function Assets.ids(namespace: string?): { string }
	local out = {}
	for id in definitions do
		if not namespace or namespaceOf(id) == namespace then
			table.insert(out, id)
		end
	end
	for id in templates do
		if (not namespace or namespaceOf(id) == namespace) and not definitions[id] then
			table.insert(out, id)
		end
	end
	table.sort(out)
	return out
end

function Assets.namespaces(): { string }
	local seen: { [string]: boolean } = {}
	for id in definitions do
		seen[namespaceOf(id)] = true
	end
	for id in templates do
		seen[namespaceOf(id)] = true
	end
	local out = {}
	for name in seen do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- ================================= pooling ==================================
--[[
	Recycling built instances.

	Streaming makes and unmakes the same reed clump hundreds of times as a
	player walks a shoreline. Each cycle is an allocation, a parent change and
	eventually a garbage collection pause, all for a thing that is identical to
	the one just thrown away.

	A pool is opt-in per asset because it is only correct for products with no
	per-instance state. Pool a rock; never pool something carrying an entity.
]]
local pools: { [string]: { Instance } } = {}
local poolLimits: { [string]: number } = {}
local poolStats = { reused = 0, recycled = 0, evicted = 0 }

function Assets.pool(id: string, limit: number?)
	poolLimits[id] = limit or 24
	pools[id] = pools[id] or {}
end

function Assets.isPooled(id: string): boolean
	return poolLimits[id] ~= nil
end

--[[
	Hand an instance back instead of destroying it.

	Returns true if it was kept. A caller that ignores the result and also
	destroys the instance will double-free, so `Scene` checks the return.
]]
function Assets.recycle(id: string, instance: Instance): boolean
	local limit = poolLimits[id]
	if not limit then
		return false
	end
	local pool = pools[id]
	if #pool >= limit then
		poolStats.evicted += 1
		return false
	end
	instance.Parent = nil
	table.insert(pool, instance)
	poolStats.recycled += 1
	return true
end

local function takeFromPool(id: string): Instance?
	local pool = pools[id]
	if not pool or #pool == 0 then
		return nil
	end
	poolStats.reused += 1
	return table.remove(pool)
end

-- Build ahead of time, so the first sight of a thing is not also the first
-- time it is constructed.
function Assets.warm(id: string, count: number)
	Assets.pool(id, math.max(poolLimits[id] or 0, count))
	for _ = 1, count do
		local product = Assets.build(id)
		if typeof(product) == "Instance" then
			Assets.recycle(id, product :: Instance)
		end
	end
end

--[[
	Memory accounting.

	Roblox exposes no per-instance cost, so this counts descendants, which
	tracks real memory closely enough to answer the only question that matters:
	which asset is responsible for the world getting heavy.
]]
local costs: { [string]: number } = {}

function Assets.costOf(id: string): number
	return costs[id] or 0
end

function Assets.heaviest(limit: number?): { any }
	local out = {}
	for id, cost in costs do
		table.insert(out, { id = id, parts = cost })
	end
	table.sort(out, function(a, b)
		return a.parts > b.parts
	end)
	local trimmed = {}
	for index = 1, math.min(limit or 10, #out) do
		table.insert(trimmed, out[index])
	end
	return trimmed
end

function Assets.dropPools(): number
	local dropped = 0
	for id, pool in pools do
		for _, instance in pool do
			instance:Destroy()
			dropped += 1
		end
		pools[id] = {}
	end
	return dropped
end

-- ============================== production ==================================
local function placeholder(id: string): Instance
	local part = Instance.new("Part")
	part.Name = "MissingAsset_" .. id
	part.Size = Assets.config.placeholderSize
	part.Color = Assets.config.placeholderColor
	part.Material = Enum.Material.Neon
	part.Anchored = true

	local label = Instance.new("BillboardGui")
	label.Size = UDim2.fromOffset(200, 40)
	label.AlwaysOnTop = true
	label.StudsOffset = Vector3.new(0, 2, 0)
	label.Parent = part

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = "missing: " .. id
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextScaled = true
	text.Parent = label

	return part
end

--[[
	Produce the thing named by `id`. Resolution order:

	  1. a producer registered for the namespace
	  2. a template instance, cloned
	  3. a definition that is itself an Instance, cloned
	  4. a visible placeholder
]]
function Assets.build(id: string, options: any?): any
	local opts = options or {}

	local pooled = takeFromPool(id)
	if pooled then
		return pooled
	end

	local definition = definitions[id]
	local producer = producers[namespaceOf(id)]

	if producer and definition ~= nil then
		local ok, product = pcall(producer, id, definition, opts)
		if ok then
			stats.built += 1
			if typeof(product) == "Instance" and costs[id] == nil then
				costs[id] = #(product :: Instance):GetDescendants() + 1
			end
			return product
		end
		warn(string.format("[Assets] producer for '%s' errored: %s", id, tostring(product)))
	end

	local template = templates[id] or (typeof(definition) == "Instance" and definition or nil)
	if template then
		stats.cloned += 1
		return (template :: Instance):Clone()
	end

	if definition ~= nil and not producer then
		-- a plain data asset: hand it back as-is
		return definition
	end

	stats.missing += 1
	if Assets.config.warnOnMissing and not warned[id] then
		warned[id] = true
		warn(string.format("[Assets] nothing registered for '%s'", id))
	end
	Assets.missing:Fire(id)
	return placeholder(id)
end

--[[
	Build and place in one call. Returns the instance, or nil if the asset is
	pure data.
]]
function Assets.spawn(id: string, cframe: CFrame?, parent: Instance?, options: any?): Instance?
	local product = Assets.build(id, options)
	if typeof(product) ~= "Instance" then
		return nil
	end

	local instance = product :: Instance
	if cframe then
		if instance:IsA("Model") then
			instance:PivotTo(cframe)
		elseif instance:IsA("BasePart") then
			instance.CFrame = cframe
		end
	end
	instance.Parent = parent or Workspace
	return instance
end

-- Warms the caches and reports what is missing before a player ever sees it.
function Assets.preload(ids: { string }): { string }
	local absent = {}
	for _, id in ids do
		if not Assets.exists(id) then
			table.insert(absent, id)
		end
	end
	if #absent > 0 then
		warn(string.format("[Assets] preload found %d missing: %s", #absent, table.concat(absent, ", ")))
	end
	return absent
end

-- Everything referenced by name anywhere in a table, checked in one pass.
-- Point it at a scene or a loot table before shipping.
function Assets.validate(references: { string }): { [string]: any }
	local missing = {}
	for _, id in references do
		if not Assets.exists(id) then
			table.insert(missing, id)
		end
	end
	return { checked = #references, missing = missing, ok = #missing == 0 }
end

function Assets.describe(): { [string]: any }
	local counts: { [string]: number } = {}
	for _, namespace in Assets.namespaces() do
		counts[namespace] = #Assets.ids(namespace)
	end
	local producerNames = {}
	for name in producers do
		table.insert(producerNames, name)
	end
	table.sort(producerNames)

	return {
		namespaces = counts,
		producers = producerNames,
		totalIds = #Assets.ids(),
		built = stats.built,
		cloned = stats.cloned,
		missing = stats.missing,
		pooled = (function()
			local n = 0
			for _, pool in pools do
				n += #pool
			end
			return n
		end)(),
		reusedFromPool = poolStats.reused,
		heaviest = Assets.heaviest(5),
	}
end

return Assets
