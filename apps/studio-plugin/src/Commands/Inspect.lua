--!strict
-- Looking at the place: what is there, what changed, what a test proved.
--
-- `dm.tree` and `dm.properties` already read the hierarchy. What was missing is
-- the shape an agent writing code actually needs: everything about one instance
-- at once, a watch that reports a change rather than being polled for it, and a
-- way to run assertions inside the engine instead of inferring them from
-- outside.

local Errors = require(script.Parent.Parent.Errors)
local Serialize = require(script.Parent.Parent.Serialize)
local Runtime = require(script.Parent.Runtime)

local InspectCommands = {}

local function resolve(path: string): Instance
	local node: Instance = game
	for piece in string.gmatch(path, "[^%.]+") do
		if piece ~= "game" then
			local child = node:FindFirstChild(piece)
			if child == nil then
				Errors.raise(Errors.NOT_FOUND, ("no instance at %s"):format(path))
			end
			node = child
		end
	end
	return node
end

--- Properties worth reading for a class, since reading all of them is neither
--- possible nor useful.
local INTERESTING: { [string]: { string } } = {
	BasePart = { "Position", "Size", "Anchored", "CanCollide", "Transparency",
		"Color", "Material", "Massless", "CastShadow" },
	Model = { "PrimaryPart", "WorldPivot" },
	Humanoid = { "Health", "MaxHealth", "WalkSpeed", "JumpPower", "PlatformStand" },
	Light = { "Brightness", "Range", "Color", "Enabled" },
	GuiObject = { "Position", "Size", "Visible", "BackgroundColor3", "BackgroundTransparency" },
	TextLabel = { "Text", "TextSize", "TextColor3", "Font", "TextScaled" },
	Sound = { "SoundId", "Volume", "Playing", "Looped", "TimePosition" },
	Constraint = { "Enabled", "Attachment0", "Attachment1" },
	Script = { "Enabled", "Disabled" },
	--[[
		The abstract base, so every *Value class is covered by one entry.

		Left out, and the engine could not read its own test report: the suite
		publishes to `ReplicatedStorage.ForgeTests.Report`, a StringValue, and
		`dm.properties` returned its Name and ClassName and silently omitted the
		only field that carries anything. The result read as "the tests never
		ran" when they had run and published perfectly.
	]]
	ValueBase = { "Value" },
	Folder = {},
}

local function readProperties(thing: Instance): { [string]: any }
	local out: { [string]: any } = {}
	for className, names in pairs(INTERESTING) do
		if thing:IsA(className) then
			for _, name in ipairs(names) do
				local ok, value = pcall(function()
					return (thing :: any)[name]
				end)
				if ok and value ~= nil then
					local kind = typeof(value)
					if kind == "Vector3" then
						out[name] = { value.X, value.Y, value.Z }
					elseif kind == "Color3" then
						out[name] = {
							math.floor(value.R * 255 + 0.5),
							math.floor(value.G * 255 + 0.5),
							math.floor(value.B * 255 + 0.5),
						}
					elseif kind == "Instance" then
						out[name] = value:GetFullName()
					elseif kind == "EnumItem" then
						out[name] = value.Name
					elseif kind == "number" or kind == "string" or kind == "boolean" then
						out[name] = value
					else
						out[name] = tostring(value)
					end
				end
			end
		end
	end
	return out
end

--- dm.inspect: everything about one instance, in one call.
function InspectCommands.inspect(params: { [string]: any }): any
	local thing = resolve(Errors.expect(params, "path", "string"))
	local CollectionService = game:GetService("CollectionService")

	local children = {}
	for _, child in ipairs(thing:GetChildren()) do
		table.insert(children, { name = child.Name, className = child.ClassName })
		if #children >= (tonumber(params.maxChildren) or 60) then
			break
		end
	end

	local attributes = {}
	for name, value in pairs(thing:GetAttributes()) do
		attributes[name] = Serialize.value(value)
	end

	local source: string? = nil
	if thing:IsA("LuaSourceContainer") and params.source == true then
		source = (thing :: any).Source
	end

	return {
		path = thing:GetFullName(),
		name = thing.Name,
		className = thing.ClassName,
		parent = if thing.Parent ~= nil then thing.Parent:GetFullName() else nil,
		properties = readProperties(thing),
		attributes = attributes,
		tags = CollectionService:GetTags(thing),
		children = children,
		childCount = #thing:GetChildren(),
		descendantCount = #thing:GetDescendants(),
		source = source,
		context = Runtime.context(),
	}
