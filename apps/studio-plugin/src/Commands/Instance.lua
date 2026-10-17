--!strict
-- DataModel mutation as typed primitives.
--
-- Until now an agent could *read* the DataModel through `dm.*` and could only
-- *write* it through `bridge.exec` -- arbitrary Luau. That is the wrong shape
-- for a platform. Arbitrary code has no schema, so nothing can validate it
-- before it runs, nothing can describe what it changed after it ran, and the
-- one command that can do anything becomes the command that does everything.
--
-- These are the primitives instead: create, update, delete, clone, and the
-- read accessors that pair with them. Every one declares its parameters, every
-- one reports what it touched, and every mutation is `at-most-once` because
-- creating an instance twice is not the same as creating it once.
--
-- Deliberately general. Nothing here knows what a plot, a conveyor or a card is;
-- a command that did would be a game feature living in the bridge.

local CollectionService = game:GetService("CollectionService")

local Config = require(script.Parent.Parent.Config)
local Errors = require(script.Parent.Parent.Errors)
local Refs = require(script.Parent.Parent.Refs)
local Resolve = require(script.Parent.Parent.Resolve)
local Serialize = require(script.Parent.Parent.Serialize)
local History = require(script.Parent.Parent.History)

local InstanceCommands = {}

--- How many instances one call may create or destroy.
---
--- A cap rather than a courtesy: an agent that miscomputes a loop bound should
--- get a refusal, not a place with 400,000 parts in it and a Studio that has to
--- be killed.
local MAX_BATCH = 256

--- Properties that change what an instance *is*, not how it looks.
--- Refused because renaming a class or reparenting into a service through a
--- property write produces failures that surface far from their cause.
local PROTECTED_PROPERTIES = table.freeze({
	ClassName = true,
	Parent = true,
	RobloxLocked = true,
	Archivable = true,
})

local function requireString(params: { [string]: any }, key: string): string
	local value = params[key]
	if type(value) ~= "string" or value == "" then
		Errors.raise("E_BAD_PARAMS", key .. " must be a non-empty string")
	end
	return value
end

