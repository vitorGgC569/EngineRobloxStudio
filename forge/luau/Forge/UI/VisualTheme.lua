--!strict
--[[
	VisualTheme — runtime theme switching over computed role tables.

	Themes are precomputed VisualTokens role sets registered by name;
	switching is one call that notifies subscribers. No theme may be
	built from raw hex at registration time -- they come from
	Tokens.fromSchemeData, so accessibility is inherited, not hoped for.
]]

local VisualTheme = {}

export type Roles = { [string]: any }

type Self = {
	themes: { [string]: Roles },
	active: string?,
	subscribers: { () -> () },
}

VisualTheme.__index = VisualTheme

function VisualTheme.new(): Self
	return setmetatable({ themes = {}, active = nil, subscribers = {} }, VisualTheme)
end

function VisualTheme.register(self: Self, name: string, roles: Roles): ()
	assert(self.themes[name] == nil, ("theme %q already registered"):format(name))
	self.themes[name] = roles
end

function VisualTheme.switchTo(self: Self, name: string): boolean
	if not self.themes[name] then
		return false
	end
	self.active = name
	for _, callback in self.subscribers do
		callback()
	end
	return true
end

function VisualTheme.current(self: Self): Roles?
	return if self.active then self.themes[self.active] else nil
end

function VisualTheme.available(self: Self): { string }
	local out: { string } = {}
	for name in self.themes do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

function VisualTheme.subscribe(self: Self, callback: () -> ()): () -> ()
	table.insert(self.subscribers, callback)
	return function()
		local index = table.find(self.subscribers, callback)
		if index then
			table.remove(self.subscribers, index)
		end
	end
end

return VisualTheme
