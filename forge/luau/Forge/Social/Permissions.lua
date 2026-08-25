--!strict
--[[
	Permissions — hierarchical ACL for shared entities (plots, servers,
	guilds). Owner > Manager > Trusted > Default, Banned below all.

	Levels are integers; actions declare the minimum level they accept.
	Grant/revoke return a new state so the caller can persist the exact
	delta. A ban blocks every action including defaults.
]]

local Permissions = {}

export type State = {
	lists: { [string]: { number } },
}

export type Config = {
	levels: { [string]: number }?,
	actions: { [string]: number }?,
}

type Self = {
	levels: { [string]: number },
	actions: { [string]: number },
	defaultLevel: number,
	bannedLevel: number,
}

Permissions.__index = Permissions

local function buildIndex(names: { string }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, name in names do
		set[name] = true
	end
	return set
end

function Permissions.new(config: Config?): Self
	local cfg = config or {}
	local levels = cfg.levels or { Owner = 3, Manager = 2, Trusted = 1 }
	local actions = cfg.actions or {}
	for _, actionName in buildIndex({ "Owner", "Manager", "Trusted", "Default", "Banned" }) do
		if actionName == "Default" or actionName == "Banned" then
			assert(not levels[actionName], "Default/Banned are reserved level names")
		end
	end
	return setmetatable({
		levels = levels,
		actions = actions,
		defaultLevel = 0,
		bannedLevel = -1,
	}, Permissions)
end

function Permissions.levelOf(self: Self, state: State, userId: number): number
	for _, levelName in { "Banned", "Owner", "Manager", "Trusted" } do
		local list = state.lists[levelName]
		if list and table.find(list, userId) then
			return if levelName == "Banned" then self.bannedLevel else (self.levels[levelName] :: number)
		end
	end
	return self.defaultLevel
end

function Permissions.check(self: Self, state: State, userId: number, action: string): (boolean, string?)
	local required = self.actions[action]
	if not required then
		return false, "unknown_action"
	end
	local level = self:levelOf(state, userId)
	if level <= self.bannedLevel then
		return false, "banned"
	end
	if level < required then
		return false, "insufficient_level"
	end
	return true, nil
end

function Permissions.grant(self: Self, state: State, userId: number, levelName: string): State?
	if not self.levels[levelName] and levelName ~= "Banned" then
		return nil
	end
	local newState: State = { lists = {} }
	for name, list in state.lists do
		newState.lists[name] = table.clone(list)
	end
	for name, list in newState.lists do
		local index = table.find(list, userId)
		if index then
			table.remove(list, index)
		end
	end
	newState.lists[levelName] = newState.lists[levelName] or {}
	table.insert(newState.lists[levelName], userId)
	return newState
end

function Permissions.revoke(self: Self, state: State, userId: number): State
	local newState: State = { lists = {} }
	for name, list in state.lists do
		local copy = table.clone(list)
		local index = table.find(copy, userId)
		if index then
			table.remove(copy, index)
		end
		newState.lists[name] = copy
	end
	return newState
end

return Permissions
