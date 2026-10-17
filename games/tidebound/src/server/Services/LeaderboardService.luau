--!strict
--[[
	LeaderboardService — three boards, two of them forever.

	"Biggest catch today" rotates at midnight and is where a good day shows
	off. "Species" and "Coins earned" are lifetime and are where a good
	*career* shows off. Values are stored as integers because OrderedDataStore
	only speaks integers: weights go up in centi-kilos and come back down for
	display, everything else is already a count.

	Boards are read when a player asks. The engine's own cache keeps that
	cheap, and a board nobody is looking at costs nothing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Net = Forge.Net
local Debug = Forge.Debug
local Leaderboard = Forge.LiveOps.Leaderboard

local DataService = require(script.Parent.DataService)

local LeaderboardService = {}

LeaderboardService.boards = {
	{
		id = "biggest_day",
		title = "Biggest catch today",
		subtitle = "Resets at midnight UTC",
		unit = "kg",
		display = 10,
		rotate = "daily",
		store = "tidebound_biggest",
	},
	{
		id = "species",
		title = "Species discovered",
		subtitle = "Lifetime",
		unit = "species",
		display = 10,
		rotate = "never",
		store = "tidebound_species",
	},
	{
		id = "coins",
		title = "Coins earned",
		subtitle = "Lifetime, every sale counted",
		unit = "coins",
		display = 10,
		rotate = "never",
		store = "tidebound_coins",
	},
}

local byId: { [string]: any } = {}
for _, definition in LeaderboardService.boards do
	byId[definition.id] = definition
	Leaderboard.define(definition.id, {
		store = definition.store,
		rotate = definition.rotate,
		display = definition.display,
	})
end

-- =============================== publishing =================================
--: Publish one player's current values to every board they can appear on.
--: The engine skips unchanged values, so calling this after anything that
--: moves a number is correct and still cheap.
function LeaderboardService.publish(player: Player)
	local profile = DataService.profile(player)
	if not profile then
		return
	end
	local biggest = profile.stats.biggest
	if biggest then
		Leaderboard.submit(Leaderboard.get("biggest_day"), player.UserId, math.floor(biggest.weight * 100))
	end
	Leaderboard.submit(Leaderboard.get("species"), player.UserId, profile.stats.species or 0)
	Leaderboard.submit(Leaderboard.get("coins"), player.UserId, profile.stats.coinsEarned or 0)
end

function LeaderboardService.afterCatch(player: Player, result: any)
	local profile = DataService.profile(player)
	if not profile then
		return
	end
	--: Only a whole new personal best is worth a write on the rotating board.
	local biggest = profile.stats.biggest
	if biggest and math.abs(biggest.weight - (result.weightKg or 0)) < 1e-6 then
		Leaderboard.submit(Leaderboard.get("biggest_day"), player.UserId, math.floor(result.weightKg * 100))
	end
	Leaderboard.submit(Leaderboard.get("species"), player.UserId, profile.stats.species or 0)
end

-- ================================ reading ===================================
local function present(definition: any, entries: { any }, player: Player): { any }
	local out = {}
	for _, entry in entries do
		local value = entry.value
		if definition.unit == "kg" then
			value = value / 100
		end
		table.insert(out, {
			rank = entry.rank,
			name = entry.name or "Uncharted",
			value = value,
			me = entry.userId == player.UserId,
		})
	end
	return out
end

function LeaderboardService.send(player: Player, boardId: string)
	local definition = byId[boardId] or byId.species
	LeaderboardService.publish(player)
	local board = Leaderboard.get(definition.id)
	local entries = if board then Leaderboard.top(board, definition.display) else {}
	Net.fire(player, "BoardSync", {
		board = definition.id,
		title = definition.title,
		subtitle = definition.subtitle,
		unit = definition.unit,
		rows = present(definition, entries, player),
		resetIn = board and Leaderboard.secondsRemaining(board) or nil,
		boards = LeaderboardService.boards,
	})
end

-- ================================== start ===================================
function LeaderboardService.start()
	Net.on("RequestBoard", function(player: Player, payload: any)
		LeaderboardService.send(player, payload.board)
	end)

	--: A player's first sight of a board should include themselves, so their
	--: values go up once on load.
	local Save = Forge.Save
	Save.observe(function(player: Player)
		task.delay(6, function()
			if player.Parent then
				LeaderboardService.publish(player)
			end
		end)
	end)

	Debug.info("leaderboards armed")
end

return LeaderboardService
