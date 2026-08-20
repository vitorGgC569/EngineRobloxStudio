--!strict
local Players = game:GetService("Players")

local LeaderboardService = {}
LeaderboardService.__index = LeaderboardService

function LeaderboardService.new()
	local self = setmetatable({}, LeaderboardService)
	return self
end

function LeaderboardService:setupPlayer(player: Player, data: any)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end

	local waveVal = leaderstats:FindFirstChild("Wave")
	if not waveVal then
		waveVal = Instance.new("IntValue")
		waveVal.Name = "Wave"
		waveVal.Value = data.highestWave or 1
		waveVal.Parent = leaderstats
	end

	local killsVal = leaderstats:FindFirstChild("Kills")
	if not killsVal then
		killsVal = Instance.new("IntValue")
		killsVal.Name = "Kills"
		killsVal.Value = data.totalKills or 0
		killsVal.Parent = leaderstats
	end

	local scrapsVal = leaderstats:FindFirstChild("Scraps")
	if not scrapsVal then
		scrapsVal = Instance.new("IntValue")
		scrapsVal.Name = "Scraps"
		scrapsVal.Value = data.scraps or 0
		scrapsVal.Parent = leaderstats
	end
end

function LeaderboardService:updateStats(player: Player, wave: number?, kills: number?, scraps: number?)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then return end

	if wave then
		local w = leaderstats:FindFirstChild("Wave") :: IntValue?
		if w then w.Value = wave end
	end
	if kills then
		local k = leaderstats:FindFirstChild("Kills") :: IntValue?
		if k then k.Value = kills end
	end
	if scraps then
		local s = leaderstats:FindFirstChild("Scraps") :: IntValue?
		if s then s.Value = scraps end
	end
end

return LeaderboardService
