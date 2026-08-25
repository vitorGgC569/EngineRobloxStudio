--!strict
--[[
	Clock — one time, agreed on by every server and every client.

	Why a game needs this and `os.time()` is not it
	----------------------------------------------

	`os.time()` is the machine's clock, and a live game runs on dozens of
	machines. Three questions break immediately without a single answer:

	  **When does "today" end?** A daily reward that rolls over at the player's
	  local midnight rolls over at a different moment for every player, and one
	  who flies to Tokyo claims twice. Days are UTC or they are not days.

	  **What is today's shop?** Two servers rolling their own random stock give
	  two players different shops on the same day, and the first thing they do
	  is compare screenshots. A day plus a salt seeds it, and every server on
	  Earth derives the same list without talking to any other.

	  **Has this expired?** A buff stored as "twelve hours from now" is stored
	  against whichever clock wrote it. Stored as an absolute UTC instant, it
	  means the same thing when it is read.

		Clock.now()                          -- server time, one source
		Clock.dayNumber()                    -- UTC day, the rollover unit
		Clock.untilNextDay()                 -- for a countdown that is honest
		Clock.dailySeed("shop")              -- same everywhere, all day
		Clock.expiresIn(3600)                -- an absolute instant, not a duration
		Clock.hasExpired(stamp)

	Clients and drift
	-----------------

	`Clock.sync` hands a client the server's time along with the round trip, so
	the client can hold its own offset and stop asking. It is not precision
	timing — it is close enough that a countdown does not disagree with the
	server by a visible second, which is the only thing anybody notices.
]]

local RunService = game:GetService("RunService")

local Clock = {}

--: Seconds in a day. Named because `86400` in an expression is a number
--: somebody has to recognise, and it is the unit this whole module turns on.
local DAY = 86400

--[[
	The offset between this machine and the authority.

	Zero on the server, which *is* the authority. On a client it is whatever
	`sync` measured, so `now()` means the same thing on both sides of the wire.
]]
local offset = 0
local syncedAt: number? = nil

-- ==================================== now ===================================
--[[
	The time, as the server understands it.

	`os.time()` rather than `tick()` or `os.clock()`: this is a wall-clock
	instant that gets written to a DataStore and read back next week, and the
	other two are process-relative and meaningless the moment the server dies.
]]
function Clock.now(): number
	return os.time() + offset
end

--[[
	The same instant with sub-second resolution, for measuring rather than
	storing. Never persist this — `os.clock` is uptime, not a date.
]]
function Clock.precise(): number
	return os.clock()
end

-- ==================================== days ==================================
--[[
	Which UTC day it is, as a whole number.

	The rollover unit for everything daily. Comparing day numbers is how you
	ask "is this from today" without any date arithmetic, and it is stable
	across servers because UTC is the same everywhere by construction.
]]
function Clock.dayNumber(at: number?): number
	return math.floor((at or Clock.now()) / DAY)
end

function Clock.dayStart(at: number?): number
	return Clock.dayNumber(at) * DAY
end

--[[
	Seconds until the next UTC midnight.

	For a countdown a player can trust. Computed from the day boundary rather
	than counted down in a loop, so a server that stuttered for four seconds
	still says the right thing.
]]
function Clock.untilNextDay(at: number?): number
	local now = at or Clock.now()
	return (Clock.dayNumber(now) + 1) * DAY - now
end

--[[
	A number that is the same on every server all day, and different tomorrow.

	The mechanism behind a daily shop, a rotating quest set, a featured item:
	seed a `Random` with this and every server independently produces the same
	list. No messaging, no shared state, no drift — the day and the salt are
	the only inputs, and both are already agreed.

	The salt keeps unrelated systems from rotating in lockstep. Without it the
	shop, the quests and the featured pet all roll the same sequence and a
	player notices the pattern within a week.
]]
function Clock.dailySeed(salt: string, at: number?): number
	local day = Clock.dayNumber(at)
	--[[
		FNV-1a over the salt, mixed with the day.

		A hash rather than `#salt` or a byte sum, because those collide on
		anagrams and near-misses — "shop" and "shops" must not share a
		sequence, and with a length-based seed they would.
	]]
	local hash = 2166136261
	for index = 1, #salt do
		hash = bit32.bxor(hash, string.byte(salt, index))
		hash = (hash * 16777619) % 4294967296
	end
	return (hash + day * 2654435761) % 2147483647
