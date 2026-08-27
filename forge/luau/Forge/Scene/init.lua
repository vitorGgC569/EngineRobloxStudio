--!strict
--[[
	Scene — a place expressed as data, not as code.

		local dungeon = Scene.create("Dungeon")
		dungeon:add("Prop.Torch", CFrame.new(10, 3, 0))
		dungeon:add("Enemy.Orc", CFrame.new(20, 3, 4), { tags = { "guard" } })
		dungeon:spawnPoint("entrance", CFrame.new(0, 4, 0))
		dungeon:load()

		local saved = dungeon:serialize()   -- JSON-able; store it anywhere
		Scene.fromTable(saved):load()

	Why this matters more than it looks
	-----------------------------------
	A world built by a `for` loop in a server script exists only while that
	script runs. Nothing can list it, diff it, hand-edit it, or hand it to a
	tool. The moment the same world is a table of placements, all four become
	possible — including an editor, which is only ever a UI over this data.

	Scenes also make unloading real. `scene:unload()` removes exactly what the
	scene created and nothing else, which is what lets a game move between
	areas without leaking the previous one into the next.
]]

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")

local Assets = require(script.Parent.Assets)
local Entity = require(script.Parent.Entity)
local Signal = require(script.Parent.Core.Signal)

local Scene = {}

Scene.loaded = Signal.new() -- (name)
Scene.unloaded = Signal.new() -- (name)

local scenes: { [string]: any } = {}
local active: string? = nil

local SceneClass = {}
SceneClass.__index = SceneClass

-- ================================ authoring =================================
function Scene.create(name: string): any
	local self = setmetatable({
		name = name,
		placements = {},
		spawnPoints = {},
		environment = nil,
		metadata = {},
		_instances = {},
		_entities = {},
		_container = nil,
		_isLoaded = false,
	}, SceneClass)
	scenes[name] = self
	return self
end

function Scene.get(name: string): any
	return scenes[name]
end

function Scene.names(): { string }
	local out = {}
	for name in scenes do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

--[[
	options:
	  name        override the instance name
	  tags        strings applied to the spawned entity
	  components  { Health = { max = 40 } } — spawns an entity with these
	  properties  set directly on the instance after building
	  scale       uniform scale for models that support it
]]
function SceneClass:add(assetId: string, cframe: CFrame, options: any?)
	local placement = {
		asset = assetId,
		cframe = cframe,
		options = options or {},
	}
	table.insert(self.placements, placement)
	if self._isLoaded then
		self:materialise(placement)
	end
	return placement
end

function SceneClass:addMany(assetId: string, cframes: { CFrame }, options: any?)
	for _, cframe in cframes do
		self:add(assetId, cframe, options)
	end
end

--[[
	Prefabs — a set piece placed many times.

	Real level design is not 480 loose props. It is "this campsite" placed nine
	times, and changing the campsite once. A flat placement list cannot express
	that, which is why a scene built by hand plateaus at about a hundred pieces
	before editing it becomes worse than rebuilding it.

		Scene.definePrefab("camp", {
			{ asset = "Prop.Tent",     cframe = CFrame.new(0, 0, 0) },
			{ asset = "Prop.Firepit",  cframe = CFrame.new(6, 0, 2) },
			{ asset = "Prop.Crate",    cframe = CFrame.new(-4, 0, 3), options = { tags = { "loot" } } },
		})

		scene:addPrefab("camp", CFrame.new(120, 30, -40))

	Expansion is by composition, not by reference: the prefab's parts become
	real placements tagged with a group id. That keeps streaming, the editor and
	serialisation working on one flat list, while `scene:group(id)` still moves
	or deletes the whole piece.
]]
local prefabs: { [string]: { any } } = {}

function Scene.definePrefab(name: string, parts: { any })
	prefabs[name] = parts
end

function Scene.prefabNames(): { string }
	local out = {}
	for name in prefabs do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

local nextGroup = 0

function SceneClass:addPrefab(name: string, cframe: CFrame, options: any?): (string?, { any })
	local parts = prefabs[name]
	if not parts then
		warn(string.format("[Scene] no prefab named '%s'", name))
		return nil, {}
	end
	nextGroup += 1
	local groupId = string.format("%s#%d", name, nextGroup)

	local created = {}
	for _, part in parts do
		local merged = {}
		for key, value in (part.options or {}) do
			merged[key] = value
		end
		for key, value in (options or {}) do
			merged[key] = value
		end
		merged.group = groupId
		merged.prefab = name

		local placement = self:add(part.asset, cframe * (part.cframe or CFrame.new()), merged)
		table.insert(created, placement)
	end
	return groupId, created
end

function SceneClass:group(groupId: string): { any }
	local out = {}
	for _, placement in self.placements do
		if placement.options and placement.options.group == groupId then
			table.insert(out, placement)
		end
	end
	return out
end

function SceneClass:groups(): { string }
	local seen: { [string]: boolean } = {}
	for _, placement in self.placements do
		local group = placement.options and placement.options.group
		if group then
			seen[group] = true
		end
	end
	local out = {}
	for group in seen do
		table.insert(out, group)
	end
	table.sort(out)
	return out
