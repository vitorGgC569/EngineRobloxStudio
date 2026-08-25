--!strict
--[[
	WaveSpawner — timed waves scaled by player count.

	Round-based PvE needs waves that grow with the lobby but never flood
	the server: interval between waves, size formula base+perPlayer×n
	capped, and a max concurrent alive budget that delays spawning.
	Pure scheduler; actual NPC creation is the caller's callback.
]]

local WaveSpawner = {}

type Self = {
	baseSize: number,
	perPlayerBonus: number,
	maxWaveSize: number,
	waveIntervalSeconds: number,
	maxAlive: number,
	waveNumber: number,
	nextWaveAt: number,
	clock: () -> number,
}

WaveSpawner.__index = WaveSpawner

function WaveSpawner.new(config: {
	baseSize: number?,
	perPlayerBonus: number?,
	maxWaveSize: number?,
	waveIntervalSeconds: number?,
	maxAlive: number?,
	firstDelaySeconds: number?,
	clock: (() -> number)?,
}): Self
	return setmetatable({
		baseSize = config.baseSize or 6,
		perPlayerBonus = config.perPlayerBonus or 2,
		maxWaveSize = config.maxWaveSize or 24,
		waveIntervalSeconds = config.waveIntervalSeconds or 30,
		maxAlive = config.maxAlive or 40,
		waveNumber = 0,
		nextWaveAt = (config.clock or os.time)() + (config.firstDelaySeconds or 10),
		clock = config.clock or os.time,
	}, WaveSpawner)
end

-- Returns wave size when a new wave should start now; nil otherwise.
function WaveSpawner.tick(self: Self, playerCount: number, aliveCount: number): number?
	if self.clock() < self.nextWaveAt then
		return nil
	end
	if aliveCount >= self.maxAlive then
		return nil -- defer until room clears; next tick retries
	end
	self.waveNumber += 1
	self.nextWaveAt = self.clock() + self.waveIntervalSeconds
	local size = math.min(
		self.baseSize + math.floor(playerCount * self.perPlayerBonus * (1 + (self.waveNumber - 1) * 0.1)),
		self.maxWaveSize,
		math.max(1, self.maxAlive - aliveCount)
	)
	return size
end

function WaveSpawner.currentWave(self: Self): number
	return self.waveNumber
end

return WaveSpawner
