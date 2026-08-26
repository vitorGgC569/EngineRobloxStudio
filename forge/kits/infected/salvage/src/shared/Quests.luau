--!strict
-- Pure quest definitions + assignment/progress logic (no Roblox services, unit-testable).
-- Each player gets a stable rotating set of daily and weekly quests derived deterministically
-- from the period id + their user id, so no per-player storage of "which quests" is needed —
-- only their progress and claim state. Metrics are incremented by the server from the same
-- events that pay coins (convert/kill/win/survive/playRounds).

local Quests = {}

export type Quest = {
	id: string,
	desc: string,
	metric: string,
	target: number,
	coins: number,
	keys: number,
	xp: number,
}

local DAILY_POOL: { Quest } = {
	{
		id = "d_convert3",
		desc = "Infect 3 survivors",
		metric = "convert",
		target = 3,
		coins = 300,
		keys = 0,
		xp = 150,
	},
	{
		id = "d_kill10",
		desc = "Kill 10 zombies",
		metric = "kill",
		target = 10,
		coins = 300,
		keys = 0,
		xp = 150,
	},
	{
		id = "d_play3",
		desc = "Play 3 rounds",
		metric = "playRounds",
		target = 3,
		coins = 250,
		keys = 0,
		xp = 120,
	},
	{
		id = "d_survive2",
		desc = "Survive 2 rounds",
		metric = "survive",
		target = 2,
		coins = 350,
		keys = 1,
		xp = 180,
	},
	{ id = "d_win1", desc = "Win a round", metric = "win", target = 1, coins = 400, keys = 1, xp = 220 },
	{
		id = "d_kill20",
		desc = "Kill 20 zombies",
		metric = "kill",
		target = 20,
		coins = 500,
		keys = 1,
		xp = 260,
	},
}

local WEEKLY_POOL: { Quest } = {
	{
		id = "w_convert25",
		desc = "Infect 25 survivors",
		metric = "convert",
		target = 25,
		coins = 2000,
		keys = 3,
		xp = 1200,
	},
	{
		id = "w_win10",
		desc = "Win 10 rounds",
		metric = "win",
		target = 10,
		coins = 2500,
		keys = 4,
		xp = 1500,
	},
	{
		id = "w_play30",
		desc = "Play 30 rounds",
		metric = "playRounds",
		target = 30,
		coins = 1800,
		keys = 3,
		xp = 1000,
	},
	{
		id = "w_kill150",
		desc = "Kill 150 zombies",
		metric = "kill",
		target = 150,
		coins = 2200,
		keys = 3,
		xp = 1300,
	},
	{
		id = "w_survive15",
		desc = "Survive 15 rounds",
		metric = "survive",
		target = 15,
		coins = 2400,
		keys = 4,
		xp = 1400,
	},
}

Quests.DailyPool = DAILY_POOL
Quests.WeeklyPool = WEEKLY_POOL
Quests.DailyCount = 3
Quests.WeeklyCount = 2

function Quests.periodDaily(dayNumber: number): number
	return dayNumber
end

function Quests.periodWeekly(dayNumber: number): number
	return math.floor(dayNumber / 7)
end

-- Deterministic shuffle of 1..n using a seeded LCG (pure; no Random service).
local function seededOrder(n: number, seed: number): { number }
	local order = {}
	for i = 1, n do
		order[i] = i
	end
	-- Numerical Recipes LCG constants; keep math in 32-bit range.
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	for i = n, 2, -1 do
		state = (state * 48271) % 2147483647
		local j = (state % i) + 1
		order[i], order[j] = order[j], order[i]
	end
	return order
end

-- The quests assigned to a user for a given scope + period. Stable for that (period,user).
function Quests.assignmentFor(scope: string, periodId: number, userId: number): { Quest }
	local pool = scope == "weekly" and WEEKLY_POOL or DAILY_POOL
	local count = scope == "weekly" and Quests.WeeklyCount or Quests.DailyCount
	local seed = (periodId * 100003 + userId) % 2147483647
	local order = seededOrder(#pool, seed)
	local out: { Quest } = {}
	for i = 1, math.min(count, #pool) do
		table.insert(out, pool[order[i]])
	end
	return out
end

-- Given a quest, its progress count, and whether it was claimed, describe its state.
function Quests.state(
	quest: Quest,
	progress: number,
	claimed: boolean
): { complete: boolean, claimable: boolean, progress: number }
	local capped = math.min(progress, quest.target)
	local complete = capped >= quest.target
	return { complete = complete, claimable = complete and not claimed, progress = capped }
end

return Quests
