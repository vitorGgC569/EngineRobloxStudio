--!strict
--[[
	SystemMailbox — deferred event buffers between simulation phases.

	Systems must not mutate each other mid-iteration: a system pushes
	events into the mailbox and drains them at its phase boundary. Buffers
	live in one registry so hot-reload can invalidate cleanly.
]]

local SystemMailbox = {}

type Self = {
	channels: { [string]: { any } },
	draining: { [string]: boolean },
}

SystemMailbox.__index = SystemMailbox

function SystemMailbox.new(): Self
	return setmetatable({ channels = {}, draining = {} }, SystemMailbox)
end

function SystemMailbox.push(self: Self, channel: string, event: any): ()
	self.channels[channel] = self.channels[channel] or {}
	table.insert(self.channels[channel], event)
end

function SystemMailbox.pushMany(self: Self, channel: string, events: { any }): ()
	for _, event in events do
		self:push(channel, event)
	end
end

-- Drains everything queued for the channel; returns in FIFO order.
function SystemMailbox.drain(self: Self, channel: string): { any }
	local queue = self.channels[channel]
	if not queue then
		return {}
	end
	self.channels[channel] = {}
	return queue
end

function SystemMailbox.count(self: Self, channel: string): number
	local queue = self.channels[channel]
	return if queue then #queue else 0
end

-- Hot-reload support: drop all buffered state.
function SystemMailbox.invalidate(self: Self): ()
	table.clear(self.channels)
	table.clear(self.draining)
end

return SystemMailbox
