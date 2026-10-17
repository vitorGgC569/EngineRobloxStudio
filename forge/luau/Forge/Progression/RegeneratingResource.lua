--!strict
--[[
	RegeneratingResource — capped resource with per-second regen and
	phase multipliers (overtime).

	The elixir/energy bar: linear regen toward a cap, optional multiplier
	by game phase, and a snapshot for throttled replication instead of
	every-frame sends.
]]

local RegeneratingResource = {}

type Self = {
	cap: number,
	regenPerSecond: number,
	phaseMultiplier: number,
	value: number,
	lastSnapshot: number,
	snapshotInterval: number,
	clock: () -> number,
}

RegeneratingResource.__index = RegeneratingResource

function RegeneratingResource.new(config: {
	cap: number,
	startValue: number?,
	regenPerSecond: number?,
	snapshotInterval: number?,
	clock: (() -> number)?,
}): Self
	assert(config.cap > 0, "cap must be positive")
	return setmetatable({
		cap = config.cap,
		regenPerSecond = config.regenPerSecond or 1,
		phaseMultiplier = 1,
		value = math.clamp(config.startValue or 0, 0, config.cap),
		lastSnapshot = -math.huge,
		snapshotInterval = config.snapshotInterval or 0.25,
		clock = config.clock or os.clock,
	}, RegeneratingResource)
end

function RegeneratingResource.setPhaseMultiplier(self: Self, multiplier: number): ()
	assert(multiplier >= 0, "multiplier cannot be negative")
	self.phaseMultiplier = multiplier
end

function RegeneratingResource.spend(self: Self, amount: number): boolean
	if amount < 0 or self.value < amount then
		return false
	end
	self.value -= amount
	return true
end

function RegeneratingResource.tick(self: Self, dt: number): ()
	-- A rewind is not a spend. Only spend() may take value off the bar.
	if dt < 0 then
		dt = 0
	end
	self.value = math.min(self.cap, self.value + self.regenPerSecond * self.phaseMultiplier * dt)
end

-- Throttled replication value; only changes on interval boundaries.
function RegeneratingResource.replicationValue(self: Self): number?
	local now = self.clock()
	if now - self.lastSnapshot < self.snapshotInterval then
		return nil
	end
	self.lastSnapshot = now
	return math.floor(self.value * 10 + 0.5) / 10
end

return RegeneratingResource