end

-- -- watching -------------------------------------------------------------------

local watches: { [string]: any } = {}

--- watch.start: record changes to an attribute so they can be read back.
---
--- A poll asks "what is it now"; a watch answers "what did it do while I was
--- not looking", which is the question that catches a value that flickered.
function InspectCommands.watchStart(params: { [string]: any }): any
	local path = Errors.expect(params, "path", "string")
	local attribute = Errors.expect(params, "attribute", "string")
	local thing = resolve(path)
	local key = path .. "|" .. attribute

	local existing = watches[key]
	if existing ~= nil then
		existing.connection:Disconnect()
	end

	local record = {
		path = path,
		attribute = attribute,
		changes = {},
		started = os.clock(),
	}
	record.connection = thing:GetAttributeChangedSignal(attribute):Connect(function()
		local value = thing:GetAttribute(attribute)
		table.insert(record.changes, {
			at = os.clock() - record.started,
			value = Serialize.value(value),
		})
		-- Bounded: a watch on something that ticks every frame must not grow
		-- until the session dies.
		if #record.changes > 500 then
			table.remove(record.changes, 1)
		end
	end)
	watches[key] = record

	return { watching = key, initial = Serialize.value(thing:GetAttribute(attribute)) }
end

--- watch.read: what has it done since the watch started.
function InspectCommands.watchRead(params: { [string]: any }): any
	local path = Errors.expect(params, "path", "string")
	local attribute = Errors.expect(params, "attribute", "string")
	local record = watches[path .. "|" .. attribute]
	if record == nil then
		return { watching = false, changes = {} }
	end
	return {
		watching = true,
		changes = record.changes,
		count = #record.changes,
		elapsed = os.clock() - record.started,
	}
end

function InspectCommands.watchStop(params: { [string]: any }): any
	local key = Errors.expect(params, "path", "string") .. "|"
		.. Errors.expect(params, "attribute", "string")
	local record = watches[key]
	if record == nil then
		return { stopped = false }
	end
	record.connection:Disconnect()
	watches[key] = nil
	return { stopped = true, changes = #record.changes }
end

-- -- testing ---------------------------------------------------------------------

--- test.run: assertions inside the engine, written by whoever is programming.
---
--- The suite outside can check Python. Nothing could check a claim about the
--- DataModel except by reading numbers back and comparing them by hand, which
--- is a test with the assertion in the wrong process.
---
--- The source is given a `check(name, condition, detail)` function and runs.
--- Everything it reports comes back as one result.
function InspectCommands.testRun(params: { [string]: any }): any
	local source = Errors.expect(params, "source", "string")
	if type(loadstring) ~= "function" then
		Errors.raise(Errors.UNSUPPORTED_CONTEXT, "loadstring is unavailable here")
	end

	local results = {}
	local passed, failed = 0, 0

	local function check(name: string, condition: any, detail: any?)
		local ok = condition and true or false
		if ok then
			passed += 1
		else
			failed += 1
		end
		table.insert(results, {
			name = tostring(name),
			passed = ok,
			detail = if detail ~= nil then tostring(detail) else nil,
		})
	end

	local chunk, compileError = loadstring(source, params.chunkName or "rqe.test")
	if chunk == nil then
		local line = tonumber(string.match(tostring(compileError), ":(%d+):"))
		return {
			ran = false,
			compiles = false,
			error = tostring(compileError),
			line = line,
			results = {},
		}
	end

	-- `check` reaches the chunk through a global, which is the simplest thing
	-- that works with `loadstring` and needs no wrapper the caller has to know.
	local previous = (getfenv(chunk) :: any).check
	local environment = getfenv(chunk)
	environment.check = check
	setfenv(chunk, environment)

	local started = os.clock()
	local ok, err = pcall(chunk)
	environment.check = previous

	return {
		ran = true,
		compiles = true,
		ok = ok and failed == 0,
		passed = passed,
		failed = failed,
		results = results,
		error = if ok then nil else tostring(err),
		elapsedMs = (os.clock() - started) * 1000,
		context = Runtime.context(),
	}
end

return InspectCommands
