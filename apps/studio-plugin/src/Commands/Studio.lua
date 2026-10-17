--!strict
-- Native Studio editor controls that should never require mouse/Explorer clicks.

local Selection = game:GetService("Selection")
local StudioService = game:GetService("StudioService")

local Resolve = require(script.Parent.Parent.Resolve)
local Refs = require(script.Parent.Parent.Refs)
local Errors = require(script.Parent.Parent.Errors)

local StudioCommands = {}

local function describe(instance: Instance): { [string]: any }
	return {
		name = instance.Name,
		className = instance.ClassName,
		path = instance:GetFullName(),
		ref = "ref:" .. Refs.of(instance),
	}
end

local function selected(): { [string]: any }
	local items = {}
	for _, instance in ipairs(Selection:Get()) do
		table.insert(items, describe(instance))
	end
	return {
		count = #items,
		items = items,
		thickness = Selection.SelectionThickness,
	}
end

function StudioCommands.selection(_params: { [string]: any }): any
	return selected()
end

function StudioCommands.select(params: { [string]: any }): any
	local mode = params.mode or "set"
	if mode ~= "set" and mode ~= "add" and mode ~= "remove" then
		Errors.raise(Errors.BAD_PARAMS, "mode must be set, add or remove")
	end

	local requested = params.paths or {}
	if type(requested) ~= "table" then
		Errors.raise(Errors.BAD_PARAMS, "paths must be an array of instance paths or refs")
	end

	local instances = {}
	for index, path in ipairs(requested) do
		if type(path) ~= "string" or path == "" then
			Errors.raise(
				Errors.BAD_PARAMS,
				string.format("paths[%d] must be a non-empty string", index)
			)
		end
		table.insert(instances, Resolve.instance(path))
	end

	if mode == "set" then
		Selection:Set(instances)
	elseif mode == "add" then
		Selection:Add(instances)
	else
		Selection:Remove(instances)
	end

	local result = selected()
	result.mode = mode
	return result
end

function StudioCommands.environment(_params: { [string]: any }): any
	local active = StudioService.ActiveScript
	return {
		gridSize = StudioService.GridSize,
		rotateIncrement = StudioService.RotateIncrement,
		useLocalSpace = StudioService.UseLocalSpace,
		locale = StudioService.StudioLocaleId,
		activeScript = if active and active:IsA("LuaSourceContainer")
			then describe(active)
			else nil,
		selection = selected(),
	}
end

return StudioCommands
