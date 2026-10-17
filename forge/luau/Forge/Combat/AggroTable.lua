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
-- NaN is not less than 0, so math.max would store it and entries would
-- report a threat that is not a number.
function AggroTable.add(self: Self, key: string, amount: number): ()
	if type(amount) ~= "number" or amount ~= amount then
		return
	end
	self.threats[key] = math.max(0, (self.threats[key] or 0) + amount)
end

-- Damage event: primary contributor full, others get the assist share.
function AggroTable.damage(self: Self, contributors: { { key: string, weight: number } }, totalThreat: number): ()
	assert(#contributors > 0, "need contributors")
	-- 0/0 is not a share. Adding it makes the total NaN, and NaN <= 0 is
	-- false, so the first key would take the whole threat.
	local usable: { { key: string, weight: number } } = {}
	local totalWeight = 0
	for _, c in contributors do
		local weight = c.weight
		if type(weight) == "number" and weight == weight and weight > 0 and weight ~= math.huge then
			table.insert(usable, c)
			totalWeight += weight
		end
	end
	if totalWeight <= 0 then
		return
	end
	-- add() keeps math.huge, since it is a number above 0. An infinite hit
	-- would latch the table on a threat that never decays to a real value.
	if type(totalThreat) ~= "number" or totalThreat ~= totalThreat or not (totalThreat > 0) or not (totalThreat < math.huge) then
		return
	end
	self:add(usable[1].key, totalThreat)
	for index = 2, #usable do
		local c = usable[index]
		local assist = math.min(self.assistShare * (c.weight / totalWeight), 0.5)
		self:add(c.key, totalThreat * assist)
	end
end

function AggroTable.decay(self: Self, dt: number): ()
	-- A negative step would add threat. Decay only fades it, so a backward
	-- dt is dropped rather than applied.
	if dt < 0 then
		dt = 0
	end
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
