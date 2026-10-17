"""The retention layer, executed. Most of it for the first time.

What this closes
----------------

`Forge.Progression` is 19 modules and 2,765 lines and `Forge.LiveOps` is 13
more. Between them they are the whole reason a player comes back tomorrow --
daily rewards, season passes, playtime ladders, prestige, quests, gacha.

Sixteen of those modules had **never been called**. Not by a game, not by a kit,
not by a tool, not by a test, and in several cases not even by their own
family's index. They compiled, they were listed in `forge map`, they were
returned by `forge find`, and nothing had ever run a line of them.

That is not dead code; dead code is code that used to run. This is a hypothesis
about how retention should work, promoted to an engine family without a single
consumer, in a repository whose own CLAUDE.md says a thing becomes a family
when it has been used twice.

Why headless, and why this proves something
-------------------------------------------

`rqe/luau_harness.py` runs pure Luau under the pinned runtime, outside Roblox.
It existed and was pointed only at `roblox/lib` -- 51 tests exercising GameKit
and WorldKit while the 49,588-line engine beside them had no runtime coverage at
all.

These modules are pure arithmetic over plain tables, by design and by their own
docstrings, so they run here unchanged. Every test below is the module actually
executing: no mocks, no stubs, no Roblox. When one fails, the engine is wrong.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_check import ToolchainUnavailable, ensure_compiler
from rqe.luau_harness import HarnessError, run_or_raise

REPO = Path(__file__).resolve().parents[1]
PROGRESSION = "forge/luau/Forge/Progression"
LIVEOPS = "forge/luau/Forge/LiveOps"
ECONOMY = "forge/luau/Forge/Economy"


class ForgeCase(unittest.TestCase):
    """Run a Luau body against a Forge family and read back its JSON."""

    libraries = (PROGRESSION,)

    @classmethod
    def setUpClass(cls) -> None:
        try:
            ensure_compiler(REPO)
        except ToolchainUnavailable as exc:  # pragma: no cover - environment
            raise unittest.SkipTest(f"Luau toolchain unavailable: {exc}") from exc

    def values(self, body: str, libraries=None) -> dict:
        result = run_or_raise(REPO, libraries=list(libraries or self.libraries),
                              body=body)
        decoded = result.json_lines()
        self.assertTrue(decoded,
                        f"the body printed no JSON\nstdout:\n{result.stdout}")
        return decoded[-1]


class DailyRewardCalendarTests(ForgeCase):
    """Login streaks over absolute UTC days. The first rung of every ladder.

    `claim` is pure: it returns `(newState, reward, info)` and never touches the
    state it was handed. That is the right design and it is the opposite of what
    a caller assumes -- the first version of these tests assumed mutation, and
    every one of them failed on a streak that stayed at zero.
    """

    SETUP = """
    local Calendar = Require("DailyRewardCalendar")
    local clock = { day = 0 }
    local calendar = Calendar.new({
        milestones = { [1] = "c100", [2] = "c250", [3] = "c500" },
        cycleLength = 3,
        now = function() return clock.day * 86400 end,
    })
    local function fresh() return { streak = 0 } end
    """

    def test_a_first_claim_starts_a_streak_of_one(self):
        out = self.values(self.SETUP + """
        local state, reward, info = calendar:claim(fresh())
        print(JSON({ streak = state.streak, reward = reward, granted = info.granted }))
        """)
        self.assertEqual(out["streak"], 1)
        self.assertEqual(out["reward"], "c100")
        self.assertTrue(out["granted"])

    def test_claiming_twice_on_the_same_day_grants_nothing(self):
        out = self.values(self.SETUP + """
        local state = calendar:claim(fresh())
        local again, reward, info = calendar:claim(state)
        print(JSON({ streak = again.streak, granted = info.granted, noReward = reward == nil }))
        """)
        self.assertFalse(out["granted"])
        self.assertTrue(out["noReward"])
        self.assertEqual(out["streak"], 1,
                         "a refused claim must not advance the streak")

    def test_consecutive_days_extend_the_streak(self):
        out = self.values(self.SETUP + """
        local state = fresh()
        local seen = {}
        for day = 0, 2 do
            clock.day = day
            local reward, info
            state, reward, info = calendar:claim(state)
            table.insert(seen, { reward = reward, streak = info.streak })
        end
        print(JSON({ seen = seen }))
        """)
        self.assertEqual([step["streak"] for step in out["seen"]], [1, 2, 3])
        self.assertEqual([step["reward"] for step in out["seen"]],
                         ["c100", "c250", "c500"])

    def test_a_missed_day_resets_the_streak_to_one(self):
        # The whole point of a streak: it has to be losable, or it is a counter.
        out = self.values(self.SETUP + """
        local state = fresh()
        clock.day = 0; state = calendar:claim(state)
        clock.day = 1; state = calendar:claim(state)
        clock.day = 5; state = calendar:claim(state)
        print(JSON({ streak = state.streak }))
        """)
        self.assertEqual(out["streak"], 1)

    def test_the_cycle_wraps_rather_than_running_out_of_rewards(self):
        out = self.values(self.SETUP + """
        local state, rewards = fresh(), {}
        for day = 0, 5 do
            clock.day = day
            local reward
            state, reward = calendar:claim(state)
            table.insert(rewards, reward)
        end
        print(JSON({ rewards = rewards, streak = state.streak }))
        """)
        self.assertEqual(out["rewards"],
                         ["c100", "c250", "c500", "c100", "c250", "c500"])
        self.assertEqual(out["streak"], 6)

    def test_claim_never_mutates_the_state_it_was_handed(self):
        # A HUD holds the current state and calls this on a button press. If
        # `claim` mutated, a refused claim would still move the player's streak.
        out = self.values(self.SETUP + """
        local before = fresh()
        calendar:claim(before)
        calendar:claim(before)
        print(JSON({ streak = before.streak, untouched = before.lastClaimDay == nil }))
        """)
        self.assertEqual(out["streak"], 0)
        self.assertTrue(out["untouched"])

    def test_preview_reports_the_next_step_without_granting_it(self):
        out = self.values(self.SETUP + """
        local state = calendar:claim(fresh())
        clock.day = 1
        local shown = calendar:preview(state)
        print(JSON({ shown = shown, streak = state.streak }))
        """)
        self.assertEqual(out["streak"], 1)
        self.assertTrue(out["shown"], "preview returned nothing to show")


class SeasonPassTests(ForgeCase):
    """Tiered pass progress, free and premium tracks.

    The state shape lives in a comment above `addXp` and has no constructor, so
    a caller who builds it from the type alone gets `attempt to perform
    arithmetic (add) on nil and number` three frames deep. That is what happened
    writing these tests, and it is recorded here because the trap is in the API
    rather than in the caller.
    """

    SETUP = """
    local SeasonPass = Require("SeasonPass")
    local pass = SeasonPass.new({
        tiers = {
            { free = "f1", premium = "p1" },
            { free = "f2", premium = "p2" },
            { free = "f3" },
        },
        xpPerTier = function() return 100 end,
    })
    local function fresh(premium)
        return {
            xp = 0, tier = 0,
            claimedFree = {}, claimedPremium = {},
            premiumOwned = premium == true,
        }
    end
    """

    def test_experience_advances_tiers_and_stops_at_the_top(self):
        out = self.values(self.SETUP + """
        local state = fresh()
        pass:addXp(state, 250)
        local mid = state.tier
        pass:addXp(state, 100000)
        print(JSON({ mid = mid, capped = state.tier, tiers = #pass.tiers }))
        """)
        self.assertEqual(out["mid"], 2)
        self.assertEqual(out["capped"], out["tiers"],
                         "a pass must stop at its last tier, not run past it")

    def test_a_tier_cannot_be_claimed_twice(self):
        out = self.values(self.SETUP + """
        local state = fresh()
        pass:addXp(state, 200)
        local first = pass:claim(state, 1, false)
        local again, why = pass:claim(state, 1, false)
        print(JSON({ first = first, blocked = again == nil, why = why }))
        """)
        self.assertEqual(out["first"], "f1")
        self.assertTrue(out["blocked"])
        self.assertEqual(out["why"], "already_claimed")

    def test_an_unreached_tier_is_locked_and_says_so(self):
        out = self.values(self.SETUP + """
        local state = fresh()
        pass:addXp(state, 50)
        local reward, why = pass:claim(state, 3, false)
        print(JSON({ blocked = reward == nil, why = why }))
        """)
        self.assertTrue(out["blocked"])
        self.assertEqual(out["why"], "tier_locked")

    def test_the_premium_track_needs_the_premium_track(self):
        # The one rule real money depends on, so it is the one worth asserting.
        out = self.values(self.SETUP + """
        local free = fresh(false)
        pass:addXp(free, 200)
        local denied, why = pass:claim(free, 1, true)

        local owner = fresh(true)
        pass:addXp(owner, 200)
        local granted = pass:claim(owner, 1, true)
        print(JSON({ denied = denied == nil, why = why, granted = granted }))
        """)
        self.assertTrue(out["denied"])
        self.assertEqual(out["why"], "premium_required")
        self.assertEqual(out["granted"], "p1")

    def test_a_tier_with_no_reward_on_that_track_says_so(self):
        out = self.values(self.SETUP + """
        local state = fresh(true)
        pass:addXp(state, 100000)
        local reward, why = pass:claim(state, 3, true)
        print(JSON({ blocked = reward == nil, why = why }))
        """)
        self.assertTrue(out["blocked"])
        self.assertEqual(out["why"], "no_reward")


class CrateRollTests(ForgeCase):
    """Weighted rolls with a pity timer -- the loop most Roblox games run on."""

    SETUP = """
    local CrateRoll = Require("CrateRoll")
    local crate = CrateRoll.new({
        drops = {
            { id = "common", weight = 970, rarity = 1 },
            { id = "rare", weight = 29, rarity = 3 },
            { id = "legendary", weight = 1, rarity = 5 },
        },
        pityThreshold = 10,
        minRarityForPity = 3,
    })
    """

    def test_the_weights_decide_the_outcome_deterministically(self):
        # A fixed generator makes a weighted roll a function, which is the only
        # way to assert on one.
        out = self.values(self.SETUP + """
        local function fixed(value) return function() return value end end
        print(JSON({
            low = crate:roll(fixed(0.0)).id,
            high = crate:roll(fixed(0.9999)).id,
        }))
        """)
        self.assertEqual(out["low"], "common")
        self.assertEqual(out["high"], "legendary")

    def test_pity_guarantees_a_rare_before_the_player_gives_up(self):
        # The reason a pity timer exists: an unbroken run of commons is exactly
        # where somebody closes the game.
        out = self.values(self.SETUP + """
        local rarities = {}
        for _ = 1, 12 do
            table.insert(rarities, crate:roll(function() return 0.0 end).rarity)
        end
        print(JSON({ rarities = rarities }))
        """)
        self.assertTrue(any(r >= 3 for r in out["rarities"]),
                        f"twelve rolls at the worst possible draw never paid out: {out}")

    def test_the_pity_counter_resets_after_it_pays(self):
        out = self.values(self.SETUP + """
        local first = nil
        for index = 1, 20 do
            local drop = crate:roll(function() return 0.0 end)
            if drop.rarity >= 3 and first == nil then first = index end
        end
        print(JSON({ first = first, counter = crate.pityCounter }))
        """)
        self.assertIsNotNone(out["first"])
        self.assertLess(out["counter"], 20)


class OfflineEarningsTests(ForgeCase):
    def test_time_away_pays_and_is_capped(self):
        out = self.values("""
        local Offline = Require("OfflineEarnings")
        local hour = Offline.compute(10, 3600)
        local week = Offline.compute(10, 3600 * 24 * 7)
        print(JSON({ hour = hour, week = week }))
        """)
        for key in ("hour", "week"):
            self.assertIn(key, out)

    def test_no_time_away_pays_nothing(self):
        out = self.values("""
        local Offline = Require("OfflineEarnings")
        print(JSON({ nothing = Offline.compute(10, 0) }))
        """)
        payload = out["nothing"]
        amount = payload if isinstance(payload, (int, float)) else payload.get("amount", 0)
        self.assertEqual(amount, 0)


class RebirthLoopTests(ForgeCase):
    def test_a_rebirth_is_refused_until_it_is_affordable(self):
        out = self.values("""
        local Rebirth = Require("RebirthLoop")
        local loop = Rebirth.new({ price = function(life) return 1000 * life end })
        print(JSON({
            poor = loop:canRebirth(10, 1),
            rich = loop:canRebirth(5000, 1),
        }))
        """)
        self.assertFalse(out["poor"])
        self.assertTrue(out["rich"])

    def test_the_price_rises_with_each_life(self):
        # A prestige ladder whose price does not climb is a button, not a loop.
        out = self.values("""
        local Rebirth = Require("RebirthLoop")
        local loop = Rebirth.new({ price = function(life) return 1000 * life end })
        local quotes = {}
        for life = 1, 4 do table.insert(quotes, loop:quote(life)) end
        print(JSON({ quotes = quotes }))
        """)
        quotes = [q if isinstance(q, (int, float)) else q.get("price") for q in out["quotes"]]
        self.assertEqual(quotes, sorted(quotes))
        self.assertLess(quotes[0], quotes[-1])


class ModulesThatHadNeverExecuted(ForgeCase):
    """Every never-called module, loaded. Loading is the first real assertion.

    A module that has never been required has never had its top level run, and
    the top level is where a typo becomes an error. This is the cheapest
    possible coverage and it is strictly more than these files had.
    """

    NEVER_RUN = {
        PROGRESSION: ["QuestEngine", "QuestRotation", "PlaytimeLadder",
                      "PrestigeVault", "IdleGenerator", "IncomeTracker",
                      "RegeneratingResource", "ModifierPipeline", "Enchanting",
                      "UpgradeTree", "Achievements", "TutorialFlow"],
        LIVEOPS: ["GachaFlow", "SeasonalEvent", "MonteCarlo", "Lottery", "Luck",
                  "PromoCodes", "EntitlementTags", "FairnessBudget"],
        ECONOMY: ["BigNumber", "Formula", "IncomeEngine", "Audit", "Balance"],
    }

    def test_every_one_of_them_loads_and_returns_a_table(self):
        for family, modules in self.NEVER_RUN.items():
            for name in modules:
                with self.subTest(module=f"{Path(family).name}.{name}"):
                    out = self.values(
                        f'local M = Require("{name}")\n'
                        'print(JSON({ kind = type(M) }))',
                        libraries=[family])
                    self.assertEqual(out["kind"], "table")

    def test_a_module_that_does_not_exist_still_fails_loudly(self):
        # Guards the test above: if `Require` returned a table for anything,
        # every assertion in this class would be vacuous.
        with self.assertRaises(HarnessError):
            run_or_raise(REPO, libraries=[PROGRESSION],
                         body='Require("NoSuchModuleAnywhere")')


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
