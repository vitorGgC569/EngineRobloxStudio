--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local Rules = {}

function Rules.reactorMultiplier(level: number): number
	return 1 + math.max(0, level) * 0.12
end

function Rules.capacity(vaultLevel: number, hasExtraVault: boolean): number
	return 4 + math.max(0, math.floor(vaultLevel)) + (if hasExtraVault then 4 else 0)
end

function Rules.walkSpeed(speedLevel: number): number
	return Config.baseWalkSpeed + math.max(0, speedLevel) * Config.speedPerLevel
end

function Rules.offlinePayout(storedRate: number, awaySeconds: number): (number, number)
	local paidSeconds = math.clamp(math.max(0, awaySeconds), 0, Config.offlineCapSeconds)
	local amount = math.floor(math.max(0, storedRate) * paidSeconds * Config.offlineEfficiency)
	return amount, paidSeconds
end

return Rules