--- Turn a JSON-shaped value into the Roblox datatype a property expects.
---
--- The wire carries JSON, so a Vector3 arrives as three numbers and a Color3 as
--- three more. Guessing from shape alone is ambiguous, so the caller tags the
--- value: `{ type = "Vector3", value = {1, 2, 3} }`. Plain scalars pass through
--- untagged because there is nothing to confuse them with.
local function coerce(raw: any, label: string): any
	if type(raw) ~= "table" then
		return raw
	end
	local kind = raw.type
	local value = raw.value
	if type(kind) ~= "string" then
		Errors.raise("E_BAD_PARAMS", label .. " must be a scalar or a {type, value} pair")
	end

	if kind == "Vector3" then
		if type(value) ~= "table" or #value ~= 3 then
			Errors.raise("E_BAD_PARAMS", label .. " Vector3 needs three numbers")
		end
		return Vector3.new(value[1], value[2], value[3])
	elseif kind == "Vector2" then
		if type(value) ~= "table" or #value ~= 2 then
			Errors.raise("E_BAD_PARAMS", label .. " Vector2 needs two numbers")
		end
		return Vector2.new(value[1], value[2])
	elseif kind == "Color3" then
		if type(value) ~= "table" or #value ~= 3 then
			Errors.raise("E_BAD_PARAMS", label .. " Color3 needs three 0..255 channels")
		end
		return Color3.fromRGB(value[1], value[2], value[3])
	elseif kind == "CFrame" then
		if type(value) ~= "table" or (#value ~= 3 and #value ~= 12) then
			Errors.raise("E_BAD_PARAMS", label .. " CFrame needs 3 or 12 numbers")
		end
		if #value == 3 then
			return CFrame.new(value[1], value[2], value[3])
		end
		return CFrame.new(table.unpack(value))
	elseif kind == "UDim2" then
		if type(value) ~= "table" or #value ~= 4 then
			Errors.raise("E_BAD_PARAMS", label .. " UDim2 needs four numbers")
		end
		return UDim2.new(value[1], value[2], value[3], value[4])
	elseif kind == "UDim" then
		if type(value) ~= "table" or #value ~= 2 then
			Errors.raise("E_BAD_PARAMS", label .. " UDim needs two numbers")
		end
		return UDim.new(value[1], value[2])
	elseif kind == "NumberRange" then
		if type(value) ~= "table" or #value ~= 2 then
			Errors.raise("E_BAD_PARAMS", label .. " NumberRange needs two numbers")
		end
		return NumberRange.new(value[1], value[2])
	elseif kind == "Enum" then
		-- `{ type = "Enum", value = "Material.Plastic" }`
		if type(value) ~= "string" then
			Errors.raise("E_BAD_PARAMS", label .. " Enum needs a \"Category.Member\" string")
		end
		local category, member = string.match(value, "^([%w_]+)%.([%w_]+)$")
		if category == nil or member == nil then
			Errors.raise("E_BAD_PARAMS", label .. " Enum must look like \"Material.Plastic\"")
		end
		local container = (Enum :: any)[category]
		if container == nil then
			Errors.raise("E_BAD_PARAMS", label .. " names an unknown Enum category: " .. category)
		end
		local item = container[member]
		if item == nil then
			Errors.raise("E_BAD_PARAMS", label .. " names an unknown Enum member: " .. value)
		end
		return item
	elseif kind == "Instance" then
		if type(value) ~= "string" then
			Errors.raise("E_BAD_PARAMS", label .. " Instance needs a ref or path string")
		end
		return Resolve.instance(value)
	end

	Errors.raise("E_BAD_PARAMS", label .. " has an unsupported type: " .. kind)
	return nil
end

local function applyProperties(instance: Instance, properties: any): { string }
	if properties == nil then
		return {}
	end
	if type(properties) ~= "table" then
		Errors.raise("E_BAD_PARAMS", "properties must be an object")
	end
	local applied: { string } = {}
	for name, raw in pairs(properties) do
		if type(name) ~= "string" then
			Errors.raise("E_BAD_PARAMS", "property names must be strings")
		end
		if PROTECTED_PROPERTIES[name] then
			Errors.raise("E_BAD_PARAMS", string.format(
				"%s cannot be set through instance.update; it changes what the instance is, "
				.. "not how it looks", name
			))
		end
		local value = coerce(raw, "properties." .. name)
		local ok, failure = pcall(function()
			(instance :: any)[name] = value
		end)
		if not ok then
			Errors.raise("E_BAD_PARAMS", string.format(
				"%s.%s could not be set: %s", instance.ClassName, name, tostring(failure)
			))
		end
		table.insert(applied, name)
	end
	table.sort(applied)
	return applied
end

local function applyTags(instance: Instance, tags: any): { string }
	if tags == nil then
		return {}
	end
	if type(tags) ~= "table" then
		Errors.raise("E_BAD_PARAMS", "tags must be an array of strings")
	end
	local applied: { string } = {}
	for _, tag in ipairs(tags) do
		if type(tag) ~= "string" or tag == "" then
			Errors.raise("E_BAD_PARAMS", "tags must be non-empty strings")
		end
		CollectionService:AddTag(instance, tag)
		table.insert(applied, tag)
	end
	return applied
end

local function applyAttributes(instance: Instance, attributes: any): { string }
	if attributes == nil then
		return {}
	end
	if type(attributes) ~= "table" then
		Errors.raise("E_BAD_PARAMS", "attributes must be an object")
	end
	local applied: { string } = {}
	for name, raw in pairs(attributes) do
		if type(name) ~= "string" then
			Errors.raise("E_BAD_PARAMS", "attribute names must be strings")
		end
		local ok, failure = pcall(function()
			instance:SetAttribute(name, coerce(raw, "attributes." .. name))
		end)
		if not ok then
			Errors.raise("E_BAD_PARAMS", string.format(
				"attribute %s could not be set: %s", name, tostring(failure)
			))
		end
		table.insert(applied, name)
	end
	table.sort(applied)
	return applied
end

local function describe(instance: Instance): { [string]: any }
	return {
		ref = Refs.of(instance),
		name = instance.Name,
		className = instance.ClassName,
		path = instance:GetFullName(),
	}
end

--- instance.create: make one instance, or a batch of them.
function InstanceCommands.create(params: { [string]: any }): any
	local className = requireString(params, "className")
	local parent = Resolve.instance(params.parent)
	local count = tonumber(params.count) or 1
	if count < 1 or count % 1 ~= 0 or count > MAX_BATCH then
		Errors.raise("E_BAD_PARAMS", string.format("count must be an integer between 1 and %d", MAX_BATCH))
	end

	return History.record("RQE instance.create", function()
		local created: { any } = {}
		for index = 1, count do
			local ok, instance = pcall(Instance.new, className)
			if not ok or instance == nil then
				Errors.raise("E_BAD_PARAMS", string.format(
					"%q is not a creatable class: %s", className, tostring(instance)
				))
			end
			if params.name ~= nil then
				instance.Name = requireString(params, "name")
				if count > 1 then
					instance.Name = instance.Name .. tostring(index)
				end
			end
			applyProperties(instance, params.properties)
			applyAttributes(instance, params.attributes)
			applyTags(instance, params.tags)
			-- Parented last. Setting properties on an instance already in the
			-- DataModel makes each write replicate separately and fires listeners
			-- against a half-built object.
			instance.Parent = parent
			table.insert(created, describe(instance))
		end

		return { created = created, count = #created, parent = describe(parent) }
	end)
end

--- instance.update: set properties, attributes and tags on an existing instance.
function InstanceCommands.update(params: { [string]: any }): any
	local instance = Resolve.instance(params.path)
	return History.record("RQE instance.update", function()
		local properties = applyProperties(instance, params.properties)
		local attributes = applyAttributes(instance, params.attributes)
		local tags = applyTags(instance, params.tags)

		local removedTags: { string } = {}
		if params.removeTags ~= nil then
			if type(params.removeTags) ~= "table" then
				Errors.raise("E_BAD_PARAMS", "removeTags must be an array of strings")
			end
			for _, tag in ipairs(params.removeTags) do
				CollectionService:RemoveTag(instance, tag)
				table.insert(removedTags, tag)
			end
		end

		return {
			instance = describe(instance),
			properties = properties,
			attributes = attributes,
			tags = tags,
			removedTags = removedTags,
		}
	end)
end

--- instance.delete: destroy an instance and report what went with it.
---
--- The descendant count is returned because `Destroy` on a model is not one
--- deletion, and an agent that thinks it removed a part when it removed a
--- district will not find out any other way.
function InstanceCommands.delete(params: { [string]: any }): any
	local instance = Resolve.instance(params.path)
	if instance == game or instance:IsA("ServiceProvider") then
		Errors.raise("E_BAD_PARAMS", "services and the DataModel root cannot be destroyed")
	end
	local descendants = #instance:GetDescendants()
	if descendants > MAX_BATCH then
		Errors.raise("E_BAD_PARAMS", string.format(
			"refusing to destroy %s: it holds %d descendants, above the %d safety limit; "
			.. "delete the subtree explicitly if that is intended",
			instance:GetFullName(), descendants, MAX_BATCH
		))
	end
	local record = describe(instance)
	return History.record("RQE instance.delete", function()
		instance:Destroy()
		return { destroyed = record, descendants = descendants }
	end)
end

--- instance.clone: copy an instance, optionally into a different parent.
function InstanceCommands.clone(params: { [string]: any }): any
	local source = Resolve.instance(params.path)
	if not source.Archivable then
		Errors.raise("E_BAD_PARAMS", source:GetFullName() .. " is not Archivable, so it cannot be cloned")
	end
	local parent = if params.parent ~= nil then Resolve.instance(params.parent) else source.Parent
	local count = tonumber(params.count) or 1
	if count < 1 or count % 1 ~= 0 or count > MAX_BATCH then
		Errors.raise("E_BAD_PARAMS", string.format("count must be an integer between 1 and %d", MAX_BATCH))
	end

	return History.record("RQE instance.clone", function()
		local created: { any } = {}
		for index = 1, count do
			local copy = source:Clone()
			if params.name ~= nil then
				copy.Name = requireString(params, "name") .. (if count > 1 then tostring(index) else "")
			end
			applyProperties(copy, params.properties)
			applyAttributes(copy, params.attributes)
			copy.Parent = parent
			table.insert(created, describe(copy))
		end
		return { source = describe(source), created = created, count = #created }
	end)
end

--- instance.children: one level, cheap.
function InstanceCommands.children(params: { [string]: any }): any
	local instance = Resolve.instance(params.path)
	local classFilter = params.classFilter
	local children: { any } = {}
	for _, child in ipairs(instance:GetChildren()) do
		if classFilter == nil or child:IsA(classFilter) then
			table.insert(children, describe(child))
		end
	end
	return { parent = describe(instance), children = children, count = #children }
end

--- instance.descendants: the whole subtree, bounded and honest about truncation.
function InstanceCommands.descendants(params: { [string]: any }): any
	local instance = Resolve.instance(params.path)
	local limit = math.min(tonumber(params.limit) or 500, Config.MAX_TREE_NODES)
	local classFilter = params.classFilter

	local found: { any } = {}
	local total = 0
	for _, descendant in ipairs(instance:GetDescendants()) do
		if classFilter == nil or descendant:IsA(classFilter) then
			total += 1
			if #found < limit then
				table.insert(found, describe(descendant))
			end
		end
	end
	return {
		root = describe(instance),
		descendants = found,
		returned = #found,
		total = total,
		-- A truncated answer that does not say so is how a count gets quoted as
		-- if it were complete.
		truncated = total > #found,
	}
end

--- instance.tags: read, and optionally query, CollectionService.
function InstanceCommands.tags(params: { [string]: any }): any
	if params.tag ~= nil then
		local tag = requireString(params, "tag")
		local limit = math.min(tonumber(params.limit) or 200, Config.MAX_TREE_NODES)
		local tagged: { any } = {}
		local all = CollectionService:GetTagged(tag)
		for index, instance in ipairs(all) do
			if index > limit then
				break
			end
			table.insert(tagged, describe(instance))
		end
		return { tag = tag, instances = tagged, returned = #tagged, total = #all, truncated = #all > #tagged }
	end

	local instance = Resolve.instance(params.path)
	local tags = CollectionService:GetTags(instance)
	table.sort(tags)
	return { instance = describe(instance), tags = tags }
end

--- instance.attributes: read every attribute, serialised for the wire.
function InstanceCommands.attributes(params: { [string]: any }): any
	local instance = Resolve.instance(params.path)
	local attributes: { [string]: any } = {}
	local names: { string } = {}
	for key, value in pairs(instance:GetAttributes()) do
		attributes[key] = Serialize.value(value)
		table.insert(names, key)
	end
	table.sort(names)
	return { instance = describe(instance), attributes = attributes, names = names }
end

return InstanceCommands
