--!strict
--[[
	StaffFlags — staff identity to capability flags.

	Creator/group staff get powers through flags derived from explicit
	lists; nothing about rank is trusted from the client. Flags gate
	admin surfaces (commands, moderation UI) with one call.
]]

local StaffFlags = {}

export type Definition = {
	userFlags: { [number]: { string } }, -- userId -> flags
	groupFlags: { [number]: { string } }, -- groupId -> flags granted to members
}

type Self = {
	definition: Definition,
	groupMembership: ((userId: number) -> { number })?,
}

StaffFlags.__index = StaffFlags

function StaffFlags.new(definition: Definition, groupMembership: ((number) -> { number })?): Self
	return setmetatable({
		definition = definition,
		groupMembership = groupMembership,
	}, StaffFlags)
end

function StaffFlags.flagsFor(self: Self, userId: number, inGroup: boolean?, groups: { number }?): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}

	for _, flag in self.definition.userFlags[userId] or {} do
		if not seen[flag] then
			seen[flag] = true
			table.insert(out, flag)
		end
	end

	if groups then
		for _, groupId in groups do
			for _, flag in self.definition.groupFlags[groupId] or {} do
				if not seen[flag] then
					seen[flag] = true
					table.insert(out, flag)
				end
			end
		end
	end

	return out
end

function StaffFlags.has(self: Self, flags: { string }, required: string): boolean
	return table.find(flags, required) ~= nil
end

return StaffFlags
