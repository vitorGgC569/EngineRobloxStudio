--!strict
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ZombieAiService = {}
ZombieAiService.__index = ZombieAiService

export type ZombieAgent = {
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	zombieType: string,
	damage: number,
	attackRate: number,
	attackRange: number,
	detectionRadius: number,
	lastAttackTime: number,
	targetPlayer: Player?,
	state: "Idle" | "Chase" | "Attack" | "Dead",
}

function ZombieAiService.new()
	local self = setmetatable({}, ZombieAiService)
	self._activeZombies = {} :: { [Model]: ZombieAgent }
	return self
end

function ZombieAiService:registerZombie(model: Model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local rootPart = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart") :: BasePart?

	if not humanoid or not rootPart then return end

	local agent: ZombieAgent = {
		model = model,
		humanoid = humanoid,
		rootPart = rootPart,
		zombieType = model:GetAttribute("ZombieType") or "walker",
		damage = model:GetAttribute("Damage") or 15,
		attackRate = model:GetAttribute("AttackRate") or 1.0,
		attackRange = model:GetAttribute("AttackRange") or 4.5,
		detectionRadius = model:GetAttribute("DetectionRadius") or 100,
		lastAttackTime = 0,
		targetPlayer = nil,
		state = "Idle",
	}

	self._activeZombies[model] = agent

	humanoid.Died:Connect(function()
		agent.state = "Dead"
		self._activeZombies[model] = nil
	end)
end

function ZombieAiService:findClosestPlayer(zombiePos: Vector3, maxRadius: number): (Player?, number)
	local closestPlayer: Player? = nil
	local closestDist = maxRadius

	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		if char and char.PrimaryPart then
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				local dist = (char.PrimaryPart.Position - zombiePos).Magnitude
				if dist < closestDist then
					closestDist = dist
					closestPlayer = player
				end
			end
		end
	end

	return closestPlayer, closestDist
end

function ZombieAiService:update(deltaTime: number)
	local now = os.clock()

	for model, agent in pairs(self._activeZombies) do
		if not model.Parent or agent.humanoid.Health <= 0 then
			self._activeZombies[model] = nil
			continue
		end

		local zombiePos = agent.rootPart.Position
		local targetPlayer, dist = self:findClosestPlayer(zombiePos, agent.detectionRadius)

		if targetPlayer and targetPlayer.Character and targetPlayer.Character.PrimaryPart then
			local targetPos = targetPlayer.Character.PrimaryPart.Position
			agent.targetPlayer = targetPlayer

			if dist <= agent.attackRange then
				-- Attack State
				agent.state = "Attack"
				agent.humanoid:MoveTo(zombiePos) -- Stop moving to attack

				if (now - agent.lastAttackTime) >= (1.0 / agent.attackRate) then
					agent.lastAttackTime = now
					local targetHum = targetPlayer.Character:FindFirstChildOfClass("Humanoid")
					if targetHum and targetHum.Health > 0 then
						targetHum:TakeDamage(agent.damage)
					end
				end
			else
				-- Chase State with smart MoveTo
				agent.state = "Chase"
				agent.humanoid:MoveTo(targetPos)
			end
		else
			-- Idle / Search State: Move towards the safezone center (0, 0, 0)
			agent.state = "Idle"
			agent.humanoid:MoveTo(Vector3.new(0, 0, 0))
		end
	end
end

function ZombieAiService:alertNearbyZombies(gunshotPosition: Vector3, hearingRadius: number)
	for _, agent in pairs(self._activeZombies) do
		if agent.state == "Idle" then
			local dist = (agent.rootPart.Position - gunshotPosition).Magnitude
			if dist <= hearingRadius then
				agent.state = "Chase"
				agent.humanoid:MoveTo(gunshotPosition)
			end
		end
	end
end

function ZombieAiService:getActiveCount(): number
	local count = 0
	for _ in pairs(self._activeZombies) do
		count += 1
	end
	return count
end

return ZombieAiService
