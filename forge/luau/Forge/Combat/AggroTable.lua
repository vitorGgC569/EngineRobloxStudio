--!strict
--[[
	AggroTable — symmetric threat with decay, assist sharing and rage latch.

	Tank/heal combat needs threat, not "who hit last": every damaging
	action adds threat, it decays continuously, assists earn a share,
	fear acts as negative threat (clamped at zero), and a rage latch
	freezes the target onto the top contributor for a minimum duration
	so kiting cannot cheese the switch.
]]

local AggroTable = {}

export type Entry = {
	key: string,
	threat: number,
}

type Self = {
	threats: { [string]: number },
	decayPerSecond: number,
	assistShare: number, -- fraction granted to non-top contributors
	latchDuration: number,
	latchKey: string?,
	latchUntil: number,
	now: () -> number,
}

AggroTable.__index = AggroTable

function AggroTable.new(config: { decayPerSecond: number?, assistShare: number?, latchDuration: number?, now: (() -> number)? }): Self
	return setmetatable({
		threats = {},
		decayPerSecond = config.decayPerSecond or 2,
		assistShare = config.assistShare or 0.25,
		latchDuration = config.latchDuration or 3,
		latchKey = nil,
		latchUntil = 0,
		now = config.now or os.clock,
	}, AggroTable)
end

-- amount may be negative (fear/heal-as-threat reduction); clamped at 0.
function AggroTable.add(self: Self, key: string, amount: number): ()
	self.threats[key] = math.max(0, (self.threats[key] or 0) + amount)
end

-- Damage event: primary contributor full, others get the assist share.
function AggroTable.damage(self: Self, contributors: { { key: string, weight: number } }, totalThreat: number): ()
	assert(#contributors > 0, "need contributors")
	local totalWeight = 0
	for _, c in contributors do
		totalWeight += c.weight
	end
	if totalWeight <= 0 then
		return
	end
	self:add(contributors[1].key, totalThreat)
	for index = 2, #contributors do
		local c = contributors[index]
		local assist = math.min(self.assistShare * (c.weight / totalWeight), 0.5)
		self:add(c.key, totalThreat * assist)
	end
end

function AggroTable.decay(self: Self, dt: number): ()
	for key, value in self.threats do
		local nextValue = value - self.decayPerSecond * dt
		if nextValue <= 0 then
			self.threats[key] = nil
		else
			self.threats[key] = nextValue
		end
	end
end

-- Latches onto current leader for the minimum duration.
function AggroTable.latch(self: Self): string?
	local now = self.now()
	if self.latchKey and now < self.latchUntil then
		return self.latchKey
	end
	local topKey: string? = nil
	local topValue = 0
	for key, value in self.threats do
		if value > topValue then
			topValue = value
			topKey = key
		end
	end
	if topKey then
		self.latchKey = topKey
		self.latchUntil = now + self.latchDuration
	end
	return topKey
end

function AggroTable.entries(self: Self): { Entry }
	local out: { Entry } = {}
	for key, value in self.threats do
		table.insert(out, { key = key, threat = value })
	end
	table.sort(out, function(a, b)
		return a.threat > b.threat
	end)
	return out
end

return AggroTable
