--[[
	EconomyService — the server's one heartbeat.

	Three concerns share a single clock because they share a single cadence:

	  * income: every player earns `state.perSecond` Rift each second, credited
	    through PlayerStore so the wallet stays the only balance in the game;
	  * auto summon: `RollService.tickAuto` is driven from here, because a
	    feature with no clock is a feature that never fires;
	  * leaderboards: four global boards, published every thirty seconds,
	    because OrderedDataStore writes are the scarce resource and a board
	    that writes per frame is a board that gets throttled.

	Every DataStore touch is pcall-wrapped and every failure degrades to an
	empty board. Studio without API access has no OrderedDataStore at all, and
	a game that errors because its leaderboard is unavailable cannot be
	developed offline.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Format = require(ReplicatedStorage.Shared.Format)
local PlayerStore = require(script.Parent.PlayerStore)
local RollService = require(script.Parent.RollService)

local Net = Forge.Net
local Leaderboard = Forge.LiveOps.Leaderboard

local EconomyService = {}

--: How often the full StateSync is pushed. The values it carries move slowly,
--: every mutating action already pushed itself, and a push per tick would
--: spend the budget that makes a purchase feel instant.
local PUSH_EVERY = 3

--: Leaderboard publishes. One write per player per thirty seconds is
--: invisible to readers and keeps a busy server inside its write budget.
local SUBMIT_EVERY = 30

local tickCount = 0
local started = false

--[[
	Boards are declared once, at module scope, so `boardFor` answers before
	`start` has ever run: tests and the Board handler read the same table, and
	`Leaderboard.define` is never called twice for one id -- a second call
	would forget everything the first board had published.
]]
local boards = {
	power = Leaderboard.define("power", { store = "aurarift_power", display = 10 }),
	floor = Leaderboard.define("floor", { store = "aurarift_floor", display = 10 }),
	collection = Leaderboard.define("collection", { store = "aurarift_collection", display = 10 }),
	divines = Leaderboard.define("divines", { store = "aurarift_divines", display = 10 }),
}

function EconomyService.boardFor(id)
	return boards[id]
end

-- ============================== formatting =================================

--: One value as its board shows it. Power is a big number and gets an
--: abbreviation; every other board is a count.
local function formatValue(boardId, value)
	if boardId == "power" then
		return Format.abbrev(value)
	end
	return tostring(value or 0)
end

--[[
	A display name for one row. An online player resolves for free; an offline
	one costs a request, hence the pcall -- and a failure is a placeholder
	name, never a broken board. Studio without API access fails every offline
	lookup, which is exactly why the failure path exists.
]]
local function nameFor(userId)
	local online = game.Players:GetPlayerByUserId(userId)
	if online ~= nil then
		return online.DisplayName
	end
	local ok, name = pcall(game.Players.GetNameFromUserIdAsync, game.Players, userId)
	if ok and type(name) == "string" then
		return name
	end
	return "Player " .. tostring(userId)
end

-- =============================== publishing ================================

--[[
	One submit, protected. `Leaderboard.submit` already skips an unchanged
	value and remembers a store that failed to open; the pcall is for
	everything else. A failed submit is not a game failure, so nothing here
	ever raises -- the heartbeat must not die with the leaderboard.
]]
local function submit(boardId, userId, value)
	pcall(Leaderboard.submit, boards[boardId], userId, value)
end

--: Every board a player belongs on, derived from the one state they have.
local function submitAll()
	PlayerStore.forEach(function(state)
		local userId = state.player.UserId
		--: The cap is OrderedDataStore's: above 1e15 the integer is fiction.
		submit("power", userId, math.floor(math.min(state.power, 1e15)))
		submit("floor", userId, state.bestFloor)
		submit("collection", userId, PlayerStore.uniqueCount(state.collection))
		submit("divines", userId, state.divines)
	end)
end

-- =============================== interface =================================

--[[
	One board, freshly read, answered to the player who asked. `force` skips
	the engine's ninety-second read cache: a player pressing refresh asked for
	the board now, not for the board as of a minute ago.
]]
local function onBoardRefresh(player, payload)
	local boardId = payload.board
	local board = EconomyService.boardFor(boardId)
	if board == nil then
		--: Not one of ours is not an error: the wire carries whatever the
		--: client sent, and a wrong name is simply ignored.
		return
	end

	local ok, entries = pcall(Leaderboard.refresh, board, true)
	if not ok or type(entries) ~= "table" then
		--: No store (Studio without API access) reads as an empty board.
		entries = {}
	end

	local mapped = {}
	for index, entry in ipairs(entries) do
		table.insert(mapped, {
			rank = entry.rank or index,
			name = nameFor(entry.userId),
			value = formatValue(boardId, entry.value),
		})
	end

	Net.fire(player, "Board", {
		board = boardId,
		entries = mapped,
		updated = os.time(),
	})
end

-- ================================ ticking ==================================

--[[
	One economy step. `dt` is explicit so a test can step a simulated minute
	in a loop without waiting one; the live caller passes the beat's own
	second. Order is income first, spending second: the auto-roll's
	affordability check should see the second that just landed.
]]
function EconomyService.tick(dt)
	tickCount += 1
	local pushNow = tickCount % PUSH_EVERY == 0

	PlayerStore.forEach(function(state)
		PlayerStore.creditRift(state, state.perSecond * dt)
		RollService.tickAuto(state, os.time())
		if pushNow then
			--: Slow values only. Everything a player just did has already
			--: pushed itself; this is the income ticking up on the HUD.
			PlayerStore.push(state.player)
		end
	end)

	if tickCount % SUBMIT_EVERY == 0 then
		submitAll()
	end
end

-- ================================ lifecycle ================================

function EconomyService.start()
	if started then
		return
	end
	started = true

	Net.on("BoardRefresh", onBoardRefresh)

	--[[
		The heartbeat. One loop for the whole server, and `task.wait` is its
		first statement -- a loop that works before it yields is the shortest
		way to hang the VM it runs on.
	]]
	task.spawn(function()
		while true do
			task.wait(1)
			EconomyService.tick(1)
		end
	end)
end

return EconomyService
