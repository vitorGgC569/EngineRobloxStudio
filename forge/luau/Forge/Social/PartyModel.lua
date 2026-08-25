--!strict
--[[
	PartyModel — small cooperative group with leader controls and a
	ready-check for group teleports.

	Invites have pending state and cooldown, the leader alone kicks or
	hands leadership, and nobody teleports until every member readies.
	Pure membership bookkeeping; transport is the caller's problem.
]]

local PartyModel = {}

export type Status = "idle" | "checking" | "approved"

type Self = {
	leader: string,
	maxSize: number,
	members: { [string]: boolean },
	order: { string },
	pending: { [string]: number },
	cooldown: number,
	clock: () -> number,
	checkStatus: Status,
	readyFlags: { [string]: boolean },
}

PartyModel.__index = PartyModel

function PartyModel.new(config: { leader: string, maxSize: number?, cooldownSeconds: number?, clock: (() -> number)? }): Self
	return setmetatable({
		leader = config.leader,
		maxSize = config.maxSize or 6,
		members = { [config.leader] = true },
		order = { config.leader },
		pending = {},
		cooldown = config.cooldownSeconds or 3,
		clock = config.clock or os.clock,
		checkStatus = "idle" :: Status,
		readyFlags = {},
	}, PartyModel)
end

function PartyModel.invite(self: Self, by: string, invitee: string): (boolean, string?)
	if by ~= self.leader then
		return false, "not_leader"
	end
	if self.members[invitee] then
		return false, "already_member"
	end
	if #self.order >= self.maxSize then
		return false, "party_full"
	end
	local now = self.clock()
	local last = self.pending[invitee .. ":t"]
	if last and now - last < self.cooldown then
		return false, "invite_cooldown"
	end
	self.pending[invitee] = now
	self.pending[invitee .. ":t"] = now
	return true, nil
end

function PartyModel.accept(self: Self, invitee: string): boolean
	local invitedAt = self.pending[invitee]
	if not invitedAt then
		return false
	end
	self.pending[invitee] = nil
	self.pending[invitee .. ":t"] = nil
	if #self.order >= self.maxSize or self.members[invitee] then
		return false
	end
	self.members[invitee] = true
	table.insert(self.order, invitee)
	return true
end

function PartyModel.decline(self: Self, invitee: string): ()
	self.pending[invitee] = nil
end

function PartyModel.kick(self: Self, by: string, target: string): boolean
	if by ~= self.leader or target == self.leader or not self.members[target] then
		return false
	end
	self.members[target] = nil
	local index = table.find(self.order, target)
	if index then
		table.remove(self.order, index)
	end
	self.readyFlags[target] = nil
	return true
end

function PartyModel.promote(self: Self, by: string, target: string): boolean
	if by ~= self.leader or not self.members[target] then
		return false
	end
	self.leader = target
	return true
end

function PartyModel.leave(self: Self, member: string): boolean
	if not self.members[member] then
		return false
	end
	self.members[member] = nil
	local index = table.find(self.order, member)
	if index then
		table.remove(self.order, index)
	end
	if member == self.leader and #self.order > 0 then
		self.leader = self.order[1]
	end
	self.checkStatus = "idle"
	return true
end

function PartyModel.startTeleportCheck(self: Self): boolean
	if self.checkStatus ~= "idle" or #self.order == 0 then
		return false
	end
	self.checkStatus = "checking"
	self.readyFlags = {}
	return true
end

function PartyModel.ready(self: Self, member: string, isReady: boolean): ()
	if self.checkStatus == "checking" and self.members[member] then
		self.readyFlags[member] = isReady
	end
end

-- True once every current member has readied; flips to approved.
function PartyModel.pollTeleportApproved(self: Self): boolean
	if self.checkStatus ~= "checking" then
		return false
	end
	for _, member in self.order do
		if not self.readyFlags[member] then
			return false
		end
	end
	self.checkStatus = "approved"
	return true
end

function PartyModel.list(self: Self): { string }
	return table.clone(self.order)
end

return PartyModel
