--!strict
--[[
	VisualKit.Binding — reactive data binding with text templates.

	The server publishes attributes; the HUD binds once: `"{score} pts"`
	re-renders when `score` changes, property bindings follow the same
	signal. No HUD code ever recomputes game state — it only formats.
	Pure: values come from an injected source table + change signal.
]]

local Binding = {}

export type ChangeSignal = (key: string) -> ()

type Self = {
	data: { [string]: any },
	listeners: { [string]: { () -> () } },
}

Binding.__index = Binding

-- A nested table used to stay the caller's. Editing it after `set`, or
-- editing the table `get` returned, rewrote the value the next read saw.
local function deepCopy(value: any, seen: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in value :: { [any]: any } do
		copy[key] = deepCopy(item, seen)
	end
	return copy
end

function Binding.new(initialData: { [string]: any }?): any
	return setmetatable({
		data = deepCopy(initialData or {}, {}),
		listeners = {},
	}, Binding)
end

local function fire(self: any, key: string): ()
	for _, callback in self.listeners[key] or {} do
		callback()
	end
end

-- Sets a value and notifies every binding that reads this key.
function Binding.set(self: any, key: string, value: any): ()
	local previous = self.data[key]
	if previous == value then
		return
	end
	self.data[key] = deepCopy(value, {})
	fire(self, key)
end

function Binding.get(self: any, key: string): any
	return deepCopy(self.data[key], {})
end

local function renderTemplate(template: string, data: { [string]: any }): string
	return (string.gsub(template, "{(%w+)}", function(placeholder)
		local value = data[placeholder]
		return if value ~= nil then tostring(value) else "{" .. placeholder .. "}"
	end))
end

-- Binds a template like "Cash: {cash}" to a setter; returns the unbind fn.
function Binding.bindToText(self: any, template: string, applyText: (text: string) -> ()): (() -> ())
	local keys: { string } = {}
	for placeholder in string.gmatch(template, "{(%w+)}") do
		table.insert(keys, placeholder)
	end

	local function recompute(): ()
		applyText(renderTemplate(template, self.data))
	end

	recompute()
	local listenerWrapper = {
		disconnect = function()
			for _, key in keys do
				local list = self.listeners[key]
				if list then
					local index = table.find(list, recompute)
					if index then
						table.remove(list, index)
					end
				end
			end
		end,
	}
	for _, key in keys do
		self.listeners[key] = self.listeners[key] or {}
		table.insert(self.listeners[key], recompute)
	end
	return listenerWrapper.disconnect
end

return Binding
