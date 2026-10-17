--!strict
--[[
	Hatch — open a thing, get a thing, want the next thing.

	The most-run loop on Roblox, and the one this repository had every piece of
	and no assembly for. `Progression.CrateRoll` is the weighted draw;
	`Telemetry.funnel` is the measurement; `Progression.Achievements` is the
	collection. Composing them by hand is four modules of wiring somebody has to
	get right, and in thirty-nine games nobody did.

	Every number below came from a measurement
	------------------------------------------

	`forge/kits/halo/.../retention/2026-07-21_*.json` -- a published game, fifty
	new players, a ten-step funnel with times on it. What it says:

	    1 hatch_first_egg   reached 36  72%   at  22s
	    2 equip_pet         reached 29  58%   at  42s
	    3 farm_crystals     reached 24  48%   at  62s
	    4 hatch_another     reached 19  38%   at  82s
	    5 first_fight       reached 15  30%   at 218s   <-- 136 seconds of nothing
	    ...
	    7,8,9              conversion 100%

	Three readings, and each one is a constant in this file:

	  * **28% left before the first hatch, which landed at 22 seconds.** So the
	    first draw is free and immediate. A loop whose first payout is behind a
	    cost loses a quarter of its players before it has shown them anything.

	  * **The steepest loss is a *gap*, not a rate.** Step four to five converts
	    at 79% -- healthy -- and the time jumps 82s to 218s. `MAX_DEAD_SECONDS`
	    exists because of that number, and `Hatch:check()` reports a violation
	    rather than waiting for players to find it.

	  * **After minute five, conversion is 100%.** The game was never the
	    problem. Everything that matters happens in the first ninety seconds,
	    which is what `EARLY_WINDOW_SECONDS` bounds.

	And 74% of new players left before earning level 2, which is why `tier2At`
	is a required parameter rather than an option: a loop whose second rung is
	unreachable in a first session is a loop with one rung.

	Theme is nouns
	--------------

		Hatch.new({ noun = "egg", verb = "hatch", drops = ... })
		Hatch.new({ noun = "anime egg", verb = "crack", drops = ... })

	Same loop, same numbers, different game. That is the thing the production
	pipeline could not express: nineteen generated games share one structure and
	differ only in an item list, which is this mistake with the halves swapped.
]]

local CrateRoll = require(script.Parent.Parent.Progression.CrateRoll)
local Telemetry = require(script.Parent.Parent.Telemetry)

local Hatch = {}
Hatch.__index = Hatch

--: The first payout must land inside this, and it must cost nothing.
--: 28% of halo's new players left before a first hatch that landed at 22s.
local FIRST_PAYOUT_SECONDS = 40

--: The longest a player may go with nothing happening.
--:
--: Not a round number: halo's one fatal gap was 136 seconds and its healthy
--: ones were 17-49. Ninety is above every gap that kept players and below the
--: one that did not.
local MAX_DEAD_SECONDS = 90

--: Everything that decides retention happened before this mark. After it,
--: halo converted at 100% for three consecutive steps.
local EARLY_WINDOW_SECONDS = 90

--: The funnel every Hatch loop declares, in order.
--:
--: Fixed rather than configurable, because the point of a Loop is that two
--: games built on it produce *comparable* funnels. A game free to rename its
--: steps produces a report nothing can be learned across.
local STEPS = {
	"first_open",      -- the free one
	"first_keep",      -- they did something with what they got
	"second_open",     -- they came back to the loop
	"first_rare",      -- the draw that is worth telling somebody about
	"collection_seen", -- they looked at what they have: the reason to return
	"tier_two",        -- the rung 74% of halo's players never reached
}

export type Theme = {
	noun: string,      -- "egg", "anime egg", "crate"
	verb: string?,     -- "hatch", "crack", "open"
	collection: string?,
}

export type Config = {
	theme: Theme,
	drops: { { id: string, weight: number, rarity: number } },
	--: When the second rung becomes reachable, in seconds of play. Required:
	--: 74% of halo's new players left before earning level 2.
	tier2At: number,
	pityThreshold: number?,
	minRarityForPity: number?,
	funnel: string?,
	onReveal: ((subject: string, drop: any, rarity: number) -> ())?,
}

