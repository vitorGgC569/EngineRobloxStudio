--!strict
--[[
	IdleGenerator — coin pickups with respawn and an upgrade pad.

	The idle-tycoon floor: world coins that vanish when collected and
	reappear after a cooldown, plus a single upgrade pad with debounced
	purchases on a linear cost curve. Pure bookkeeping over keys.
]]

local IdleGenerator = {}

type Coin = {
	id: string,
	value: number,
	respawnSeconds: number,
	availableAt: number,
}

type Self = {
	coins: { [string]: Coin },
	upgradeBaseCost: number,
	upgradeStepCost: number,
	upgradeLevel: number,
	lastUpgradeAt: number,
	debounce: number,
	clock: () -> number,
	passivePerSecond: number,
}

IdleGenerator.__index = IdleGenerator

function IdleGenerator.new(config: {
	upgradeBaseCost: number?,
	upgradeStepCost: number?,
	debounce: number?,
	passivePerSecond: number?,
	clock: (() -> number)?,
}): Self
	return setmetatable({
		coins = {},
		upgradeBaseCost = config.upgradeBaseCost or 50,
		upgradeStepCost = config.upgradeStepCost or 25,
		upgradeLevel = 1,
		lastUpgradeAt = -math.huge,
		debounce = config.debounce or 1,
		clock = config.clock or os.clock,
		passivePerSecond = config.passivePerSecond or 0,
	}, IdleGenerator)
end

function IdleGenerator.addCoin(self: Self, id: string, value: number, respawnSeconds: number?): ()
	-- math.huge passes `>= 1`, and collect then pays an infinite coin.
	assert(type(value) == "number" and value >= 1 and value < math.huge, ("coin %q needs value >= 1"):format(id))
	assert(not self.coins[id], ("duplicate coin %q"):format(id))
	-- nil is the default. 0 is a real delay, and a negative delay makes the
	-- coin live again at the same clock.
	local respawn = 5
	if respawnSeconds ~= nil then
		assert(
			type(respawnSeconds) == "number" and respawnSeconds >= 0,
			("coin %q needs respawnSeconds >= 0"):format(id)
		)
		respawn = respawnSeconds
	end
	self.coins[id] = { id = id, value = value, respawnSeconds = respawn, availableAt = 0 }
end

-- Collect attempt; returns the payout when the coin was live.
function IdleGenerator.collect(self: Self, id: string): (number, string?)
	local coin = self.coins[id]
	if not coin then
		return 0, "unknown_coin"
	end
	if self.clock() < coin.availableAt then
		return 0, "on_cooldown"
	end
	coin.availableAt = self.clock() + coin.respawnSeconds
	return coin.value, nil
end

function IdleGenerator.isLive(self: Self, id: string): boolean
	local coin = self.coins[id]
	return coin ~= nil and self.clock() >= coin.availableAt
end

function IdleGenerator.upgradeCost(self: Self): number
	return self.upgradeBaseCost + (self.upgradeLevel - 1) * self.upgradeStepCost
end

-- Debounced purchase; caller checks funds.
function IdleGenerator.tryUpgrade(self: Self): (boolean, number?)
	local now = self.clock()
	if now - self.lastUpgradeAt < self.debounce then
		return false, nil
	end
	self.lastUpgradeAt = now
	local cost = self:upgradeCost()
	self.upgradeLevel += 1
	return true, cost
end

function IdleGenerator.passiveIncome(self: Self, dt: number): number
	-- A rewind is not a debit. Only an upgrade spends coins.
	if dt < 0 then
		dt = 0
	end
	return self.passivePerSecond * self.upgradeLevel * dt
end

return IdleGenerator
