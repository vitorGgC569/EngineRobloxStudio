--!strict
--[[
	Leaderboard — persistent cross-server rankings that reset cleanly.

	`Movement.Scoreboard` ranks the players in one match. This ranks everyone
	who has ever played, across every server, and survives restarts. They solve
	different problems and neither substitutes for the other.

		local board = Leaderboard.define("weekly_coins", {
			store = "coins",
			rotate = "weekly",
			display = 10,
		})

		Leaderboard.submit(board, player.UserId, coins)
		local top = Leaderboard.top(board)

	Generalised from a shipped game's leaderboard service. Four of its decisions
	are the difference between a board that works and one that quietly eats a
	game's DataStore budget.

	You cannot clear an OrderedDataStore. So do not try.
	---------------------------------------------------

	There is no "delete everything" call, and walking the keys to remove them
	costs a request per player and races every server still writing. The shipped
	answer is to **stop reading the old store and start reading a new one**: the
	store's name carries the start of the current round, so rotation is a string
	change. It is atomic, it is free, and the abandoned stores age out on their
	own and are never read again.

	This is the single most useful thing in this file.

	Write only what changed
	-----------------------

	A player whose score has not moved does not need writing. Without this check
	every server burns its write budget re-publishing identical numbers, and
	DataStore throttling is invisible until the board stops updating.

	Read a hundred, show ten, name ten
	----------------------------------

	Resolving a user id to a name is its own request. A board that fetches a
	hundred entries and names all of them makes ninety calls nobody sees. Names
	are resolved for the visible rows only, and the shipped comment says why it
	mattered: it keeps the refresh cost bounded as the game grows.

	Zero is not a rank
	------------------

	On a competitive board a score of zero is removed rather than written, so
	the board does not fill with every player who has ever loaded in and done
	nothing. On a lifetime-total board zero is a real value and is kept, which
	is why it is a per-board setting rather than a rule.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Leaderboard = {}

local boards: { [string]: any } = {}
local names: { [number]: string } = {}

--: How long between reads of the global store. The board is a social object,
--: not a HUD element; ninety seconds of staleness is invisible to players and
--: the difference between one request a minute and one per frame.
local REFRESH_SECONDS = 90

--: OrderedDataStore returns pages; a hundred is one page and more depth than
--: any board displays. Fetching less saves nothing, fetching more costs pages.
local FETCH_ENTRIES = 100

export type Config = {
	--: The underlying store name. Rotation decorates it; it is never used raw
	--: when a board rotates.
	store: string?,
	--: "never" | "daily" | "weekly" | "monthly", or a period in seconds.
	rotate: (string | number)?,
	--: Rows a player actually sees. Only these get names resolved.
	display: number?,
	--: "desc" ranks highest-first, which is what almost every board wants.
	sort: string?,
	--: Drop rather than store a zero. True for competitive boards, false for
	--: lifetime totals where zero is a real standing.
	dropZero: boolean?,
	refreshSeconds: number?,
}

local ROTATIONS: { [string]: number } = {
	daily = 86400,
	weekly = 604800,
	monthly = 2592000, -- 30 days; calendar months are not a fixed period
}

--[[
	When the current round began, as a unix timestamp.

	Floored to the period so every server in the game computes the same value
	from its own clock without any of them agreeing first. That is what makes
	rotation work across servers with no coordination at all.
]]
function Leaderboard.roundStart(rotate: (string | number)?, now: number?): number?
	if rotate == nil or rotate == "never" then
		return nil
	end
	local period = if type(rotate) == "number" then rotate else ROTATIONS[rotate]
	if not period or period <= 0 then
		return nil
	end
	return math.floor((now or os.time()) / period) * period
end

--[[
	The store name for a board right now.

	The whole rotation mechanism: append the round to the name, and a new round
	is a new store. Nothing is deleted, nothing is migrated, and the reset is
	atomic because it is a string.
]]
function Leaderboard.storeName(board: any, now: number?): string
	local base = board.config.store or board.id
	local round = Leaderboard.roundStart(board.config.rotate, now)
	if not round then
		return base
	end
	return string.format("%s_r%d", base, round)
end

function Leaderboard.define(id: string, config: Config?): any
	local board = {
		id = id,
		config = config or {},
		--: Last value published per user, so unchanged scores are not rewritten.
		published = {} :: { [number]: number },
		entries = {} :: { any },
		fetchedAt = 0,
		round = nil :: number?,
		stores = {} :: { [string]: any },
	}
	boards[id] = board
	return board
end

function Leaderboard.get(id: string): any?
	return boards[id]
end

local function openStore(board: any, now: number?): any?
	local name = Leaderboard.storeName(board, now)
	local cached = board.stores[name]
	if cached ~= nil then
		return cached or nil
	end
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(name)
	end)
	--: `false` rather than nil, so a store that failed to open is remembered as
	--: failed and not retried on every single call.
	board.stores[name] = ok and store or false
	return ok and store or nil
end

--[[
	Publish one player's score.

	Returns whether a write actually happened, which is the number worth
	watching: a board that writes on every call is a board about to be
	throttled.
]]
function Leaderboard.submit(board: any, userId: number, value: number, now: number?): boolean
	local at = now or os.time()
	local round = Leaderboard.roundStart(board.config.rotate, at)
	if round ~= board.round then
		--: A new round. Everything known about the old one is about the old
		--: store and must not suppress writes to the new one.
		board.round = round
		board.published = {}
		board.entries = {}
		board.fetchedAt = 0
	end

	if board.published[userId] == value then
		return false
	end

	local store = openStore(board, at)
	if not store then
		return false
	end

	local drop = board.config.dropZero ~= false and value <= 0
	local ok = pcall(function()
		if drop then
			store:RemoveAsync(tostring(userId))
		else
			store:SetAsync(tostring(userId), math.floor(value))
		end
	end)
	if ok then
		board.published[userId] = value
	end
	return ok
end

local function nameFor(userId: number): string
	local known = names[userId]
	if known then
		return known
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		names[userId] = player.Name
		return player.Name
	end
	local ok, result = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local resolved = ok and result or ("User" .. userId)
	names[userId] = resolved
	return resolved
end

--[[
	Read the board, using the cache unless it has gone stale.

	`force` skips the cache; use it after something that must show immediately,
	not on a timer.
]]
function Leaderboard.refresh(board: any, force: boolean?, now: number?): { any }
	local at = now or os.time()
	local interval = board.config.refreshSeconds or REFRESH_SECONDS
	if not force and board.fetchedAt > 0 and at - board.fetchedAt < interval then
		return board.entries
	end

	local store = openStore(board, at)
	if not store then
		return board.entries
	end

	local ascending = board.config.sort == "asc"
	local ok, pages = pcall(function()
		return store:GetSortedAsync(ascending, FETCH_ENTRIES)
	end)
	if not ok then
		return board.entries
	end

	local readPage, page = pcall(function()
		return pages:GetCurrentPage()
	end)
	if not readPage then
		return board.entries
	end

	--: Names are resolved only down to the display depth. Everything past it is
	--: kept as a rank and an id, which is all a "you are #47" line needs.
	local display = board.config.display or 10
	local entries = {}
	for rank, row in page do
		local userId = tonumber(row.key) or 0
		entries[rank] = {
			rank = rank,
			userId = userId,
			value = row.value,
			name = if rank <= display then nameFor(userId) else nil,
		}
	end

	board.entries = entries
	board.fetchedAt = at
	return entries
end

--: The visible rows, named and ordered.
function Leaderboard.top(board: any, count: number?): { any }
	local entries = Leaderboard.refresh(board)
	local wanted = count or board.config.display or 10
	local out = {}
	for index = 1, math.min(wanted, #entries) do
		table.insert(out, entries[index])
	end
	return out
end

--[[
	Where one player stands, or nil if they are not in the fetched depth.

	Nil is a real answer and not an error: a board reads the top hundred, and
	most players in a large game are not in it. A game that needs an exact rank
	for everybody needs a different data structure, not a deeper page.
]]
function Leaderboard.rankOf(board: any, userId: number): number?
	for _, entry in Leaderboard.refresh(board) do
		if entry.userId == userId then
			return entry.rank
		end
	end
	return nil
end

--: Seconds until the current round ends, for a countdown. Nil when the board
--: does not rotate.
function Leaderboard.secondsRemaining(board: any, now: number?): number?
	local at = now or os.time()
	local round = Leaderboard.roundStart(board.config.rotate, at)
	if not round then
		return nil
	end
	local rotate = board.config.rotate
	local period = if type(rotate) == "number" then rotate else ROTATIONS[rotate :: string]
	return round + (period or 0) - at
end

function Leaderboard.describe(): { [string]: any }
	local list = {}
	for id, board in boards do
		list[id] = {
			store = Leaderboard.storeName(board),
			rotate = board.config.rotate or "never",
			cached = #board.entries,
		}
	end
	return {
		context = RunService:IsServer() and "server" or "client",
		boards = list,
		rotations = { "never", "daily", "weekly", "monthly", "<seconds>" },
	}
end

return Leaderboard
