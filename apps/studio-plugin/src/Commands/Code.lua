--!strict
-- Writing and reloading code inside the open place.
--
-- The most expensive thing in this platform was adding a module: write the
-- file, run Rojo, restart Studio, reopen the place, try again. About a minute,
-- every iteration. An agent programming a game lives in that loop, and a
-- minute per attempt is the difference between programming and waiting.
--
-- These commands put the source straight into the DataModel.
--
-- **Reloading means a new identity.** Roblox caches `require` per ModuleScript
-- instance, forever. Setting `.Source` on a module that has already been
-- required changes nothing — the cached table is what everyone still holds. So
-- reload destroys the module and creates a new one with the same name and
-- parent, which is a genuinely different instance and therefore a fresh
-- require.
--
-- The consequence is worth stating plainly rather than hiding: **anything
-- holding a reference to the old table keeps it.** A system that did
-- `local Core = require(...)` at the top and is still running has the previous
-- version. Reload is for the write-test-write loop, not for surgery on a live
-- session, and `run_at_start` exists for code that must come up with the game.

local Errors = require(script.Parent.Parent.Errors)
local Runtime = require(script.Parent.Runtime)
local ScriptEditorService = game:GetService("ScriptEditorService")
local History = require(script.Parent.Parent.History)

local CodeCommands = {}

local function editorSource(container: LuaSourceContainer): string
	local ok, value = pcall(function()
		return ScriptEditorService:GetEditorSource(container)
	end)
	if ok and type(value) == "string" then
		return value
	end
	return (container :: any).Source or ""
end

local function updateSource(container: LuaSourceContainer, source: string)
	local ok, err = pcall(function()
		ScriptEditorService:UpdateSourceAsync(container, function(_old)
			return source
		end)
	end)
	if not ok then
		Errors.raise(
			Errors.EXEC,
			"ScriptEditorService:UpdateSourceAsync failed: " .. tostring(err)
		)
	end
end

local ROOTS: { [string]: string } = {
	replicated = "ReplicatedStorage",
	server = "ServerScriptService",
	starter = "StarterPlayer",
	workspace = "Workspace",
	lighting = "Lighting",
}

--- Walk a dotted path, creating folders for anything missing.
local function resolve(path: string, create: boolean): Instance?
	local pieces = {}
	for piece in string.gmatch(path, "[^%./]+") do
		table.insert(pieces, piece)
	end
	if #pieces == 0 then
		return nil
	end

	local head = pieces[1]
	local service = ROOTS[string.lower(head)] or head
	local ok, node = pcall(function()
		return game:GetService(service :: any)
	end)
	if not ok or node == nil then
		node = game:FindFirstChild(head)
	end
	if node == nil then
		return nil
	end

	for index = 2, #pieces do
		local name = pieces[index]
		local child = node:FindFirstChild(name)
		if child == nil then
			-- Reading: a missing leaf means there is nothing there.
			-- Creating: every missing piece is made, *including the last* --
			-- the first version stopped short of it, so
			-- `ReplicatedStorage.Scratch` resolved to `ReplicatedStorage` and
			-- the module was written one level too high.
			if not create then
				return nil
			end
			child = Instance.new("Folder")
			child.Name = name
			child.Parent = node
		end
		node = child
	end
	return node
end

local function leafName(path: string): string
	local last = path
	for piece in string.gmatch(path, "[^%./]+") do
		last = piece
	end
	-- `Core/Signal.lua` and `Core.Signal` should both land on `Signal`.
	return (string.gsub(last, "%.lua$", ""))
end

--- code.write: put source into a script in the place.
---
--- `kind` decides what is made: "module" for something required, "server" for a
--- Script that runs, "client" for a LocalScript.
local function writeImpl(params: { [string]: any }): any
	local path = Errors.expect(params, "path", "string")
	local source = Errors.expect(params, "source", "string")
	local kind = params.kind or "module"

	local className =
		if kind == "server" then "Script"
		elseif kind == "client" then "LocalScript"
		elseif kind == "module" then "ModuleScript"
		else nil
	if className == nil then
		Errors.raise(Errors.BAD_PARAMS,
			("kind must be module, server or client; got %q"):format(tostring(kind)))
	end

	local name = leafName(path)
	local parentPath = string.match(path, "^(.*)[%./][^%./]+$")
	local parent = if parentPath ~= nil then resolve(parentPath, true) else nil
	if parent == nil then
		parent = if kind == "module" then game:GetService("ReplicatedStorage")
			else game:GetService("ServerScriptService")
	end

	local existing = parent:FindFirstChild(name)
	local replaced = false
	if existing ~= nil then
		if existing.ClassName ~= className then
			existing:Destroy()
		else
			-- Same class: rewrite in place. Cheapest path, and enough when the
			-- module has not been required yet.
			updateSource(existing :: LuaSourceContainer, source)
			replaced = true
			return {
				written = existing:GetFullName(),
				className = className,
				bytes = #source,
				replaced = replaced,
				requiresReload = true,
				note = "source replaced in place; call code.reload for a fresh require",
			}
		end
	end

	local made = Instance.new(className :: any)
	made.Name = name
	made.Parent = parent
	updateSource(made :: LuaSourceContainer, source)

	return {
		written = made:GetFullName(),
		className = className,
		bytes = #source,
		replaced = replaced,
		requiresReload = false,
	}
