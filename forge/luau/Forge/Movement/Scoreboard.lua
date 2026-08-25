--!strict
--[[
	Scoreboard — K/D scoreboard with headshots and per-opponent detail.

	Kills, deaths and headshots aggregate per player; the matchup table
	records who killed whom how often, which feeds both leaderboards and
	balance analysis. Pure ledger; persistence is Save's job.
]]

local Scoreboard = {}

export type PlayerStats = {
	kills: number,
	deaths: number,
	headshots: number,
	matchups: { [number]: number },
}

type Self = {
	stats: { [number]: PlayerStats },
}

Scoreboard.__index = Scoreboard

local function emptyStats(): PlayerStats
	return { kills = 0, deaths = 0, headshots = 0, matchups = {} }
end

function Scoreboard.new(): Self
	return setmetatable({ stats = {} }, Scoreboard)
end

function Scoreboard.get(self: Self, userId: number): PlayerStats
	return self.stats[userId] or emptyStats()
end

-- recordKill(killer=1 victim=2): killer gains a kill (+headshot flag),
-- victim gains a death; both record the matchup.
function Scoreboard.recordKill(self: Self, killerId: number, victimId: number, headshot: boolean?): ()
	local killer = self.stats[killerId] or emptyStats()
	killer.kills += 1
	if headshot then
		killer.headshots += 1
	end
	killer.matchups[victimId] = (killer.matchups[victimId] or 0) + 1
	self.stats[killerId] = killer

	local victim = self.stats[victimId] or emptyStats()
	victim.deaths += 1
	victim.matchups[killerId] = (victim.matchups[killerId] or 0) + 1
	self.stats[victimId] = victim
end

function Scoreboard.snapshot(self: Self): { [number]: PlayerStats }
	local out: { [number]: PlayerStats } = {}
	for userId, stats in self.stats do
		out[userId] = table.clone(stats)
	end
	return out
end

return Scoreboard
