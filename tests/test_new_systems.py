"""Behaviour of the systems added to close the 19-system inventory.

These execute the shipped Luau rather than inspecting it. That distinction has
earned its keep in this project: every defect worth finding here was in code
that type-checked and had never run.

Only the pure modules are covered. `Weapon.Validate.origin` raycasts and
`Weapon.Stance.read` reads a Humanoid, so both are exercised against a real
character inside Studio instead -- there is no point asserting against a shim
that a raycast the shim does not perform returns what we hoped.
"""

from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

from rqe.luau_check import ToolchainUnavailable, ensure_compiler
from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge" / "luau" / "Forge"

#: Copied into one flat directory rather than passing the family folders. The
#: harness namespace is flat and a family folder would drag in every sibling,
#: including inits that require modules this has no reason to load.
UNDER_TEST = (
    FORGE / "Companion" / "Formation.lua",
    FORGE / "Companion" / "Meander.lua",
    FORGE / "Weapon" / "Stance.lua",
    FORGE / "Weapon" / "Sway.lua",
    FORGE / "Weapon" / "Validate.lua",
    FORGE / "LiveOps" / "Luck.lua",
    FORGE / "Progression" / "PlaytimeLadder.lua",
    FORGE / "Progression" / "IncomeTracker.lua",
)


#: A flat JSON encoder for test results, injected into every body. Sorted keys
#: so a failure diff is stable, and it deliberately handles only scalars and
#: flat arrays -- anything deeper is a sign the assertion wants splitting.
_EMIT = """
local function _encode(value)
	local kind = type(value)
	if kind == "number" then
		--: %.10g rather than tostring: Luau prints large integers in exponent
		--: form, which is not valid JSON.
		if value ~= value or value == math.huge or value == -math.huge then
			return "null"
		end
		return string.format("%.10g", value)
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind == "nil" then
		return "null"
	elseif kind == "string" then
		return '"' .. value:gsub('[\\\\"]', '\\%0') .. '"'
	elseif kind == "table" then
		local parts = {}
		for _, item in ipairs(value) do
			table.insert(parts, _encode(item))
		end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	return "null"
end

local function emit(fields)
	local keys = {}
	for key in fields do
		table.insert(keys, key)
	end
	table.sort(keys)
	local parts = {}
	for _, key in keys do
		table.insert(parts, '"' .. key .. '":' .. _encode(fields[key]))
	end
	print("{" .. table.concat(parts, ",") .. "}")
end
"""


class NewSystemsCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        try:
            ensure_compiler(ROOT)
        except ToolchainUnavailable as exc:
            raise AssertionError(f"Luau runtime unavailable: {exc}") from exc

        cls._temp = tempfile.TemporaryDirectory()
        cls.library = Path(cls._temp.name) / "UnderTest"
        cls.library.mkdir()
        for source in UNDER_TEST:
            shutil.copy2(source, cls.library / source.name)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temp.cleanup()

    def values(self, requires: str, body: str) -> dict:
        """Run `body` with the named modules required, and decode what it printed.

        `emit` is supplied rather than `HttpService`, which the harness shim does
        not implement -- these modules are pure and never ask for a service, so
        shimming one just to serialise a test result would be shimming for the
        test's convenience rather than for the code's needs.
        """
        preamble = "\n".join(
            f'local {name} = Require("{name}")' for name in requires.split()
        )
        result = run_or_raise(
            ROOT, libraries=[self.library], body=f"{preamble}\n{_EMIT}\n{body}")
        decoded = result.json_lines()
        self.assertTrue(decoded, f"{result.stdout}\n{result.stderr}")
        return decoded[-1]

    # ------------------------------------------------------------ Formation
    def test_slots_return_in_caller_order_not_sorted_order(self) -> None:
        """Placement sorts by size; the answer must not be reordered by it.

        A caller holds followers in a stable list and expects slot `i` to belong
        to follower `i`. Who stands where is an internal decision.
        """
        out = self.values("Formation", """
local crew = {
	{ id = "big", footprint = 9, large = true },
	{ id = "small", footprint = 2 },
	{ id = "mid", footprint = 5 },
}
local slots = Formation.resolve(crew, { mode = "conga", floatOffsets = { large = -1.5 } })
emit({
	count = #slots,
	indices = { slots[1].index, slots[2].index, slots[3].index },
	bigZ = slots[1].z, smallZ = slots[2].z, midZ = slots[3].z,
	bigY = slots[1].y,
})
""")
        self.assertEqual(out["count"], 3)
        self.assertEqual(out["indices"], [1, 2, 3])
        # Small in front, large behind: -Z is forward, so the large one is lowest.
        self.assertLess(out["bigZ"], out["midZ"])
        self.assertLess(out["midZ"], out["smallZ"])
        # Large followers sink by their class offset.
        self.assertAlmostEqual(out["bigY"], 0.5, places=6)

    def test_per_id_float_offset_beats_the_size_class(self) -> None:
        out = self.values("Formation", """
local crew = { { id = "tall", footprint = 9, large = true } }
local slots = Formation.resolve(crew,
	{ mode = "conga", floatOffsets = { large = -1.5, byId = { tall = 2 } } })
emit({ y = slots[1].y })
""")
        self.assertAlmostEqual(out["y"], 4.0, places=6)

    def test_separation_pushes_targets_apart_without_mutating_input(self) -> None:
        out = self.values("Formation", """
local stacked = {
	{ x = 0, y = 0, z = 0, index = 1 },
	{ x = 0.2, y = 0, z = 0, index = 2 },
}
local pushed = Formation.separate(stacked, 3)
emit({
	gap = math.abs(pushed[2].x - pushed[1].x),
	originalUntouched = stacked[2].x,
})
""")
        self.assertGreater(out["gap"], 2.5)
        self.assertAlmostEqual(out["originalUntouched"], 0.2, places=6)

    def test_bob_is_out_of_phase_between_followers(self) -> None:
        """One shared oscillator makes a group rise and fall as a single object."""
        out = self.values("Formation", """
emit({
	first = Formation.bob(1, 0.5, 0.5, 2),
	second = Formation.bob(2, 0.5, 0.5, 2),
	zeroPeriod = Formation.bob(1, 1, 0.5, 0),
})
""")
        self.assertNotAlmostEqual(out["first"], out["second"], places=6)
        self.assertEqual(out["zeroPeriod"], 0)

    # -------------------------------------------------------------- Meander
    def test_wander_waits_on_the_leader_and_surrenders_when_they_move(self) -> None:
        """The distinction that makes this read as alive rather than as lag."""
        out = self.values("Meander", """
local state = Meander.new(0.42, nil)
local movingX = Meander.step(state, 0.1, 0, false, nil)

local strolled = false
for _ = 1, 200 do
	local dx, dz = Meander.step(state, 0.1, 99, false, nil)
	if dx ~= 0 or dz ~= 0 then strolled = true break end
end
local afterX = Meander.step(state, 0.1, 0, false, nil)

emit({
	whileLeaderMoves = movingX,
	strolled = strolled,
	afterLeaderMovesAgain = afterX,
	targetCleared = state.targetX == nil,
	whileBusy = Meander.step(Meander.new(1, nil), 0.1, 99, true, nil),
	whileDisabled = Meander.step(Meander.new(1, nil), 0.1, 99, false, { enabled = false }),
})
""")
        self.assertEqual(out["whileLeaderMoves"], 0)
        self.assertTrue(out["strolled"])
        self.assertEqual(out["afterLeaderMovesAgain"], 0)
        self.assertTrue(out["targetCleared"])
        self.assertEqual(out["whileBusy"], 0)
        self.assertEqual(out["whileDisabled"], 0)

    # --------------------------------------------------------------- Stance
    def test_movement_penalties_compound(self) -> None:
        """What stops bunny-hopping from being free accuracy."""
        out = self.values("Stance", """
local rifle = Stance.presets.rifle
emit({
	resting = Stance.multiplier(rifle, nil),
	ads = Stance.multiplier(rifle, { ads = true }),
	sprint = Stance.multiplier(rifle, { sprinting = true }),
	air = Stance.multiplier(rifle, { airborne = true }),
	both = Stance.multiplier(rifle, { sprinting = true, airborne = true }),
})
""")
        self.assertEqual(out["resting"], 1)
        self.assertLess(out["ads"], 1)
        self.assertGreater(out["both"], out["sprint"])
        self.assertGreater(out["both"], out["air"])

    def test_preset_copies_rather_than_aliases_the_class_table(self) -> None:
        """A preset that aliased its class would let one weapon retune every other."""
        out = self.values("Stance", """
local carbine = Stance.preset("rifle", { damage = 24, spread = { min = 2 } })
emit({
	rpm = carbine.rpm,
	damage = carbine.damage,
	overridden = carbine.spread.min,
	siblingKept = carbine.spread.max,
	classUntouched = Stance.presets.rifle.spread.min,
	unknownErrors = not pcall(function() Stance.preset("bazooka") end),
})
""")
        self.assertEqual(out["damage"], 24)
        self.assertEqual(out["overridden"], 2)
        self.assertEqual(out["siblingKept"], 6.0)
        self.assertEqual(out["classUntouched"], 0.9)
        self.assertTrue(out["unknownErrors"])

    def test_shotgun_blooms_least_relative_to_its_own_cone(self) -> None:
        """Absolute bloom is misleading; a shotgun's cone is already its spread."""
        out = self.values("Stance", """
local function relative(class)
	local s = Stance.presets[class].spread
	return s.perShot / s.min
end
emit({
	shotgun = relative("shotgun"), pistol = relative("pistol"),
	rifle = relative("rifle"), smg = relative("smg"),
})
""")
        self.assertLess(out["shotgun"], out["pistol"])
        self.assertLess(out["shotgun"], out["rifle"])
        self.assertLess(out["smg"], out["pistol"])

    # ------------------------------------------------------------------ Sway
    def test_airborne_freezes_the_walk_cycle_rather_than_resetting_it(self) -> None:
        """A weapon that keeps pumping in mid-air is walking on nothing."""
        out = self.values("Sway", """
local bob = Sway.newBob()
local walking = Sway.bob(bob, 0.1, 16, true, nil)
local clockBefore = bob.clock
local firstAir = Sway.bob(bob, 0.1, 16, false, nil)
local secondAir = Sway.bob(bob, 0.5, 16, false, nil)

local still, stillPeak = Sway.newBob(), 0
for _ = 1, 50 do
	stillPeak = math.max(stillPeak, math.abs(Sway.bob(still, 0.1, 0, true, nil)))
end

local slow, fast = Sway.newBob(), Sway.newBob()
local slowPeak, fastPeak = 0, 0
for _ = 1, 30 do
	slowPeak = math.max(slowPeak, Sway.bob(slow, 0.05, 8, true, nil))
	fastPeak = math.max(fastPeak, Sway.bob(fast, 0.05, 24, true, nil))
end

emit({
	walking = walking, firstAir = firstAir, secondAir = secondAir,
	clockHeld = bob.clock == clockBefore,
	stillPeak = stillPeak, slowPeak = slowPeak, fastPeak = fastPeak,
})
""")
        self.assertNotEqual(out["walking"], 0)
        self.assertEqual(out["firstAir"], out["walking"])
        self.assertEqual(out["secondAir"], out["walking"])
        self.assertTrue(out["clockHeld"])
        self.assertAlmostEqual(out["stillPeak"], 0, places=9)
        self.assertGreater(out["fastPeak"], out["slowPeak"])
        # Lopsided clamp: it may drop further than it rises.
        self.assertLessEqual(out["walking"], 0.4 + 1e-9)

    def test_strafe_roll_is_signed_and_saturates(self) -> None:
        out = self.values("Sway", """
emit({
	left = Sway.roll(-10, nil), right = Sway.roll(10, nil),
	none = Sway.roll(0, nil), saturated = Sway.roll(9999, nil),
})
""")
        self.assertLess(out["left"], 0)
        self.assertGreater(out["right"], 0)
        self.assertEqual(out["none"], 0)
        self.assertAlmostEqual(out["saturated"], 2, places=9)

    def test_idle_axes_run_at_different_rates(self) -> None:
        """Equal rates trace one closed figure; unequal ones read as breathing."""
        out = self.values("Sway", """
local p1, y1, r1 = Sway.idle(1.0, 1)
local p2 = Sway.idle(2.0, 1)
emit({
	pitch = p1, yaw = y1, roll = r1, laterPitch = p2,
	silent = select(1, Sway.idle(1.0, 0)),
})
""")
        for axis in ("pitch", "yaw", "roll"):
            self.assertNotEqual(out[axis], 0)
        self.assertNotAlmostEqual(out["pitch"], out["laterPitch"], places=9)
        self.assertEqual(out["silent"], 0)

    def test_recoil_halves_over_a_half_life_and_settles_to_zero(self) -> None:
        out = self.values("Sway", """
emit({
	half = Sway.decay(1, 0.1, 0.1),
	settled = Sway.decay(1, 5, 0.1),
})
""")
        self.assertAlmostEqual(out["half"], 0.5, places=6)
        self.assertEqual(out["settled"], 0)

    # -------------------------------------------------------------- Validate
    def test_only_outrunning_the_weapon_is_treated_as_hostile(self) -> None:
        """Flagging jitter as cheating is how a server bans its own players."""
        out = self.values("Validate", """
local fast = Validate.rate(0, 0.5, 1.0)
emit({
	noReason = Validate.classify(nil).ok,
	reloading = Validate.classify("reloading").hostile,
	empty = Validate.classify("empty").hostile,
	cooldown = Validate.classify("cooldown").hostile,
	fullInterval = Validate.rate(0, 1.0, 1.0).ok,
	insideSlack = Validate.rate(0, 0.95, 1.0).ok,
	doubleRateOk = fast.ok, doubleRateHostile = fast.hostile,
})
""")
        self.assertTrue(out["noReason"])
        self.assertFalse(out["reloading"])
        self.assertFalse(out["empty"])
        self.assertTrue(out["cooldown"])
        self.assertTrue(out["fullInterval"])
        self.assertTrue(out["insideSlack"])
        self.assertFalse(out["doubleRateOk"])
        self.assertTrue(out["doubleRateHostile"])

    def test_suspicion_decays(self) -> None:
        """Without decay every long session trips any threshold on jitter alone."""
        out = self.values("Validate", """
local tracker = Validate.tracker(60)
Validate.flag(tracker, "player", 0)
Validate.flag(tracker, "player", 0)
local immediate = Validate.score(tracker, "player", 0)
local later = Validate.score(tracker, "player", 60)
Validate.forget(tracker, "player")
emit({
	immediate = immediate, afterOneHalfLife = later,
	unknown = Validate.score(tracker, "nobody", 0),
	forgotten = Validate.score(tracker, "player", 0),
})
""")
        self.assertEqual(out["immediate"], 2)
        self.assertAlmostEqual(out["afterOneHalfLife"], 1, places=6)
        self.assertEqual(out["unknown"], 0)
        self.assertEqual(out["forgotten"], 0)

    # ------------------------------------------------------------------ Luck
    def test_luck_arbitrates_and_never_multiplies(self) -> None:
        """Multiplying is how a gacha economy dies: 2 x 3 must be 3, not 6."""
        out = self.values("Luck", """
local best, source = Luck.best({
	{ active = true, multiplier = 2, source = "gamepass" },
	{ active = true, multiplier = 3, source = "potion" },
	{ active = false, multiplier = 9, source = "event" },
})
emit({
	best = best, source = source,
	empty = (Luck.best({})),
	weakIgnored = (Luck.best({ { active = true, multiplier = 0.5 } })),
})
""")
        self.assertEqual(out["best"], 3)
        self.assertEqual(out["source"], "potion")
        self.assertEqual(out["empty"], 1)
        self.assertEqual(out["weakIgnored"], 1)

    def test_collection_luck_pays_for_coverage_not_volume(self) -> None:
        """Raw count rewards grinding one source; coverage rewards breadth."""
        out = self.values("Luck", """
emit({
	none = Luck.fromCompletion(0, 50, 1),
	half = Luck.fromCompletion(25, 50, 2),
	full = Luck.fromCompletion(50, 50, 1),
	overGrind = Luck.fromCompletion(500, 50, 1),
	noDenominator = Luck.fromCompletion(5, 0, 1),
})
""")
        self.assertEqual(out["none"], 1)
        self.assertAlmostEqual(out["half"], 2, places=9)
        self.assertEqual(out["full"], 2)
        # Grinding past completion must not keep paying.
        self.assertEqual(out["overGrind"], 2)
        self.assertEqual(out["noDenominator"], 1)

    def test_luck_reweights_without_mutating_and_renormalisation_softens_it(self) -> None:
        """A 2x weight is not a 2x chance, which is why `effect` exists."""
        out = self.values("Luck", """
local drops = {
	{ id = "common", weight = 90, rarity = 1 },
	{ id = "rare", weight = 9, rarity = 3 },
	{ id = "legendary", weight = 1, rarity = 5 },
}
local lucky = Luck.apply(drops, 2, 3)
local baseOdds, luckyOdds = Luck.odds(drops), Luck.odds(lucky)
emit({
	sourceUntouched = drops[2].weight,
	commonWeight = lucky[1].weight, rareWeight = lucky[2].weight,
	belowThreshold = Luck.apply(drops, 2, 5)[2].weight,
	oddsSum = baseOdds.common + baseOdds.rare + baseOdds.legendary,
	effect = Luck.effect(drops, lucky, "legendary"),
	commonFell = luckyOdds.common < baseOdds.common,
	unknownId = Luck.effect(drops, lucky, "nope"),
})
""")
        self.assertEqual(out["sourceUntouched"], 9)
        self.assertEqual(out["commonWeight"], 90)
        self.assertEqual(out["rareWeight"], 18)
        self.assertEqual(out["belowThreshold"], 9)
        self.assertAlmostEqual(out["oddsSum"], 1, places=9)
        self.assertGreater(out["effect"], 1)
        self.assertLess(out["effect"], 2)
        self.assertTrue(out["commonFell"])
        self.assertEqual(out["unknownId"], 1)

    # -------------------------------------------------------- PlaytimeLadder
    def test_sustained_idleness_stops_the_clock_but_grace_does_not(self) -> None:
        """The AFK question is the design: pay for playing, not for being open."""
        out = self.values("PlaytimeLadder", """
local ladder = PlaytimeLadder.define("session", {
	graceSeconds = 20,
	rungs = { { at = 300, reward = 3 }, { at = 60, reward = 1 }, { at = 900, reward = 9 } },
})
local state = PlaytimeLadder.begin(ladder, nil)
for _ = 1, 60 do PlaytimeLadder.tick(ladder, state, 1, true) end

local insideGrace = PlaytimeLadder.tick(ladder, state, 5, false)
local pausedInsideGrace = PlaytimeLadder.isPaused(ladder, state)
for _ = 1, 5 do PlaytimeLadder.tick(ladder, state, 10, false) end
local frozen = state.elapsed
local afk = PlaytimeLadder.tick(ladder, state, 60, false)
--: Captured here, not inside emit: the resume below moves `elapsed` on, and
--: reading it afterwards would compare the wrong two numbers.
local elapsedHeld = state.elapsed == frozen
local pausedBeyondGrace = PlaytimeLadder.isPaused(ladder, state)

local resumed = PlaytimeLadder.tick(ladder, state, 1, true)

emit({
	sorted = { ladder.rungs[1].at, ladder.rungs[3].at },
	insideGrace = insideGrace, pausedInsideGrace = pausedInsideGrace,
	afkCredited = afk, elapsedHeld = elapsedHeld,
	pausedBeyondGrace = pausedBeyondGrace,
	resumed = resumed, idleCleared = state.idleFor == 0,
})
""")
        self.assertEqual(out["sorted"], [60, 900])
        self.assertEqual(out["insideGrace"], 5)
        self.assertFalse(out["pausedInsideGrace"])
        self.assertEqual(out["afkCredited"], 0)
        self.assertTrue(out["elapsedHeld"])
        self.assertTrue(out["pausedBeyondGrace"])
        self.assertEqual(out["resumed"], 1)
        self.assertTrue(out["idleCleared"])

    def test_claiming_is_once_only_and_a_backlog_arrives_whole(self) -> None:
        """A player away for three milestones should not collect one per join."""
        out = self.values("PlaytimeLadder", """
local ladder = PlaytimeLadder.define("backlog", {
	rungs = { { at = 1, reward = "a" }, { at = 2, reward = "b" }, { at = 3, reward = "c" } },
})
local state = PlaytimeLadder.begin(ladder, nil)
PlaytimeLadder.tick(ladder, state, 10, true)
local waiting = #PlaytimeLadder.claimable(ladder, state)
local first = PlaytimeLadder.claim(ladder, state, ladder.rungs[1].id)
local repeated = PlaytimeLadder.claim(ladder, state, ladder.rungs[1].id)
local rest = PlaytimeLadder.claimAll(ladder, state)

local unreached = PlaytimeLadder.define("far", { rungs = { { at = 999, reward = "z" } } })
local farState = PlaytimeLadder.begin(unreached, nil)
emit({
	waiting = waiting, first = first, repeated = repeated == nil,
	rest = #rest, leftOver = #PlaytimeLadder.claimable(ladder, state),
	unreachable = PlaytimeLadder.claim(unreached, farState, unreached.rungs[1].id) == nil,
})
""")
        self.assertEqual(out["waiting"], 3)
        self.assertEqual(out["first"], "a")
        self.assertTrue(out["repeated"])
        self.assertEqual(out["rest"], 2)
        self.assertEqual(out["leftOver"], 0)
        self.assertTrue(out["unreachable"])

    def test_a_session_ladder_persists_claims_but_never_the_timer(self) -> None:
        """A derived value in a save file will one day disagree with its source."""
        out = self.values("PlaytimeLadder", """
local session = PlaytimeLadder.define("s", { scope = "session",
	rungs = { { at = 10, reward = 1 } } })
local state = PlaytimeLadder.begin(session, nil)
PlaytimeLadder.tick(session, state, 25, true)
PlaytimeLadder.claim(session, state, session.rungs[1].id)
local saved = PlaytimeLadder.save(session, state)
local restored = PlaytimeLadder.begin(session, saved)

local life = PlaytimeLadder.define("l", { scope = "lifetime",
	rungs = { { at = 10, reward = 1 } } })
local lifeState = PlaytimeLadder.begin(life, nil)
PlaytimeLadder.tick(life, lifeState, 25, true)
local lifeSaved = PlaytimeLadder.save(life, lifeState)

emit({
	sessionSavesElapsed = saved.elapsed ~= nil,
	claimPersisted = saved.claimed[session.rungs[1].id] == true,
	restoredElapsed = restored.elapsed,
	restoredClaim = restored.claimed[session.rungs[1].id] == true,
	lifetimeElapsed = lifeSaved.elapsed,
	lifetimeRestored = PlaytimeLadder.begin(life, lifeSaved).elapsed,
})
""")
        self.assertFalse(out["sessionSavesElapsed"])
        self.assertTrue(out["claimPersisted"])
        self.assertEqual(out["restoredElapsed"], 0)
        self.assertTrue(out["restoredClaim"])
        self.assertEqual(out["lifetimeElapsed"], 25)
        self.assertEqual(out["lifetimeRestored"], 25)

    def test_a_looping_ladder_rewinds_and_progress_measures_from_the_last_rung(self) -> None:
        """Measured from zero, every bar past the first starts nearly full."""
        out = self.values("PlaytimeLadder", """
local loop = PlaytimeLadder.define("loop", { loop = true,
	rungs = { { at = 10, reward = "x" } } })
local loopState = PlaytimeLadder.begin(loop, nil)
PlaytimeLadder.tick(loop, loopState, 12, true)
local reward = PlaytimeLadder.claim(loop, loopState, loop.rungs[1].id)

local ladder = PlaytimeLadder.define("bar", {
	rungs = { { at = 60, reward = 1 }, { at = 300, reward = 2 } } })
local state = PlaytimeLadder.begin(ladder, nil)
PlaytimeLadder.tick(ladder, state, 60, true)
PlaytimeLadder.claim(ladder, state, ladder.rungs[1].id)
PlaytimeLadder.tick(ladder, state, 60, true)
local nextRung, remaining = PlaytimeLadder.next(ladder, state)

local done = PlaytimeLadder.define("done", { rungs = { { at = 1, reward = 1 } } })
local doneState = PlaytimeLadder.begin(done, nil)
PlaytimeLadder.tick(done, doneState, 5, true)
PlaytimeLadder.claim(done, doneState, done.rungs[1].id)

emit({
	reward = reward, rewound = loopState.elapsed,
	claimsCleared = next(loopState.claimed) == nil, loops = loopState.loops,
	progress = PlaytimeLadder.progress(ladder, state),
	nextAt = nextRung.at, remaining = remaining,
	finishedHasNoNext = (PlaytimeLadder.next(done, doneState)) == nil,
	finishedProgress = PlaytimeLadder.progress(done, doneState),
})
""")
        self.assertEqual(out["reward"], "x")
        self.assertAlmostEqual(out["rewound"], 2, places=9)
        self.assertTrue(out["claimsCleared"])
        self.assertEqual(out["loops"], 1)
        # 120s into a 60 -> 300 span is a quarter of the way, not 40%.
        self.assertAlmostEqual(out["progress"], 0.25, places=6)
        self.assertEqual(out["nextAt"], 300)
        self.assertAlmostEqual(out["remaining"], 180, places=9)
        self.assertTrue(out["finishedHasNoNext"])
        self.assertEqual(out["finishedProgress"], 1)

    # --------------------------------------------------------- IncomeTracker
    def test_spending_is_not_negative_income(self) -> None:
        """A raw delta window reads a purchase as earning less than nothing."""
        out = self.values("IncomeTracker", """
local tracker = IncomeTracker.new({ windowSize = 4, interval = 2, warmupSeconds = 10 })
local freshReady = tracker:ready()
tracker:sample(0)
local baselineCounted = tracker.seen
tracker:sample(20)
local afterEarning = tracker:average()
local spent = tracker:sample(5)

local raw = IncomeTracker.new({ ignoreNegative = false })
raw:sample(0) raw:sample(10) raw:sample(0)

emit({
	freshReady = freshReady, baselineCounted = baselineCounted,
	afterEarning = afterEarning, rate = tracker:rate(),
	spentKept = spent ~= nil, averageHeld = tracker:average(),
	seenAdvanced = tracker.seen, rawAverage = raw:average(),
	rateNeedsInterval = not pcall(function() return IncomeTracker.new({}):rate() end),
})
""")
        self.assertFalse(out["freshReady"])
        self.assertEqual(out["baselineCounted"], 0)
        self.assertEqual(out["afterEarning"], 20)
        # Divided by the interval exactly once.
        self.assertEqual(out["rate"], 10)
        self.assertFalse(out["spentKept"])
        self.assertEqual(out["averageHeld"], 20)
        # A discarded sample still counts as elapsed time.
        self.assertEqual(out["seenAdvanced"], 2)
        self.assertEqual(out["rawAverage"], 0)
        self.assertTrue(out["rateNeedsInterval"])

    def test_reset_restarts_the_warmup_as_well_as_the_window(self) -> None:
        """Samples after a rebirth are as unrepresentative as those after a join."""
        out = self.values("IncomeTracker", """
local tracker = IncomeTracker.new({ interval = 2, warmupSeconds = 10 })
tracker:sample(0)
for step = 1, 6 do tracker:sample(step * 20) end
local readyBefore = tracker:ready()
tracker:reset()

local window = IncomeTracker.new({ windowSize = 2 })
window:sample(0) window:sample(100) window:sample(200) window:sample(202)

emit({
	readyBefore = readyBefore,
	averageAfterReset = tracker:average(),
	readyAfterReset = tracker:ready(),
	baselineDropped = tracker.hasPrevious == false,
	windowKept = #window.deltas, windowAverage = window:average(),
})
""")
        self.assertTrue(out["readyBefore"])
        self.assertEqual(out["averageAfterReset"], 0)
        self.assertFalse(out["readyAfterReset"])
        self.assertTrue(out["baselineDropped"])
        self.assertEqual(out["windowKept"], 2)
        # Only the last two deltas: 100 and 2.
        self.assertAlmostEqual(out["windowAverage"], 51, places=9)


if __name__ == "__main__":
    unittest.main()