end

--- code.reload: give a module a new identity so `require` re-runs it.
local function reloadImpl(params: { [string]: any }): any
	local path = Errors.expect(params, "path", "string")
	local target = resolve(path, false)
	if target == nil then
		Errors.raise(Errors.NOT_FOUND, ("nothing at %s to reload"):format(path))
	end
	if not target:IsA("LuaSourceContainer") then
		Errors.raise(Errors.BAD_PARAMS,
			("%s is a %s, not a script"):format(path, target.ClassName))
	end

	local source = params.source
	if type(source) == "string" then
		updateSource(target :: LuaSourceContainer, source)
	end
	local currentSource = editorSource(target :: LuaSourceContainer)

	local parent = target.Parent
	local name = target.Name
	-- A clone is a different instance, and a different instance is a different
	-- require key. This is the only way to invalidate Roblox's module cache.
	local fresh = target:Clone()
	local children = target:GetChildren()
	for _, child in ipairs(children) do
		child.Parent = fresh
	end
	target:Destroy()
	fresh.Name = name
	fresh.Parent = parent
	updateSource(fresh :: LuaSourceContainer, currentSource)

	-- Prove it loads now, rather than at whatever later moment somebody
	-- requires it. A module that fails here says so with a line number; the
	-- alternative is "Requested module experienced an error while loading",
	-- which names nothing.
	local loaded, err = true, nil
	if fresh:IsA("ModuleScript") then
		local ok, result = pcall(require, fresh :: any)
		loaded = ok
		if not ok then
			err = tostring(result)
		end
	end

	return {
		reloaded = fresh:GetFullName(),
		bytes = #editorSource(fresh :: LuaSourceContainer),
		loads = loaded,
		error = err,
		note = "anything that already required the old module still holds it",
	}
end

--- code.list: what scripts exist under a path, and how big.
function CodeCommands.list(params: { [string]: any }): any
	local path = params.path or "ReplicatedStorage"
	local root = resolve(path, false)
	if root == nil then
		Errors.raise(Errors.NOT_FOUND, ("nothing at %s"):format(path))
	end

	local scripts = {}
	for _, item in ipairs(root:GetDescendants()) do
		if item:IsA("LuaSourceContainer") then
			table.insert(scripts, {
				path = item:GetFullName(),
				name = item.Name,
				className = item.ClassName,
				bytes = #editorSource(item :: LuaSourceContainer),
			})
		end
	end
	table.sort(scripts, function(a, b)
		return a.path < b.path
	end)
	return { root = root:GetFullName(), scripts = scripts, count = #scripts }
end

--- code.read: the source of one script, to read before changing it.
function CodeCommands.read(params: { [string]: any }): any
	local path = Errors.expect(params, "path", "string")
	local target = resolve(path, false)
	if target == nil or not target:IsA("LuaSourceContainer") then
		Errors.raise(Errors.NOT_FOUND, ("no script at %s"):format(path))
	end
	local source = editorSource(target :: LuaSourceContainer)
	return {
		path = target:GetFullName(),
		className = target.ClassName,
		bytes = #source,
		source = source,
	}
end

--- code.at_start: code that runs when the game starts, saved with the place.
---
--- The difference from `bridge.exec` is lifetime. Exec runs now and its
--- connections die with the session; this becomes a Script in the place, so it
--- comes up with every Play Solo and survives a restart.
local function atStartImpl(params: { [string]: any }): any
	local source = Errors.expect(params, "source", "string")
	local name = params.name or "RQEStartup"
	local client = params.client == true

	local parent = if client
		then game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts")
			or game:GetService("StarterPlayer")
		else game:GetService("ServerScriptService")

	local existing = parent:FindFirstChild(name)
	if existing ~= nil then
		existing:Destroy()
	end

	local made = Instance.new(if client then "LocalScript" else "Script")
	made.Name = name
	made.Parent = parent
	updateSource(made :: LuaSourceContainer, source)

	return {
		installed = made:GetFullName(),
		className = made.ClassName,
		bytes = #source,
		runsOn = if client then "client" else "server",
	}
end

--- code.compile: does this parse, without running any of it.
function CodeCommands.compile(params: { [string]: any }): any
	local source = Errors.expect(params, "source", "string")
	if type(loadstring) ~= "function" then
		Errors.raise(Errors.UNSUPPORTED_CONTEXT, "loadstring is unavailable here")
	end
	local chunk, err = loadstring(source, params.chunkName or "rqe.compile")
	if chunk == nil then
		local line = tonumber(string.match(tostring(err), ":(%d+):"))
		return {
			compiles = false,
			error = tostring(err),
			line = line,
			context = Runtime.context(),
		}
	end
	return { compiles = true, context = Runtime.context() }
end


CodeCommands.write = function(params: { [string]: any }): any
	return History.record("RQE code.write", function()
		return writeImpl(params)
	end)
end

CodeCommands.reload = function(params: { [string]: any }): any
	return History.record("RQE code.reload", function()
		return reloadImpl(params)
	end)
end

CodeCommands.atStart = function(params: { [string]: any }): any
	return History.record("RQE code.at_start", function()
		return atStartImpl(params)
	end)
end

return CodeCommands
