--!strict
-- L6: leaderboards.
--
-- Authored because `tidepool` asked for it and the composer came back PLANNED.
--
-- A leaderboard looks like the easiest thing in a game and is where several
-- silent failures live.
--
-- **A tie must resolve the same way every time.** `table.sort` with a
-- comparator that returns false for equal scores leaves their order to the
-- sort's internals, so two players with the same score swap places on every
-- refresh and both of them see the board flickering. Ties break on a stable
-- secondary key here, always.
--
-- **A board that cannot be read is not a board.** Roblox's OrderedDataStore has
-- real limits and real outages; a read that fails and returns an empty list
-- shows every player an empty leaderboard and looks exactly like "nobody has
-- scored yet". `snapshot` reports staleness rather than hiding it.
--
-- **The number on the board and the number in the game must be the same one.**
-- A leaderboard fed by its own counter drifts from the economy that actually
-- moved, and the drift is invisible until a player screenshots both.
--
-- **Higher is not always better.** A speedrun board ranks ascending, and a
-- module that only knows descending silently ranks the worst player first.
--
-- Storage is injected exactly like `Economy` and `Inventory`, so a whole season
-- can be simulated with a plain table.

local Analytics = require(script.Parent.Analytics)

local Leaderboard = {}

export type BoardDefinition = {
	id: string,
	displayName: string,
	--- "desc" ranks the largest first (score, wealth); "asc" the smallest
	--- (best time, fewest deaths).
	direction: string?,
	--- How many entries the board shows.
	size: number?,
	--- Whole numbers only. Roblox's OrderedDataStore stores integers, and a
	--- float silently truncates -- which turns 12.9 seconds into 12.
	integral: boolean?,
}

export type Entry = {
	userId: number,
	name: string,
	value: number,
}

export type Store = {
	get: (boardId: string) -> { Entry }?,
	set: (boardId: string, entries: { Entry }) -> (),
}

export type Snapshot = {
	boardId: string,
	entries: { Entry },
	--- Whether the underlying store answered. An empty board and an unreachable
	--- store look identical to a player and need opposite fixes.
	available: boolean,
	reason: string?,
	truncated: boolean,
}

export type Leaderboard = any

local function fail(message: string): never
	error("[Leaderboard] " .. message, 0)
end

local DIRECTIONS = { desc = true, asc = true }

function Leaderboard.memoryStore(): Store
	local held: { [string]: { Entry } } = {}
	return {
		get = function(boardId: string): { Entry }?
			return held[boardId]
		end,
		set = function(boardId: string, entries: { Entry })
			held[boardId] = entries
		end,
	}
end

function Leaderboard.validate(boards: { BoardDefinition }): { string }
	local problems: { string } = {}
	local seen: { [string]: true } = {}
	for index, board in ipairs(boards) do
		local label = string.format("boards[%d]", index)
		if type(board.id) ~= "string" or board.id == "" then
			table.insert(problems, label .. " needs a non-empty id")
			continue
		end
		if seen[board.id] then
			table.insert(problems, string.format("board %q is defined twice", board.id))
			continue
		end
		seen[board.id] = true

		local direction = board.direction or "desc"
		if not DIRECTIONS[direction] then
			table.insert(problems, string.format(
				"board %q ranks %q; it must be desc (largest first) or asc (smallest "
				.. "first, for times and death counts)", board.id, tostring(direction)))
		end
		local size = board.size or 100
		if type(size) ~= "number" or size < 1 or size % 1 ~= 0 then
			table.insert(problems, string.format(
				"board %q shows %s entries; it must be a whole number of at least 1",
				board.id, tostring(board.size)))
		elseif size > 100 then
			table.insert(problems, string.format(
				"board %q shows %d entries; nobody reads past the first screen and "
				.. "every extra row is bandwidth on every refresh", board.id, size))
		end
	end
	return problems
end

--- Order entries so equal values never swap between refreshes.
---
--- The secondary key is the user id: arbitrary, but *stable*, which is the only
--- property that matters. Without it two tied players trade places on every
--- read and the board looks broken to both of them.
local function ranked(entries: { Entry }, direction: string): { Entry }
	local sorted = table.clone(entries)
	table.sort(sorted, function(left: Entry, right: Entry): boolean
		if left.value ~= right.value then
			if direction == "asc" then
				return left.value < right.value
			end
			return left.value > right.value
		end
		return left.userId < right.userId
	end)
	return sorted
end