end

--: A `Random` already seeded for today. The form most callers actually want.
function Clock.dailyRandom(salt: string, at: number?): Random
	return Random.new(Clock.dailySeed(salt, at))
end

--[[
	Which week it is, counted from a UTC Monday.

	Unix epoch day 0 was a Thursday, so the shift by four is what makes weeks
	start on Monday rather than three days into one.
]]
function Clock.weekNumber(at: number?): number
	return math.floor((Clock.dayNumber(at) + 4) / 7)
end

-- ================================= expiring =================================
--[[
	Turn a duration into an instant.

	Storing "3600" means "an hour from whenever this is read", which is a bug
	that only appears after a restart. Storing the instant means the same thing
	for ever.
]]
function Clock.expiresIn(seconds: number, at: number?): number
	return (at or Clock.now()) + seconds
end

function Clock.hasExpired(stamp: number?, at: number?): boolean
	if not stamp then
		-- No expiry is not an expiry. A nil here is "permanent", and treating
		-- it as expired silently deletes everything that has no deadline.
		return false
	end
	return (at or Clock.now()) >= stamp
end

--: Seconds left, never negative — a countdown that goes below zero renders as
--: "-00:03 remaining" and every UI has to clamp it anyway.
function Clock.remaining(stamp: number?, at: number?): number
	if not stamp then
		return math.huge
	end
	return math.max(0, stamp - (at or Clock.now()))
end

--[[
	`1h 04m`, for a UI.

	Two units, largest first: `2d 06h` rather than `2d 6h 14m 3s`. A countdown
	with four units is read as noise, and the last two never matter at the
	moment somebody is looking at the first.
]]
function Clock.format(seconds: number): string
	if seconds >= math.huge then
		return "never"
	end
	seconds = math.max(0, math.floor(seconds))
	local days = seconds // DAY
	local hours = (seconds % DAY) // 3600
	local minutes = (seconds % 3600) // 60

	if days > 0 then
		return string.format("%dd %02dh", days, hours)
	elseif hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	elseif minutes > 0 then
		return string.format("%dm %02ds", minutes, seconds % 60)
	end
	return string.format("%ds", seconds)
end

-- ================================== syncing =================================
--[[
	What the server sends a client so it can stop asking.

	The round trip is included so the client can allow for the half of it that
	the answer spent in flight.
]]
function Clock.stamp(): { serverTime: number, sentAt: number }
	return { serverTime = Clock.now(), sentAt = os.clock() }
end

--[[
	Adopt the server's clock on a client.

	`roundTrip / 2` is the standard approximation: the answer is that old by
	the time it arrives, assuming the trip was symmetric. It is not, quite, but
	the error is milliseconds and the thing being corrected is a clock that
	could be minutes out.

	Refused on the server, where adopting an offset would mean the authority
	deferring to somebody else's idea of the time.
]]
function Clock.adopt(serverTime: number, roundTrip: number): boolean
	if RunService:IsServer() then
		return false
	end
	offset = (serverTime + roundTrip / 2) - os.time()
	syncedAt = os.clock()
	return true
end

function Clock.describe(): { [string]: any }
	return {
		now = Clock.now(),
		day = Clock.dayNumber(),
		week = Clock.weekNumber(),
		untilNextDay = math.floor(Clock.untilNextDay()),
		offsetSeconds = math.floor(offset * 1000) / 1000,
		syncedSecondsAgo = syncedAt and math.floor(os.clock() - syncedAt) or nil,
		authority = RunService:IsServer() and "server" or (syncedAt and "synced" or "unsynced"),
	}
end

return Clock
