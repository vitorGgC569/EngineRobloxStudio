--!strict
-- DataModel introspection: the commands that stop Roblox from being a black box.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local findSnapshots: { [string]: any } = {}

local Config = require(script.Parent.Parent.Config)
local Errors = require(script.Parent.Parent.Errors)
local Refs = require(script.Parent.Parent.Refs)
local Resolve = require(script.Parent.Parent.Resolve)
local Serialize = require(script.Parent.Parent.Serialize)

local DataModelCommands = {}

local function tagsOf(instance: Instance): { string }
	local ok, tags = pcall(function()
		return CollectionService:GetTags(instance)
	end)
	return if ok then tags else {}
end

local function attributesOf(instance: Instance): { [string]: any }
	local result = {}
	local ok, attributes = pcall(function()
		return instance:GetAttributes()
	end)
	if ok then
		for key, value in pairs(attributes) do
			result[key] = Serialize.value(value)
		end
	end
	return result
end

--- dm.tree: a bounded slice of the hierarchy.
---
--- Bounded on purpose. An unbounded tree of a real place is hundreds of
--- thousands of nodes and would be useless to an agent and hostile to Studio.
function DataModelCommands.tree(params: { [string]: any }): any
	local root = Resolve.instance(params.path)
	local maxDepth = math.min(tonumber(params.depth) or 2, Config.MAX_TREE_DEPTH)
	local maxNodes = math.min(tonumber(params.maxNodes) or 400, Config.MAX_TREE_NODES)
	local includeAttributes = params.includeAttributes == true
	local classFilter = params.classFilter

	local nodeCount = 0
	local truncated = false

	local function describe(instance: Instance, depth: number): any
		nodeCount += 1
		local children = instance:GetChildren()
		local node: { [string]: any } = {
			name = instance.Name,
			className = instance.ClassName,
			path = instance:GetFullName(),
			childCount = #children,
		}

		local tags = tagsOf(instance)
		if #tags > 0 then
			node.tags = tags
		end
		if includeAttributes then
			local attributes = attributesOf(instance)
			if next(attributes) ~= nil then
				node.attributes = attributes
			end
		end
		if instance:IsA("BasePart") then
			node.position = Serialize.roundVector(instance.Position, 2)
			node.size = Serialize.roundVector(instance.Size, 2)
		end

		if depth >= maxDepth or #children == 0 then
			if #children > 0 then
				node.childrenOmitted = #children
			end
			return node
		end

		local serialized = {}
		for _, child in ipairs(children) do
			if nodeCount >= maxNodes then
				truncated = true
				break
			end
			if classFilter == nil or child:IsA(classFilter) then
				table.insert(serialized, describe(child, depth + 1))
			end
		end
		node.children = serialized
		return node
	end

	local tree = describe(root, 0)
	return {
		root = root:GetFullName(),
		nodes = nodeCount,
		truncated = truncated,
		maxDepth = maxDepth,
		tree = tree,
	}
end

--- dm.properties: read named properties plus attributes and tags.
---
--- Luau has no property reflection, so each read is a guarded access. A
--- property that cannot be read comes back as an explicit error entry rather
--- than as nil, so "unreadable" and "unset" stay distinguishable.
function DataModelCommands.properties(params: { [string]: any }): any
	local instance = Resolve.instance(Errors.expect(params, "path", "string"))
	local requested = params.properties

	local values: { [string]: any } = {}
	local unreadable: { [string]: string } = {}

	if typeof(requested) == "table" and #requested > 0 then
		for _, name in ipairs(requested) do
			local ok, value = pcall(function()
				return (instance :: any)[name]
			end)
			if ok then
				values[name] = Serialize.value(value)
			else
				unreadable[name] = tostring(value)
			end
		end
	else
		-- No explicit list: return the properties that matter for QA on this class.
		local defaults = { "Name", "ClassName", "Parent" }
		if instance:IsA("BasePart") then
			defaults = {
				"Name", "ClassName", "Position", "Size", "Orientation", "CFrame",
				"Anchored", "CanCollide", "CanTouch", "Transparency", "Material",
				"Color", "Massless", "CollisionGroup", "Shape",
			}
		elseif instance:IsA("GuiObject") then
			defaults = {
				"Name", "ClassName", "Visible", "Position", "Size", "AnchorPoint",
				"ZIndex", "BackgroundTransparency", "ClipsDescendants", "AbsolutePosition", "AbsoluteSize",
			}
			if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
				table.insert(defaults, "Text")
				table.insert(defaults, "TextScaled")
				table.insert(defaults, "TextSize")
				table.insert(defaults, "TextTransparency")
			end
		elseif instance:IsA("Humanoid") then
			defaults = { "Name", "ClassName", "Health", "MaxHealth", "WalkSpeed", "JumpPower", "FloorMaterial", "RigType" }
		elseif instance:IsA("ProximityPrompt") then
			defaults = { "Name", "ClassName", "ActionText", "ObjectText", "Enabled", "MaxActivationDistance", "HoldDuration", "RequiresLineOfSight" }
		elseif instance:IsA("Lighting") then
			defaults = { "Name", "ClassName", "Ambient", "Brightness", "ClockTime", "GlobalShadows", "OutdoorAmbient", "FogEnd", "FogStart", "Technology" }
		end

		for _, name in ipairs(defaults) do
			local ok, value = pcall(function()
				return (instance :: any)[name]
			end)
			if ok then
				values[name] = Serialize.value(value)
			end
		end
	end

	return {
		path = instance:GetFullName(),
		className = instance.ClassName,
		properties = values,
		unreadable = unreadable,
		attributes = attributesOf(instance),
		tags = tagsOf(instance),
	}
end