end

-- Move a whole placed prefab. The editor calls this when the selection is part
-- of a group, so dragging one tent does not tear the camp apart.
function SceneClass:moveGroup(groupId: string, delta: Vector3)
	for _, placement in self:group(groupId) do
		placement.cframe = placement.cframe + delta
		if placement._instance then
			if placement._instance:IsA("Model") then
				placement._instance:PivotTo(placement.cframe)
			elseif placement._instance:IsA("BasePart") then
				placement._instance.CFrame = placement.cframe
			end
		end
	end
end

function SceneClass:removeGroup(groupId: string): number
	local removed = 0
	for index = #self.placements, 1, -1 do
		local placement = self.placements[index]
		if placement.options and placement.options.group == groupId then
			self:dematerialise(placement)
			table.remove(self.placements, index)
			removed += 1
		end
	end
	return removed
end

function SceneClass:spawnPoint(id: string, cframe: CFrame)
	self.spawnPoints[id] = cframe
	return cframe
end

function SceneClass:getSpawnPoint(id: string?): CFrame?
	if id then
		return self.spawnPoints[id]
	end
	for _, cframe in self.spawnPoints do
		return cframe
	end
	return nil
end

-- Lighting/atmosphere applied on load and restored on unload.
function SceneClass:setEnvironment(settings: any)
	self.environment = settings
end

function SceneClass:count(): number
	return #self.placements
end

-- ================================ loading ===================================
-- Public because Streaming drives placements one at a time rather than
-- loading a whole scene at once.
--[[
	Asset ids beginning `prop:` come from the baked store catalogue.

	Placement was expressible only for things registered in `Assets`, so a
	catalogued prop -- the 30-odd rocks, crates and machines read out of real
	store models -- could be generated in a loop and never *placed*. The report
	put it exactly: the platform knows how to generate and not how to put that
	rock in that spot.

	`prop:` is the whole bridge. `scene:add("prop:rock", CFrame.new(...))` now
	means what it looks like, persists through `toJson` like any other
	placement, and comes back on load.

	Required inside the function rather than at the top: `Catalog` pulls in
	`StoreProps`, which builds lookup tables at load, and a scene that never
	places a prop should not pay for that.
]]
local PROP_PREFIX = "prop:"

