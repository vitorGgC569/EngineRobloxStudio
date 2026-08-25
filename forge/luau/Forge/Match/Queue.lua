--!strict
--[[
	Queue — FIFO matchmaking with presence validation and forfeit handling.

	A matchmaking queue is trivial until someone disconnects mid-queue and
	their ghost blocks a slot forever. This queue keeps order strictly FIFO,
	validates presence at formation time through an injected checker, drops
	the absent, and reports who left so the server can award a forfeit.
]]

local Queue = {}

export type Config = {
	playersPerMatch: number?,
}

type Entry = {
	key: string,
	enqueuedAt: number,
}

type Self = {
	playersPerMatch: number,
	order: { Entry },
	members: { [string]: boolean },
	presenceChecker: ((string) -> boolean)?,
	clock: () -> number,
}

Queue.__index = Queue

function Queue.new(config: Config?): Self
	local cfg = config or {}
	return setmetatable({
		playersPerMatch = cfg.playersPerMatch or 2,
		order = {},
		members = {},
		presenceChecker = nil,
		clock = os.clock,
	}, Queue)
end

function Queue.setPresenceChecker(self: Self, checker: ((string) -> boolean)?)
	self.presenceChecker = checker
end

function Queue.setClock(self: Self, clock: () -> number)
	self.clock = clock
end

function Queue.join(self: Self, key: string): (boolean, string?)
	if self.members[key] then
		return false, "already_queued"
	end
	table.insert(self.order, { key = key, enqueuedAt = self.clock() })
	self.members[key] = true
	return true, nil
end

function Queue.leave(self: Self, key: string): boolean
	if not self.members[key] then
		return false
	end
	self.members[key] = nil
	for i, entry in self.order do
		if entry.key == key then
			table.remove(self.order, i)
			break
		end
	end
	return true
end

function Queue.size(self: Self): number
	return #self.order
end

function Queue.position(self: Self, key: string): number?
	for i, entry in self.order do
		if entry.key == key then
			return i
		end
	end
	return nil
end

-- Attempts to form one match from the head of the queue. Absent players are
-- dropped first (and reported), so ghosts never block a match.
function Queue.form(self: Self): ({ [string]: any }?)
	local dropped: { string } = {}
	while #self.order >= self.playersPerMatch or (#self.order > 0 and self.presenceChecker) do
		if #self.order == 0 then
			break
		end
		local checker = self.presenceChecker
		local head = self.order[1]
		if checker and not checker(head.key) then
			table.remove(self.order, 1)
			self.members[head.key] = nil
			table.insert(dropped, head.key)
		else
			break
		end
	end
	if #self.order < self.playersPerMatch then
		if #dropped > 0 then
			return { players = nil, dropped = dropped }
		end
		return nil
	end
	local players: { string } = {}
	for _ = 1, self.playersPerMatch do
		local entry = table.remove(self.order, 1) :: Entry
		self.members[entry.key] = nil
		table.insert(players, entry.key)
	end
	return { players = players, dropped = dropped }
end

return Queue