export type Self = {
	theme: Theme,
	--: `crateFor` is a *method*, so it is deliberately not a field here. Naming
	--: it in the type shadows `Hatch.crateFor`, and `loop:crateFor(x)` then
	--: calls the field -- which `forge doctor` caught in this very file.
	crates: { [string]: any },
	crateConfig: any,
	funnel: string,
	tier2At: number,
	opened: { [string]: number },
	firstOpenAt: { [string]: number },
	lastEventAt: { [string]: number },
	onReveal: ((subject: string, drop: any, rarity: number) -> ())?,
}

--[[
	Build the loop, and declare its funnel in the same call.

	The declaration is not optional and not the caller's job. Two games are
	published from this repository and neither can say whether anybody stayed,
	because declaring a funnel was something a game had to remember. Here it
	happens because the loop exists.
]]
function Hatch.new(config: Config): Self
	assert(config.theme and config.theme.noun, "a Hatch loop needs a theme.noun")
	assert(config.drops and #config.drops > 0, "a Hatch loop needs drops")
	assert(config.tier2At and config.tier2At > 0,
		"a Hatch loop needs tier2At: 74% of new players in the only real "
		.. "retention record here left before reaching a second rung, so when "
		.. "it becomes reachable is a decision, not a default")

	local name = config.funnel or "hatch"
	Telemetry.defineFunnel(name, STEPS)

	local self: Self = setmetatable({
		theme = config.theme,
		funnel = name,
		tier2At = config.tier2At,
		--[[
			One crate per player, not one per loop.

			`CrateRoll` keeps its pity counter on the crate, which is correct
			for a crate and wrong for a loop: the counter exists to say *this
			player* has had a bad run, and a shared one pays somebody else's
			bad luck out to whoever opens next.

			Measured on the first version of this file, twelve different
			players opening once each:

			    rarities  1 1 1 1 1 1 1 1 1 3 1 1
			                                ^ player 10, paid for by 1-9

			That is worse than no pity timer. It makes the payout arrive for a
			player who has seen one common, and never for the player the
			mechanism was built to keep.
		]]
		crates = {},
		crateConfig = {
			drops = config.drops,
			--: A run of commons is where somebody closes the game. Ten is
			--: halo's own cadence; below that the rare stops being rare.
			pityThreshold = config.pityThreshold or 10,
			minRarityForPity = config.minRarityForPity or 3,
		},
		opened = {},
		firstOpenAt = {},
		lastEventAt = {},
		onReveal = config.onReveal,
	}, Hatch) :: any
	return self
end

--: This player's own crate, and its own pity counter.
function Hatch.crateFor(self: Self, subject: string): any
	local found = self.crates[subject]
	if found == nil then
		found = CrateRoll.new(self.crateConfig)
		self.crates[subject] = found
	end
	return found
end

--: What to call the thing, so a caller never hardcodes "egg".
function Hatch.label(self: Self): string
	local verb = self.theme.verb or "open"
	return verb .. " " .. self.theme.noun
end

--[[
	Whether this player's first payout is still free.

	The whole of the first-hatch finding, as a function a caller can branch on
	rather than a rule in a comment.
]]
function Hatch.isFree(self: Self, subject: string): boolean
	return (self.opened[subject] or 0) == 0
end

--[[
	One draw, with the funnel and the reveal attached.

	Returns the drop and the step it moved the player to, so a caller can show
	the right thing without recomputing what just happened.
]]
function Hatch.open(self: Self, subject: string, rng: (() -> number)?): (any, number)
	Telemetry.seen(subject)
	local now = os.time()
	local count = (self.opened[subject] or 0) + 1
	self.opened[subject] = count
	if self.firstOpenAt[subject] == nil then
		self.firstOpenAt[subject] = now
	end
	self.lastEventAt[subject] = now

	local drop = self:crateFor(subject):roll(rng or math.random)

	local step = 0
	if count == 1 then
		step = 1
		Telemetry.funnel(self.funnel, 1, subject)
	elseif count == 2 then
		step = 3
		Telemetry.funnel(self.funnel, 3, subject)
	end

	--: The draw worth telling somebody about. Marked separately from the
	--: count, because a player whose second open was legendary and one whose
	--: fortieth was are different players and the funnel has to see both.
	if (drop.rarity or 1) >= 3 then
		Telemetry.funnel(self.funnel, 4, subject)
		if step < 4 then
			step = 4
		end
	end

	if self.onReveal then
		--: The moment. A draw with no reveal is a number changing, and a
		--: number changing is not why anybody opens the next one.
		self.onReveal(subject, drop, drop.rarity or 1)
	end
	return drop, step
end

--: They did something with what they got: equipped, placed, used.
function Hatch.kept(self: Self, subject: string)
	self.lastEventAt[subject] = os.time()
	Telemetry.funnel(self.funnel, 2, subject)
end

--: They looked at the collection. In every game of this shape the collection
--: is the reason to come back, and a player who never opens it has not been
--: given one.
function Hatch.sawCollection(self: Self, subject: string)
	self.lastEventAt[subject] = os.time()
	Telemetry.funnel(self.funnel, 5, subject)
end

--: The rung 74% of halo's new players never reached.
function Hatch.reachedTierTwo(self: Self, subject: string)
	self.lastEventAt[subject] = os.time()
	Telemetry.funnel(self.funnel, 6, subject)
end

--[[
	Is this loop breaking its own rules, right now, for this player.

	The findings are the three the halo funnel names, checked live rather than
	discovered in a report a month later. A caller runs this on a tick and acts
	on what comes back -- an idle prompt, a free draw, an unlocked rung.
]]
function Hatch.check(self: Self, subject: string): { { rule: string, detail: string } }
	local findings = {}
	local now = os.time()
	local seen = self.firstOpenAt[subject]

	if seen == nil then
		if Telemetry.hasMark(subject, "hatch.joined") == false then
			Telemetry.mark(subject, "hatch.joined")
		end
	elseif now - seen > FIRST_PAYOUT_SECONDS and (self.opened[subject] or 0) == 0 then
		table.insert(findings, {
			rule = "first_payout_late",
			detail = string.format(
				"%ds without a first %s; 28%% of new players left before one "
				.. "that landed at 22s", now - seen, self.theme.noun),
		})
	end

	local last = self.lastEventAt[subject]
	if last ~= nil and now - last > MAX_DEAD_SECONDS then
		table.insert(findings, {
			rule = "dead_time",
			detail = string.format(
				"%ds with nothing happening; the one fatal gap in the only real "
				.. "retention record here was 136s and its healthy ones were "
				.. "17-49s", now - last),
		})
	end

	if seen ~= nil and now - seen > self.tier2At
		and not Telemetry.hasMark(subject, "hatch.tier2." .. subject) then
		table.insert(findings, {
			rule = "tier_two_unreached",
			detail = string.format(
				"past tier2At (%ds) and still on the first rung; 74%% of new "
				.. "players never reached a second one", self.tier2At),
		})
	end
	return findings
end

--: What this loop is, for a validator and for a reader.
function Hatch.describe(self: Self): { [string]: any }
	return {
		loop = "hatch",
		label = self:label(),
		noun = self.theme.noun,
		funnel = self.funnel,
		steps = STEPS,
		tier2At = self.tier2At,
		firstPayoutSeconds = FIRST_PAYOUT_SECONDS,
		maxDeadSeconds = MAX_DEAD_SECONDS,
		earlyWindowSeconds = EARLY_WINDOW_SECONDS,
		subjects = (function()
			local total = 0
			for _ in self.opened do
				total += 1
			end
			return total
		end)(),
	}
end

Hatch.STEPS = STEPS
Hatch.FIRST_PAYOUT_SECONDS = FIRST_PAYOUT_SECONDS
Hatch.MAX_DEAD_SECONDS = MAX_DEAD_SECONDS
Hatch.EARLY_WINDOW_SECONDS = EARLY_WINDOW_SECONDS

return Hatch
