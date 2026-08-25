--!strict
--[[
	GroundLoot — dropped physical items with temporary ownership.

	Loot that hits the floor belongs briefly to its source's killer
	(owner window), then becomes public. The ledger tracks drops by id,
	expires ownership, and answers pickup attempts with stable reasons.
]]

local GroundLoot = {}

type Drop = {
	id: string,
	itemId: string,
	count: number,
	ownerUserId: number?,
	ownerUntil: number,
}

type Self = {
	drops: { [string]: Drop },
	ownerWindow: number,
	clock: () -> number,
	nextId: number,
}

GroundLoot.__index = GroundLoot

function GroundLoot.new(config: { ownerWindow: number?, clock: (() -> number)? }): Self
	return setmetatable({
		drops = {},
		ownerWindow = config.ownerWindow or 10,
		clock = config.clock or os.time,
		nextId = 1,
	}, GroundLoot)
end

function GroundLoot.drop(self: Self, itemId: string, count: number, ownerUserId: number?): string
	local id = "drop_" .. tostring(self.nextId)
	self.nextId += 1
	self.drops[id] = {
		id = id,
		itemId = itemId,
		count = count,
		ownerUserId = ownerUserId,
		ownerUntil = self.clock() + self.ownerWindow,
	}
	return id
end

function GroundLoot.pickup(self: Self, dropId: string, userId: number): (boolean, string?, string?, number?)
	local drop = self.drops[dropId]
	if not drop then
		return false, "unknown_drop", nil, nil
	end
	if drop.ownerUserId and self.clock() < drop.ownerUntil and drop.ownerUserId ~= userId then
		return false, "owned_by_other", nil, nil
	end
	self.drops[dropId] = nil
	return true, nil, drop.itemId, drop.count
end

-- Drops past their owner window become public automatically on read.
function GroundLoot.publicDrops(self: Self): { { id: string, itemId: string, count: number } }
	local now = self.clock()
	local out: { { id: string, itemId: string, count: number } } = {}
	for _, drop in self.drops do
		if not drop.ownerUserId or now >= drop.ownerUntil then
			table.insert(out, { id = drop.id, itemId = drop.itemId, count = drop.count })
		end
	end
	return out
end

return GroundLoot
