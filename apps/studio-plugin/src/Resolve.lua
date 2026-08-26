--!strict
-- Instance path resolution.
--
-- Agents address instances by their full path ("game.Workspace.Map.SpawnPad").
-- Resolution is strict: a path that does not exist raises E_NOT_FOUND with the
-- exact segment that failed, because an agent acting on a silently-nil instance
-- produces a confident wrong answer.

local Resolve = {}

local Errors = require(script.Parent.Errors)
local Refs = require(script.Parent.Refs)

local ROOT_ALIASES = {
	game = true,
	Game = true,
	DataModel = true,
}

--- Split a dotted path, tolerating bracket segments like Workspace["My Part"].
local function segments(path: string): { string }
	local parts: { string } = {}
	local buffer = ""
	local index = 1
	local length = #path

	while index <= length do
		local char = string.sub(path, index, index)
		if char == "." then
			if #buffer > 0 then
				table.insert(parts, buffer)
				buffer = ""
			end
			index += 1
		elseif char == "[" then
			if #buffer > 0 then
				table.insert(parts, buffer)
				buffer = ""
			end
			local closing = string.find(path, "]", index, true)
			if not closing then
				Errors.raise(Errors.BAD_PARAMS, "unterminated '[' in path: " .. path)
			end
			local inner = string.sub(path, index + 1, closing - 1)
			-- Strip the quotes used by GetFullName-style paths.
			inner = string.gsub(inner, '^"(.*)"$', "%1")
			inner = string.gsub(inner, "^'(.*)'$", "%1")
			table.insert(parts, inner)
			index = closing + 1
		else
			buffer ..= char
			index += 1
		end
	end

	if #buffer > 0 then
		table.insert(parts, buffer)
	end
	return parts
end

--- Resolve a path to an Instance, or raise a structured error.
function Resolve.instance(path: string?): Instance
	if path == nil or path == "" then
		return game
	end

	-- Refs address one exact instance; paths can be ambiguous between siblings.
	local refId = string.match(path, "^ref:(.+)$")
	if refId ~= nil then
		local instance = Refs.get(refId)
		if instance == nil then
			Errors.raise(Errors.NOT_FOUND, "ref is unknown or its instance was destroyed", { ref = refId })
		end
		return instance :: Instance
	end

	local parts = segments(path)
	if #parts == 0 then
		return game
	end

	local current: Instance = game
	local startIndex = 1

	--[[
		`walked` is the message, and the message has to name the real root.

		It used to start at "game" unconditionally, so a path rooted at the
		Workspace that failed on its second segment reported "no instance at
		game.Plots" -- a path nobody asked about, pointing at the wrong parent.
		That message cost a debugging session: it reads as a broken resolver
		when the resolver was right and the instance simply was not in the
		DataModel being asked.
	]]
	local walked = { "game" }

	if ROOT_ALIASES[parts[1]] then
		startIndex = 2
	elseif parts[1] == "workspace" or parts[1] == "Workspace" then
		current = workspace
		startIndex = 2
		walked = { "Workspace" }
	end

	for index = startIndex, #parts do
		local name = parts[index]
		local nextInstance: Instance? = nil

		-- Services must be fetched by GetService: they may not be instantiated
		-- yet and FindFirstChild would report a false negative.
		if current == game then
			local ok, service = pcall(function()
				return game:GetService(name :: any)
			end)
			if ok and service then
				nextInstance = service
			end
		end

		if nextInstance == nil then
			nextInstance = current:FindFirstChild(name)
		end

		if nextInstance == nil then
			Errors.raise(Errors.NOT_FOUND, "no instance at " .. table.concat(walked, ".") .. "." .. name, {
				resolvedPath = table.concat(walked, "."),
				missingSegment = name,
				requestedPath = path,
			})
		end

		current = nextInstance :: Instance
		table.insert(walked, name)
	end

	return current
end

--- Resolve a path that must be a BasePart or a Model with a bounding box.
function Resolve.spatial(path: string?): Instance
	local instance = Resolve.instance(path)
	if instance:IsA("BasePart") or instance:IsA("Model") or instance:IsA("Folder") or instance:IsA("Workspace") then
		return instance
	end
	Errors.raise(Errors.BAD_PARAMS, string.format("%s is a %s, which has no spatial extent", instance:GetFullName(), instance.ClassName))
	error("unreachable")
end

--- Compute a world-space bounding box for any container or part.
function Resolve.boundingBox(instance: Instance): (CFrame, Vector3)
	if instance:IsA("BasePart") then
		return instance.CFrame, instance.Size
	end
	if instance:IsA("Model") then
		return instance:GetBoundingBox()
	end

	-- Folders and services have no native bounding box: derive one from the
	-- parts they contain so world queries work on any grouping the game uses.
	local minimum: Vector3? = nil
	local maximum: Vector3? = nil
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local cframe = descendant.CFrame
			local halfSize = descendant.Size / 2
			for x = -1, 1, 2 do
				for y = -1, 1, 2 do
					for z = -1, 1, 2 do
						local corner = cframe * CFrame.new(halfSize.X * x, halfSize.Y * y, halfSize.Z * z)
						local position = corner.Position
						minimum = if minimum then minimum:Min(position) else position
						maximum = if maximum then maximum:Max(position) else position
					end
				end
			end
		end
	end

	if minimum == nil or maximum == nil then
		Errors.raise(Errors.NOT_FOUND, instance:GetFullName() .. " contains no BasePart to measure")
		error("unreachable")
	end

	local center = ((minimum :: Vector3) + (maximum :: Vector3)) / 2
	return CFrame.new(center), (maximum :: Vector3) - (minimum :: Vector3)
end

return Resolve