--- dm.find: query the hierarchy by class, tag or name.
function DataModelCommands.find(params: { [string]: any }): any
	local rootPath = params.root
	local className = params.className
	local tag = params.tag
	local name = params.name
	local namePattern = params.namePattern
	local limit = math.clamp(tonumber(params.limit) or 200, 1, Config.MAX_FIND_RESULTS)

	if className == nil and tag == nil and name == nil and namePattern == nil then
		Errors.raise(Errors.BAD_PARAMS, "dm.find needs at least one of className, tag, name or namePattern")
	end

	-- string.match throws on a malformed pattern such as "(". Check once, before
	-- any instance is resolved, so the command returns E_BAD_PARAMS instead of
	-- crashing mid-walk. Nil still means no name filter.
	local nameNeedle: string? = nil
	if namePattern ~= nil then
		local valid = pcall(function()
			string.match("", namePattern)
		end)
		if not valid then
			Errors.raise(Errors.BAD_PARAMS, "namePattern is not a valid Luau pattern")
		end
		nameNeedle = namePattern
	end

	local candidates: { Instance }
	if tag ~= nil then
		-- Tag lookup is indexed by the engine; never walk the tree for it.
		candidates = CollectionService:GetTagged(tag)
	else
		local root = Resolve.instance(rootPath or "game.Workspace")
		candidates = root:GetDescendants()
	end

	local root: Instance? = if rootPath ~= nil then Resolve.instance(rootPath) else nil
	local matched: { { instance: Instance, entry: { [string]: any } } } = {}
	local scanned = 0

	for _, instance in ipairs(candidates) do
		scanned += 1
		local ok = true
		if className ~= nil and not instance:IsA(className) then
			ok = false
		end
		if ok and name ~= nil and instance.Name ~= name then
			ok = false
		end
		if ok and nameNeedle ~= nil and not string.match(instance.Name, nameNeedle) then
			ok = false
		end
		if ok and root ~= nil and tag ~= nil and not instance:IsDescendantOf(root) then
			ok = false
		end
		if ok then
			if #matched >= 20000 then
				Errors.raise(Errors.BAD_PARAMS, "query exceeds 20000 matches; narrow its root or filters")
			end
			local entry: { [string]: any } = {
				path = instance:GetFullName(),
				-- Paths collide between same-named siblings; refs do not.
				ref = Refs.of(instance),
				name = instance.Name,
				className = instance.ClassName,
			}
			if instance:IsA("BasePart") then
				entry.position = Serialize.roundVector(instance.Position, 2)
				entry.size = Serialize.roundVector(instance.Size, 2)
				entry.anchored = instance.Anchored
				entry.canCollide = instance.CanCollide
			end
			table.insert(matched, { instance = instance, entry = entry })
		end
	end

	local nested = 0
	if params.topLevelOnly == true then
		-- A name pattern like "^Plot" matches PlotA and its PlotBorder children.
		-- For "the set of plots" the caller wants the outermost matches only.
		local kept = {}
		for _, candidate in ipairs(matched) do
			local isNested = false
			for _, other in ipairs(matched) do
				if other.instance ~= candidate.instance and candidate.instance:IsDescendantOf(other.instance) then
					isNested = true
					break
				end
			end
			if isNested then
				nested += 1
			else
				table.insert(kept, candidate)
			end
		end
		matched = kept
	end

	table.sort(matched, function(a, b) return a.entry.ref < b.entry.ref end)
	local signature, all = {}, {}
	for _, candidate in ipairs(matched) do
		table.insert(signature, candidate.entry.ref .. "\0" .. candidate.entry.path)
		table.insert(all, candidate.entry)
	end
	local query = { className = className, tag = tag, name = name, namePattern = namePattern,
		root = rootPath, topLevelOnly = params.topLevelOnly == true }
	local queryKey = HttpService:JSONEncode({className or false,tag or false,name or false,
		namePattern or false,rootPath or false,params.topLevelOnly == true})
	local fingerprint = table.concat(signature, "\n")
	local now = os.clock()
	for id, snapshot in pairs(findSnapshots) do
		if now - snapshot.created > 120 then findSnapshots[id] = nil end
	end
	local id, offset, snapshot
	if params.cursor then
		local rawOffset
		id, rawOffset = string.match(params.cursor, "^([%w%-]+):(%d+)$")
		offset = tonumber(rawOffset)
		snapshot = id and findSnapshots[id]
		if not snapshot or not offset or offset < 1 or offset > #snapshot.results
			or snapshot.query ~= queryKey or snapshot.fingerprint ~= fingerprint then
			Errors.raise(Errors.BAD_PARAMS, "query cursor is expired, changed or belongs to another session; restart enumeration")
		end
	else
		local count, oldestId, oldest = 0, nil, math.huge
		for key, value in pairs(findSnapshots) do
			count += 1
			if value.created < oldest then oldestId, oldest = key, value.created end
		end
		if count >= 8 and oldestId then findSnapshots[oldestId] = nil end
		id, offset = HttpService:GenerateGUID(false), 1
		snapshot = {created=now,query=queryKey,fingerprint=fingerprint,results=all}
		findSnapshots[id] = snapshot
	end
	local matches = {}
	for index = offset, math.min(offset + limit - 1, #snapshot.results) do
		table.insert(matches, snapshot.results[index])
	end
	local nextOffset = offset + #matches
	local hasMore = nextOffset <= #snapshot.results
	return {
		query = query, scanned = scanned, matched = #matches, totalMatched = #snapshot.results,
		nestedDropped = nested, truncated = hasMore, results = matches,
		snapshotId = id, snapshotAgeSeconds = now - snapshot.created,
		nextCursor = if hasMore then id .. ":" .. tostring(nextOffset) else nil,
	}

end

return DataModelCommands