function Leaderboard.define(boards: { BoardDefinition }, store: Store): Leaderboard
	if type(store) ~= "table" or type(store.get) ~= "function" or type(store.set) ~= "function" then
		fail("store must provide get and set")
	end

	local problems = Leaderboard.validate(boards)
	if #problems > 0 then
		fail("the boards do not validate: " .. table.concat(problems, "; "))
	end

	local self = {} :: any
	self.boards = {}
	for _, board in ipairs(boards) do
		self.boards[board.id] = board
	end
	self.store = store

	local function requireBoard(boardId: string): BoardDefinition
		local board = self.boards[boardId]
		if board == nil then
			local names: { string } = {}
			for id in pairs(self.boards) do
				table.insert(names, id)
			end
			table.sort(names)
			fail(string.format("unknown board %q; defined: %s", boardId, table.concat(names, ", ")))
		end
		return board
	end

	--- Record a value for one player.
	---
	--- Replaces rather than accumulates: the caller owns the number, and a board
	--- that adds to what it already had drifts from the system that produced it.
	function self.submit(player: Player, boardId: string, value: number): Entry
		local board = requireBoard(boardId)
		if type(value) ~= "number" or value ~= value then
			fail(string.format("board %q was submitted a value that is not a number", boardId))
		end
		if board.integral ~= false and value % 1 ~= 0 then
			-- Truncation is stated rather than performed silently: a time of
			-- 12.9 stored as 12 makes a player faster than they were.
			fail(string.format(
				"board %q takes whole numbers and was submitted %.3f; scale the value "
				.. "(milliseconds rather than seconds) or declare integral = false",
				boardId, value))
		end

		local entries = store.get(boardId) or {}
		local updated = false
		for _, entry in ipairs(entries) do
			if entry.userId == player.UserId then
				entry.value = value
				entry.name = player.Name
				updated = true
				break
			end
		end
		local entry: Entry = { userId = player.UserId, name = player.Name, value = value }
		if not updated then
			table.insert(entries, entry)
		end
		store.set(boardId, entries)
		Analytics.custom(player, "leaderboard_submit", value, { boardId = boardId })
		return entry
	end

	--- The board as it should be displayed.
	function self.snapshot(boardId: string): Snapshot
		local board = requireBoard(boardId)
		local ok, entries = pcall(function()
			return store.get(boardId)
		end)
		if not ok then
			-- Reported, never returned as an empty board. "Nobody has scored"
			-- and "the store is down" look identical on screen and need
			-- opposite responses.
			return {
				boardId = boardId,
				entries = {},
				available = false,
				reason = "the leaderboard store could not be read: " .. tostring(entries),
				truncated = false,
			}
		end

		local size = board.size or 100
		local sorted = ranked(entries or {}, board.direction or "desc")
		local shown: { Entry } = {}
		for index = 1, math.min(size, #sorted) do
			table.insert(shown, sorted[index])
		end
		return {
			boardId = boardId,
			entries = shown,
			available = true,
			truncated = #sorted > size,
		}
	end

	--- Where one player stands, including when they are off the visible board.
	---
	--- A player outside the top N seeing no rank at all cannot tell whether they
	--- are 101st or unranked, and those feel very different.
	function self.rankOf(player: Player, boardId: string): (number?, number)
		local board = requireBoard(boardId)
		local entries = store.get(boardId) or {}
		local sorted = ranked(entries, board.direction or "desc")
		for index, entry in ipairs(sorted) do
			if entry.userId == player.UserId then
				return index, #sorted
			end
		end
		return nil, #sorted
	end

	return self
end

--- Boards that will read as broken to a player.
function Leaderboard.problems(snapshot: Snapshot, policy: { [string]: any }?): { string }
	local settings = policy or {}
	local minimum = settings.minimumEntries or 1

	local problems: { string } = {}
	if not snapshot.available then
		table.insert(problems, string.format(
			"board %q could not be read, so every player sees an empty board that looks "
			.. "like nobody has scored: %s", snapshot.boardId, tostring(snapshot.reason)))
		return problems
	end
	if #snapshot.entries < minimum then
		table.insert(problems, string.format(
			"board %q has %d entries; an empty leaderboard on a live game reads as a "
			.. "feature nobody uses", snapshot.boardId, #snapshot.entries))
	end

	local values: { [number]: true } = {}
	local duplicates = 0
	for _, entry in ipairs(snapshot.entries) do
		if values[entry.value] then
			duplicates += 1
		end
		values[entry.value] = true
	end
	if #snapshot.entries > 4 and duplicates >= #snapshot.entries - 1 then
		table.insert(problems, string.format(
			"board %q is almost entirely ties; a board where everyone scores the same "
			.. "ranks nobody", snapshot.boardId))
	end
	return problems
end

Leaderboard.ranked = ranked

return Leaderboard
