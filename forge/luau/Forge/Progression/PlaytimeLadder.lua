--!strict
--[[
	PlaytimeLadder — rewards for time spent, without paying people to be absent.

	`DailyRewardCalendar` rewards coming back on consecutive days.	This rewards
	staying once you are here: a ladder of milestones at five minutes, fifteen,
	thirty, an hour, each with something at the top of it.

		local ladder = PlaytimeLadder.define("session", {
			scope = "session",
			rungs = {
				{ at = 300, reward = { coins = 100 } },
				{ at = 900, reward = { coins = 300 } },
				{ at = 1800, reward = { gems = 5 } },
			},
		})

		local state = PlaytimeLadder.begin(ladder, saved)
		PlaytimeLadder.tick(ladder, state, dt, active)   -- each frame or second
		for _, rung in PlaytimeLadder.claimable(ladder, state) do ... end

	Written rather than salvaged
	----------------------------

	Unlike most of this engine, this one has no shipped antecedent: none of the
	production games read for it had a session-time ladder, so nothing here is
	somebody else's hard-won tuning and it should not be presented as such. What
	it does carry across is the shape of the reward systems that *were* there --
	claim rather than grant, persist the claim not the timer, keep the policy
	pure and testable -- plus one problem those systems did not have to solve.

	The AFK problem is the whole design
	-----------------------------------

	A ladder that counts wall-clock time pays players for leaving the game open
	on a second monitor. Every serious implementation of this eventually grows
	an idle check, and bolting one on afterwards is how you end up with a timer
	that behaves differently in three places.

	So `tick` takes an `active` flag and **the caller decides what active
	means** -- moving, clicking, being in combat, not being in the lobby. This
	module will not guess, because the answer differs per game and a wrong guess
	silently either pays AFK farmers or punishes someone reading a quest log.

	Two things make it usable rather than merely correct:

	  * **Grace.** Idleness has to persist before the clock stops. Without it,
	    a player who stands still to read a sign loses credit for the pause, and
	    the ladder feels like it is cheating them.
	  * **A cap on the drift.** Once idle beyond the grace, time stops
	    accumulating entirely rather than accumulating slowly. Half credit for
	    being away is still a reason to be away.

	Claim, do not grant
	-------------------

	Reaching a rung makes it *claimable*; it does not hand anything over. A
	reward granted at the moment of arrival lands while the player is mid-fight,
	mid-menu or mid-cutscene, and a grant that nobody sees may as well not have
	happened. The claim is also the thing worth persisting -- see below.

	Persist the claim, not the clock
	--------------------------------

	Save which rungs are claimed and, for lifetime ladders, the accumulated
	total. Never save "seconds until the next rung": that is derived, and a
	derived value in a save file is a value that will one day disagree with what
	it was derived from.
]]

local PlaytimeLadder = {}

local ladders: { [string]: any } = {}

export type Rung = {
	--: Seconds of accumulated active time this rung sits at.
	at: number,
	--: Whatever the game hands out. Opaque here on purpose.
	reward: any,
	id: string?,
}

export type Config = {
	--: "session" resets every join; "lifetime" accumulates across all of them.
	--: A daily ladder is `lifetime` with the caller clearing it at rollover --
	--: this does not own the calendar, `DailyRewardCalendar` does.
	scope: string?,
	rungs: { Rung }?,
	--: Seconds of continuous idleness before the clock stops. Short enough to
	--: refuse AFK farming, long enough to survive reading something.
	graceSeconds: number?,
	--: Start again from the bottom once the last rung is claimed. For endless
	--: "every ten minutes" ladders.
	loop: boolean?,
}

export type State = {
	--: Accumulated *active* seconds. The only number that matters.
	elapsed: number,
	--: Rung ids already handed over. Persisted.
	claimed: { [string]: boolean },
	--: How long the player has been continuously idle. Never persisted; a
	--: session boundary resets it by definition.
	idleFor: number,
	--: Times the ladder has been completed, when looping.
	loops: number,
}

local DEFAULT_GRACE = 20

