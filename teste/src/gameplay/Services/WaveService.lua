local ZombieCatalog, ZombieRigModeler
do
	local ok, rs = pcall(function() return game:GetService("ReplicatedStorage") end)
	if ok and rs and rs:FindFirstChild("Shared") then
		ZombieCatalog = require(rs.Shared.ZombieCatalog)
		ZombieRigModeler = require(rs.Shared.MeshKit.ZombieRigModeler)
	else
		ZombieCatalog = require(script.Parent.Parent.shared.ZombieCatalog)
		ZombieRigModeler = require(script.Parent.Parent.shared.MeshKit.ZombieRigModeler)
	end
end

local WaveService = {}
WaveService.__index = WaveService

export type WaveState = "Intermission" | "Spawning" | "Active" | "Completed"

function WaveService.new(zombieAiService: any, spawnPoints: { BasePart })
	local self = setmetatable({}, WaveService)
	self._ai = zombieAiService
	self._spawnPoints = spawnPoints
	self._currentWave = 0
	self._state = "Intermission" :: WaveState
	self._zombiesRemainingToSpawn = 0
	self._zombiesAlive = 0
	self._nextSpawnTime = 0
	self._intermissionEndTime = 0
	self._onWaveCompleted = nil :: ((wave: number) -> ())?
	self._onWaveStarted = nil :: ((wave: number) -> ())?
	return self
end

function WaveService:startIntermission(durationSeconds: number)
	self._state = "Intermission"
	self._intermissionEndTime = os.clock() + durationSeconds
end

function WaveService:startNextWave()
	self._currentWave += 1
	self._state = "Spawning"

	-- Calculate wave budget
	local baseCount = 8 + (self._currentWave * 4)
	self._zombiesRemainingToSpawn = baseCount
	self._zombiesAlive = 0
	self._nextSpawnTime = os.clock()

	if self._onWaveStarted then
		self._onWaveStarted(self._currentWave)
	end
end

function WaveService:pickZombieTypeForWave(): string
	local roll = math.random(1, 100)
	local wave = self._currentWave

	if wave % 5 == 0 and self._zombiesRemainingToSpawn == 1 then
		return "nightmare_boss"
	end

	if wave >= 4 and roll <= 15 then
		return "brute"
	elseif wave >= 3 and roll <= 35 then
		return "spitter"
	elseif wave >= 2 and roll <= 60 then
		return "runner"
	else
		return "walker"
	end
end

function WaveService:spawnZombie()
	if #self._spawnPoints == 0 then return end

	local spPart = self._spawnPoints[math.random(1, #self._spawnPoints)]
	local zombieType = self:pickZombieTypeForWave()
	local model = ZombieRigModeler.build(zombieType, spPart.CFrame)

	model.Parent = Workspace
	self._ai:registerZombie(model)

	self._zombiesRemainingToSpawn -= 1
	self._zombiesAlive += 1

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Died:Connect(function()
			self._zombiesAlive = math.max(0, self._zombiesAlive - 1)
		end)
	end
end

function WaveService:update(deltaTime: number)
	local now = os.clock()

	if self._state == "Intermission" then
		if now >= self._intermissionEndTime then
			self:startNextWave()
		end
	elseif self._state == "Spawning" then
		if self._zombiesRemainingToSpawn > 0 then
			if now >= self._nextSpawnTime then
				self:spawnZombie()
				self._nextSpawnTime = now + math.max(0.4, 2.0 - (self._currentWave * 0.1))
			end
		else
			self._state = "Active"
		end
	elseif self._state == "Active" then
		local activeInAi = self._ai:getActiveCount()
		if activeInAi == 0 and self._zombiesRemainingToSpawn == 0 then
			self._state = "Completed"
			if self._onWaveCompleted then
				self._onWaveCompleted(self._currentWave)
			end
			self:startIntermission(15.0) -- 15s intermission between waves
		end
	end
end

function WaveService:getCurrentWave(): number
	return self._currentWave
end

function WaveService:getState(): WaveState
	return self._state
end

function WaveService:onWaveStarted(callback: (wave: number) -> ())
	self._onWaveStarted = callback
end

function WaveService:onWaveCompleted(callback: (wave: number) -> ())
	self._onWaveCompleted = callback
end

return WaveService
