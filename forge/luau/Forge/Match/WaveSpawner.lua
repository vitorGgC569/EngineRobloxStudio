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
	-- `or` keeps -1: Luau treats it as truthy, and tick then returns a negative wave.
	-- 0 stays and means an empty base.
	local baseSize = config.baseSize
	if baseSize == nil then
		baseSize = 6
	end
	assert(type(baseSize) == "number" and baseSize >= 0, "baseSize must be >= 0")
	-- `or` keeps -1: Luau treats it as truthy, and math.min then returns a negative wave.
	-- 0 stays and means a cap of nothing.
	local maxWaveSize = config.maxWaveSize
	if maxWaveSize == nil then
		maxWaveSize = 24
	end
	assert(type(maxWaveSize) == "number" and maxWaveSize >= 0, "maxWaveSize must be >= 0")
	-- `or` keeps -1: Luau treats it as truthy, and arriving players then shrink the wave below zero.
	-- 0 stays and means no per-player bonus.
	local perPlayerBonus = config.perPlayerBonus
	if perPlayerBonus == nil then
		perPlayerBonus = 2
	end
	assert(type(perPlayerBonus) == "number" and perPlayerBonus >= 0, "perPlayerBonus must be >= 0")
	-- `or` keeps -1: Luau treats it as truthy, and the next wave is already due.
	-- 0 stays and means the next wave can start immediately.
	local waveIntervalSeconds = config.waveIntervalSeconds
	if waveIntervalSeconds == nil then
		waveIntervalSeconds = 30
	end
	assert(type(waveIntervalSeconds) == "number" and waveIntervalSeconds >= 0, "waveIntervalSeconds must be >= 0")
	-- `or` keeps -1: Luau treats it as truthy, and zero enemies then block every wave.
	-- 0 stays and means the room is already full.
	local maxAlive = config.maxAlive
	if maxAlive == nil then
		maxAlive = 40
	end
	assert(type(maxAlive) == "number" and maxAlive >= 0, "maxAlive must be >= 0")
	-- `or` keeps -1: Luau treats it as truthy, and the first wave is already due.
	-- 0 stays and means the first wave can start at once.
	local firstDelaySeconds = config.firstDelaySeconds
	if firstDelaySeconds == nil then
		firstDelaySeconds = 10
	end
	assert(type(firstDelaySeconds) == "number" and firstDelaySeconds >= 0, "firstDelaySeconds must be >= 0")
	-- NaN < NaN is false, so a NaN reading used to start a wave on every tick.
	local clock = config.clock or os.time
	local now = clock()
	assert(
		type(now) == "number" and now == now and now > -math.huge and now < math.huge,
		"clock must return a finite number"
	)
	return setmetatable({
		baseSize = baseSize,
		perPlayerBonus = perPlayerBonus,
		maxWaveSize = maxWaveSize,
		waveIntervalSeconds = waveIntervalSeconds,
		maxAlive = maxAlive,
		waveNumber = 0,
		nextWaveAt = now + firstDelaySeconds,
		clock = clock,
	}, WaveSpawner)
end

-- Returns wave size when a new wave should start now; nil otherwise.
function WaveSpawner.tick(self: Self, playerCount: number, aliveCount: number): number?
	local now = self.clock()
	-- NaN < nextWaveAt is false, so a bad reading used to start another wave
	-- and store NaN as the next due time.
	if type(now) ~= "number" or now ~= now or not (now > -math.huge and now < math.huge) then
		return nil
	end
	if now < self.nextWaveAt then
		return nil
	end
	if aliveCount >= self.maxAlive then
		return nil -- defer until room clears; next tick retries
	end
	self.waveNumber += 1
	-- A second clock() used to land on NaN, and the next real tick then saw now < NaN.
	self.nextWaveAt = now + self.waveIntervalSeconds
	-- A missing or hostile count must not ask the spawner for a negative wave.
	local players = math.max(0, playerCount)
	local size = math.min(
		self.baseSize + math.floor(players * self.perPlayerBonus * (1 + (self.waveNumber - 1) * 0.1)),
		self.maxWaveSize,
		math.max(1, self.maxAlive - aliveCount)
	)
	return size
end

function WaveSpawner.currentWave(self: Self): number
	return self.waveNumber
end

return WaveSpawner