-- Claim returns the stored reward. A later edit of that table would
-- rewrite what the next claim hands out. A number stays a number.
local function deepCopy(value: any, seen: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in value :: { [any]: any } do
		copy[key] = deepCopy(item, seen)
	end
	return copy
end

local function rungId(rung: Rung, index: number): string
	-- "" is truthy, so `or` would keep it. claim("") then takes the rung,
	-- and two empty ids share one claimed flag.
	if rung.id == nil then
		return "rung" .. index
	end
	assert(type(rung.id) == "string" and #rung.id > 0, "rung id must be a non-empty string")
	return rung.id
end

--[[
	Register a ladder. Rungs are sorted by time, so a caller may list them in
	any order and a generated ladder needs no discipline about it.
]]
function PlaytimeLadder.define(id: string, config: Config?): any
	-- "" is a real key. get("") returns that ladder, and a second define("") overwrites it.
	assert(type(id) == "string" and #id > 0, "ladder id must be a non-empty string")
	-- A second define replaces the first, so get pays the new reward.
	assert(ladders[id] == nil, "ladder id is already registered")
	-- A config of 1 is truthy, so `or {}` would keep it. Reading rungs then
	-- throws without saying the config was wrong. Nil still means no rungs.
	local settings = {}
	if config ~= nil then
		assert(type(config) == "table", "config must be a table")
		settings = config
	end
	local rungs: { Rung } = {}
	for index, rung in settings.rungs or {} do
		-- 0 >= -1, so a negative rung is claimable before any time is spent.
		assert(
			type(rung.at) == "number" and rung.at >= 0 and rung.at < math.huge,
			"rung.at must be a finite number >= 0"
		)
		table.insert(rungs, {
			at = rung.at,
			reward = deepCopy(rung.reward, {}),
			id = rungId(rung, index),
		})
	end
	-- claim returns the first match, so a repeated id can never be taken.
	local seenId: { [string]: boolean } = {}
	for _, copied in rungs do
		local id = copied.id :: string
		assert(seenId[id] ~= true, "duplicate rung id")
		seenId[id] = true
	end
	table.sort(rungs, function(a, b)
		return a.at < b.at
	end)

	-- -1 is truthy, so `or 20` would keep it. The first idle second then
	-- already passes grace and the clock stops. 0 stays and means no grace.
	local grace = DEFAULT_GRACE
	if settings.graceSeconds ~= nil then
		grace = settings.graceSeconds
	end
	assert(type(grace) == "number" and grace >= 0, "graceSeconds must be a number >= 0")
	-- "nope" is truthy, so `or "session"` would keep it. begin only restores
	-- elapsed for "lifetime", so any other word silently drops saved time.
	local scope = if settings.scope == nil then "session" else settings.scope
	assert(scope == "session" or scope == "lifetime", "scope must be session or lifetime")
	local ladder = {
		id = id,
		scope = scope,
		grace = grace,
		loop = settings.loop == true,
		rungs = rungs,
	}
	ladders[id] = ladder
	return ladder
end

function PlaytimeLadder.get(id: string): any?
	return ladders[id]
end

--[[
	A fresh state, or one restored from a save.

	A session ladder ignores any saved elapsed time -- that is what makes it a
	session ladder -- but still honours saved claims, so a game can switch a
	ladder from lifetime to session without players re-earning what they had.
]]
function PlaytimeLadder.begin(ladder: any, saved: any?): State
	local restored = saved or {}
	local claimed = {}
	-- A saved 1 is truthy, so `or {}` would keep it and the loop throws.
	local savedClaimed = if type(restored.claimed) == "table" then restored.claimed else {}
	for key, value in savedClaimed do
		if value then
			claimed[key] = true
		end
	end
	-- NaN is truthy, so `or 0` would keep it. Later comparisons are false
	-- and the ladder never reaches a rung.
	local elapsed = 0
	if ladder.scope == "lifetime" then
		local savedElapsed = restored.elapsed
		if
			type(savedElapsed) == "number"
			and savedElapsed == savedElapsed
			and savedElapsed >= 0
			and savedElapsed < math.huge
		then
			elapsed = savedElapsed
		end
	end
	-- NaN is truthy, so `or 0` would keep a saved loop count that can never
	-- be compared with a real completion.
	local loops = 0
	local savedLoops = restored.loops
	if
		type(savedLoops) == "number"
		and savedLoops == savedLoops
		and savedLoops >= 0
		and savedLoops < math.huge
	then
		loops = savedLoops
	end
	return {
		elapsed = elapsed,
		claimed = claimed,
		idleFor = 0,
		loops = loops,
	}
end

--: What to persist. Deliberately not the whole state: `idleFor` is meaningless
--: across a session boundary and saving it would only invite it being trusted.
function PlaytimeLadder.save(ladder: any, state: State): any
	return {
		elapsed = if ladder.scope == "lifetime" then state.elapsed else nil,
		claimed = state.claimed,
		loops = state.loops,
	}
end

--[[
	Advance the clock.

	`active` is the game's own judgement, and the reason this module refuses to
	form one. Passing `true` unconditionally gives a wall-clock ladder, which is
	a legitimate choice for a game where merely being present is the point.

	Returns the seconds actually credited, which is `dt` or zero. Callers that
	want to show "paused" in a HUD read it rather than re-deriving the idle rule.
]]
function PlaytimeLadder.tick(ladder: any, state: State, dt: number, active: boolean?): number
	-- A negative step rewinds a rung already earned. NaN and infinity are
	-- the same kind of step, so only a finite dt of at least 0 is credited.
	if type(dt) ~= "number" or dt ~= dt or dt < 0 or not (dt < math.huge) then
		dt = 0
	end
	if active == false then
		state.idleFor += dt
		--: Grace: brief stillness still counts. Only sustained idleness stops
		--: the clock, so standing still to read something is not punished.
		if state.idleFor > ladder.grace then
			return 0
		end
	else
		state.idleFor = 0
	end

	state.elapsed += dt
	return dt
end

--: True while the clock is stopped, for a HUD that wants to say so. A ladder
--: that pauses silently reads as broken rather than as working correctly.
function PlaytimeLadder.isPaused(ladder: any, state: State): boolean
	return state.idleFor > ladder.grace
end

--[[
	Rungs reached but not yet taken, in order.

	Returned rather than granted, and returning the whole list rather than one
	matters: a player who was away for the last three milestones should see all
	three waiting, not collect them one join at a time.
]]
function PlaytimeLadder.claimable(ladder: any, state: State): { Rung }
	local out: { Rung } = {}
	for _, rung in ladder.rungs do
		if state.elapsed >= rung.at and not state.claimed[rung.id :: string] then
			-- claimAll reads `id` off this list. The reward is the ladder's
			-- own table, so a listing must not be able to rewrite the claim.
			table.insert(out, {
				at = rung.at,
				id = rung.id,
				reward = deepCopy(rung.reward, {}),
			})
		end
	end
	return out
end

--[[
	Take one rung. Returns its reward, or nil if it was not available.

	Nil covers both "not reached yet" and "already taken", and the caller does
	not need to tell them apart: in either case nothing is owed. Checking the
	claim inside here rather than trusting the caller is what makes a double
	click harmless.
]]
function PlaytimeLadder.claim(ladder: any, state: State, id: string): any?
	for _, rung in ladder.rungs do
		if rung.id == id then
			if state.elapsed < rung.at or state.claimed[id] then
				return nil
			end
			state.claimed[id] = true

			--: Looping ladders wind back once the top rung is taken, so an
			--: "every ten minutes" ladder needs no special-casing by the game.
			if ladder.loop and #ladder.rungs > 0 then
				local top = ladder.rungs[#ladder.rungs]
				if id == top.id then
					state.elapsed -= top.at
					state.claimed = {}
					state.loops += 1
				end
			end
			return deepCopy(rung.reward, {})
		end
	end
	return nil
end

--: Everything outstanding at once, for a "collect all" button.
function PlaytimeLadder.claimAll(ladder: any, state: State): { any }
	local rewards = {}
	--: Snapshotted first: `claim` may reset `claimed` on a looping ladder, and
	--: iterating the live list while it does that skips rungs.
	local pending = PlaytimeLadder.claimable(ladder, state)
	for _, rung in pending do
		local reward = PlaytimeLadder.claim(ladder, state, rung.id :: string)
		if reward ~= nil then
			table.insert(rewards, reward)
		end
	end
	return rewards
end

--[[
	The next rung and the seconds until it, for a countdown.

	Returns nil when every rung is claimed and the ladder does not loop, which
	is a real state a HUD should render as "done" rather than as a stuck timer.
]]
function PlaytimeLadder.next(ladder: any, state: State): (Rung?, number?)
	for _, rung in ladder.rungs do
		if not state.claimed[rung.id :: string] then
			-- progress reads `at` off this return. The reward is the ladder's
			-- own table, so a peek must not be able to rewrite the claim.
			return {
				at = rung.at,
				id = rung.id,
				reward = deepCopy(rung.reward, {}),
			}, math.max(0, rung.at - state.elapsed)
		end
	end
	return nil, nil
end

--: Progress toward the next rung, 0..1, for a bar. One when nothing is left.
function PlaytimeLadder.progress(ladder: any, state: State): number
	local rung, remaining = PlaytimeLadder.next(ladder, state)
	if not rung then
		return 1
	end

	--: Measured from the previous rung, not from zero, or every bar after the
	--: first starts most of the way full and barely appears to move.
	local previous = 0
	for _, candidate in ladder.rungs do
		if candidate.at < rung.at then
			previous = math.max(previous, candidate.at)
		end
	end
	local span = rung.at - previous
	if span <= 0 then
		return 1
	end
	return math.clamp(1 - (remaining or 0) / span, 0, 1)
end

function PlaytimeLadder.describe(): { [string]: any }
	local list = {}
	for id, ladder in ladders do
		list[id] = {
			scope = ladder.scope,
			rungs = #ladder.rungs,
			loop = ladder.loop,
			graceSeconds = ladder.grace,
		}
	end
	return { ladders = list }
end

return PlaytimeLadder