function SceneClass:materialise(placement: any)
	local opts = placement.options

	local instance
	if string.sub(placement.asset, 1, #PROP_PREFIX) == PROP_PREFIX then
		local Prop = require(script.Parent.Catalog).Prop
		instance = Prop.build(string.sub(placement.asset, #PROP_PREFIX + 1),
			placement.cframe, {
				parent = self._container,
				scale = opts.scale,
				targetHeight = opts.targetHeight,
				targetSize = opts.targetSize,
				anchored = opts.anchored,
				canCollide = opts.canCollide,
			})
		if not instance then
			warn(string.format("[Scene] no baked prop for %q", placement.asset))
		end
	else
		instance = Assets.spawn(placement.asset, placement.cframe, self._container, opts)
	end

	if not instance then
		return nil
	end

	if opts.name then
		instance.Name = opts.name
	end
	if opts.properties then
		for property, value in opts.properties do
			local ok = pcall(function()
				(instance :: any)[property] = value
			end)
			if not ok then
				warn(string.format("[Scene] could not set %s on %s", property, instance.Name))
			end
		end
	end

	table.insert(self._instances, instance)
	placement._instance = instance

	-- An entity is created only when the placement asks for one. A torch does
	-- not need to be an entity; an orc does.
	if opts.components or opts.tags or opts.entity then
		local id = Entity.create({
			name = opts.name or placement.asset,
			instance = instance,
			tags = opts.tags,
			components = opts.components,
		})
		table.insert(self._entities, id)
		placement._entity = id
	end

	return instance
end

-- Remove one placement's instance and entity, leaving the placement itself in
-- the scene so it can come back. This is what unloading a chunk means.
function SceneClass:dematerialise(placement: any)
	if placement._entity then
		Entity.destroy(placement._entity, false)
		placement._entity = nil
	end
	if placement._instance then
		if placement._instance.Parent then
			placement._instance:Destroy()
		end
		for index = #self._instances, 1, -1 do
			if self._instances[index] == placement._instance then
				table.remove(self._instances, index)
				break
			end
		end
		placement._instance = nil
	end
end

function SceneClass:load(parent: Instance?): any
	if self._isLoaded then
		return self
	end

	local container = Instance.new("Folder")
	container.Name = "Scene_" .. self.name
	container.Parent = parent or Workspace
	self._container = container

	if self.environment then
		self._savedEnvironment = {}
		for property, value in self.environment do
			local ok, previous = pcall(function()
				return (Lighting :: any)[property]
			end)
			if ok then
				self._savedEnvironment[property] = previous
				pcall(function()
					(Lighting :: any)[property] = value
				end)
			end
		end
	end

	-- A streamed scene materialises nothing here: the streamer decides what
	-- exists, based on where people are.
	if not self.streamed then
		for _, placement in self.placements do
			self:materialise(placement)
		end
	end

	self._isLoaded = true
	active = self.name
	Scene.loaded:Fire(self.name)
	return self
end

function SceneClass:unload()
	if not self._isLoaded then
		return
	end

	for _, id in self._entities do
		Entity.destroy(id, false)
	end
	table.clear(self._entities)

	if self._container then
		self._container:Destroy()
		self._container = nil
	end
	table.clear(self._instances)

	for _, placement in self.placements do
		placement._instance = nil
		placement._entity = nil
	end

	if self._savedEnvironment then
		for property, value in self._savedEnvironment do
			pcall(function()
				(Lighting :: any)[property] = value
			end)
		end
		self._savedEnvironment = nil
	end

	self._isLoaded = false
	if active == self.name then
		active = nil
	end
	Scene.unloaded:Fire(self.name)
end

function SceneClass:isLoaded(): boolean
	return self._isLoaded
end

function SceneClass:container(): Instance?
	return self._container
end

-- Only one scene at a time: the common case for areas, dungeons and lobbies.
function Scene.activate(name: string, parent: Instance?): any
	if active and active ~= name then
		local current = scenes[active]
		if current then
			current:unload()
		end
	end
	local scene = scenes[name]
	if not scene then
		error(string.format("[Scene] no scene named '%s'", name), 2)
	end
	return scene:load(parent)
end

function Scene.activeName(): string?
	return active
end

-- =============================== persistence ================================
local function cframeToArray(cframe: CFrame): { number }
	return { cframe:GetComponents() }
end

local function arrayToCFrame(values: { number }): CFrame
	return CFrame.new(table.unpack(values, 1, 12))
end

--[[
	A plain table: safe for JSONEncode, a DataStore, a file, or a tool that
	never runs inside Roblox.
]]
function SceneClass:serialize(): { [string]: any }
	local placements = {}
	for _, placement in self.placements do
		local options = {}
		for key, value in placement.options do
			if key ~= "properties" then
				options[key] = value
			end
		end
		table.insert(placements, {
			asset = placement.asset,
			cframe = cframeToArray(placement.cframe),
			options = options,
		})
	end

	local spawnPoints = {}
	for id, cframe in self.spawnPoints do
		spawnPoints[id] = cframeToArray(cframe)
	end

	return {
		version = 1,
		name = self.name,
		metadata = self.metadata,
		environment = self.environment,
		placements = placements,
		spawnPoints = spawnPoints,
	}
end

function SceneClass:toJson(): string
	return HttpService:JSONEncode(self:serialize())
end

function Scene.fromTable(data: { [string]: any }): any
	local scene = Scene.create(data.name or "unnamed")
	scene.metadata = data.metadata or {}
	scene.environment = data.environment

	for _, placement in (data.placements or {}) do
		scene:add(placement.asset, arrayToCFrame(placement.cframe), placement.options)
	end
	for id, values in (data.spawnPoints or {}) do
		scene:spawnPoint(id, arrayToCFrame(values))
	end
	return scene
end

function Scene.fromJson(text: string): any
	return Scene.fromTable(HttpService:JSONDecode(text))
end

--[[
	Capture what is already in the world as a scene.

	This is the bridge from hand-built to data-driven: block something out in
	Studio, capture it, and from then on it is a table an agent can edit.
	Instances carry a `ForgeAsset` attribute naming what they are; anything
	without one cannot be captured, because the engine has no id for it.
]]
function Scene.capture(name: string, root: Instance): any
	local scene = Scene.create(name)
	local skipped = 0

	for _, child in root:GetChildren() do
		local assetId = child:GetAttribute("ForgeAsset")
		if type(assetId) == "string" then
			local cframe
			if child:IsA("Model") then
				cframe = child:GetPivot()
			elseif child:IsA("BasePart") then
				cframe = child.CFrame
			end
			if cframe then
				scene:add(assetId, cframe, { name = child.Name })
			end
		else
			skipped += 1
		end
	end

	scene.metadata.capturedFrom = root:GetFullName()
	scene.metadata.skipped = skipped
	if skipped > 0 then
		warn(string.format("[Scene] captured '%s', skipped %d instances with no ForgeAsset attribute", name, skipped))
	end
	return scene
end

-- Check every asset a scene references before trying to load it.
function SceneClass:validate(): { [string]: any }
	local references = {}
	for _, placement in self.placements do
		table.insert(references, placement.asset)
	end
	return Assets.validate(references)
end

function Scene.describe(): { [string]: any }
	local report: { [string]: any } = {}
	for name, scene in scenes do
		report[name] = {
			placements = #scene.placements,
			loaded = scene._isLoaded,
			spawnPoints = (function()
				local n = 0
				for _ in scene.spawnPoints do
					n += 1
				end
				return n
			end)(),
		}
	end
	return { active = active, scenes = report, prefabs = Scene.prefabNames() }
end

return Scene
