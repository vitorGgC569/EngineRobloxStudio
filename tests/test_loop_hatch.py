"""The composition layer, and the circuit it closes.

Two things were missing and they turn out to be one thing.

**The external loop.** Two games are published from this repository and neither
could say whether anybody stayed. `forge analytics` read them for the first time
in this session: `provingground` has one session start and no gameplay events;
`quarryline` has 872 `earn` events and zero sessions, so there is not even a
denominator. Neither declares a funnel, because declaring one was something a
game had to remember and no game did.

**The composition.** `Progression.CrateRoll` is correct weighted-draw arithmetic
and 0% of a loop. Thirty-two retention modules were written and sixteen were
never called, because composing them by hand is work an agent does not do.

`Forge.Loop.Hatch` is the resolution to both: it composes the primitives *and
declares its own funnel*, so a game built on it emits the drop-off report the
moment it has players -- in exactly the shape `forge/cli/analytics.py` already
reads. The last test here runs the loop, takes the events it emitted, feeds them
to the real reader and asserts on the funnel that comes out. That is the whole
circuit, in one assertion.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from forge.cli.analytics import funnels
from rqe.luau_check import ToolchainUnavailable, ensure_compiler
from rqe.luau_harness import run_or_raise

REPO = Path(__file__).resolve().parents[1]
LIBRARIES = [
    "forge/luau/Forge/Loop",
    "forge/luau/Forge/Progression",
    "forge/luau/Forge/Telemetry",
    "forge/luau/Forge/Core",
]

SETUP = """
local Hatch = Require("Hatch")
local Telemetry = Require("Telemetry")

local revealed = {}
local loop = Hatch.new({
    theme = { noun = "egg", verb = "hatch", collection = "pets" },
    drops = {
        { id = "common", weight = 970, rarity = 1 },
        { id = "rare", weight = 29, rarity = 3 },
        { id = "legendary", weight = 1, rarity = 5 },
    },
    tier2At = 180,
    onReveal = function(subject, drop, rarity)
        table.insert(revealed, { subject = subject, id = drop.id, rarity = rarity })
    end,
})
local function always(value) return function() return value end end
"""


class HatchCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        try:
            ensure_compiler(REPO)
        except ToolchainUnavailable as exc:  # pragma: no cover - environment
            raise unittest.SkipTest(f"Luau toolchain unavailable: {exc}") from exc

    def values(self, body: str) -> dict:
        result = run_or_raise(REPO, libraries=list(LIBRARIES), body=SETUP + body)
        decoded = result.json_lines()
        self.assertTrue(decoded, f"no JSON printed\nstdout:\n{result.stdout}")
        return decoded[-1]


class WhatALoopIsTests(HatchCase):
    def test_it_refuses_to_exist_without_the_number_that_matters(self):
        # 74% of the only real retention record's new players left before
        # reaching a second rung, so when it becomes reachable is a decision.
        out = self.values("""
        local ok = pcall(function()
            return Hatch.new({ theme = { noun = "egg" },
                               drops = { { id = "a", weight = 1, rarity = 1 } } })
        end)
        print(JSON({ accepted = ok }))
        """)
        self.assertFalse(out["accepted"])

    def test_the_theme_is_nouns_and_the_structure_is_not(self):
        # "crack pet eggs" and "crack anime eggs" must be one loop.
        out = self.values("""
        local anime = Hatch.new({
            theme = { noun = "anime egg", verb = "crack" },
            drops = { { id = "a", weight = 1, rarity = 1 } }, tier2At = 180,
        })
        print(JSON({
            pets = loop:label(), anime = anime:label(),
            sameSteps = table.concat(Hatch.STEPS, ",") == table.concat(Hatch.STEPS, ","),
        }))
        """)
        self.assertEqual(out["pets"], "hatch egg")
        self.assertEqual(out["anime"], "crack anime egg")
        self.assertTrue(out["sameSteps"])

    def test_the_first_payout_is_free(self):
        # 28% of halo's new players left before a first hatch that landed at 22s.
        out = self.values("""
        local before = loop:isFree("p1")
        loop:open("p1", always(0.0))
        print(JSON({ before = before, after = loop:isFree("p1") }))
        """)
        self.assertTrue(out["before"])
        self.assertFalse(out["after"])

    def test_the_reveal_fires_with_what_was_drawn(self):
        # A draw with no reveal is a number changing, and a number changing is
        # not why anybody opens the next one.
        out = self.values("""
        loop:open("p1", always(0.9999))
        print(JSON({ revealed = revealed }))
        """)
        self.assertEqual(len(out["revealed"]), 1)
        self.assertEqual(out["revealed"][0]["id"], "legendary")
        self.assertEqual(out["revealed"][0]["rarity"], 5)


class TheRulesItChecksTests(HatchCase):
    def test_a_late_first_payout_is_reported(self):
        out = self.values("""
        Telemetry.seen("p1", os.time() - 300)
        loop.firstOpenAt["p1"] = os.time() - 300
        local rules = {}
        for _, finding in ipairs(loop:check("p1")) do
            table.insert(rules, finding.rule)
        end
        print(JSON({ rules = rules }))
        """)
        self.assertIn("first_payout_late", out["rules"])

    def test_dead_time_is_reported_before_players_find_it(self):
        # The one fatal gap in the only real retention record was 136 seconds,
        # and it hid behind a 79% conversion rate.
        out = self.values("""
        loop:open("p1", always(0.0))
        loop.lastEventAt["p1"] = os.time() - 200
        local rules = {}
        for _, finding in ipairs(loop:check("p1")) do
            table.insert(rules, finding.rule)
        end
        print(JSON({ rules = rules, threshold = Hatch.MAX_DEAD_SECONDS }))
        """)
        self.assertIn("dead_time", out["rules"])
        self.assertEqual(out["threshold"], 90)

    def test_a_healthy_gap_is_not_reported(self):
        # halo's healthy gaps were 17-49 seconds; the threshold has to sit above
        # them or the check cries wolf and stops being read.
        out = self.values("""
        loop:open("p1", always(0.0))
        loop.lastEventAt["p1"] = os.time() - 45
        local rules = {}
        for _, finding in ipairs(loop:check("p1")) do
            table.insert(rules, finding.rule)
        end
        print(JSON({ rules = rules }))
        """)
        self.assertNotIn("dead_time", out["rules"])


class TheCircuitTests(HatchCase):
    """Composition emits the funnel; the shipped reader reads it."""

    def _events(self, body: str) -> list[dict]:
        out = self.values(body + """
        local flat = {}
        for _, entry in ipairs(Telemetry.flushed or {}) do table.insert(flat, entry) end
        print(JSON({ events = collected }))
        """)
        return out["events"]

    def test_playing_the_loop_emits_the_funnel_without_being_asked(self):
        collected = self.values("""
        local collected = {}
        Telemetry.sink(function(batch)
            for _, entry in ipairs(batch) do table.insert(collected, entry) end
            return true
        end)

        -- Twelve players open once; six of them keep what they got; three come
        -- back for a second; one sees the collection.
        for index = 1, 12 do
            local who = "player:" .. index
            loop:open(who, always(0.0))
            if index <= 6 then loop:kept(who) end
            if index <= 3 then loop:open(who, always(0.0)) end
            if index <= 1 then loop:sawCollection(who) end
        end
        Telemetry.flush()
        print(JSON({ events = collected }))
        """)["events"]

        names = {entry["name"] for entry in collected}
        self.assertIn("funnel.hatch", names,
                      "the loop declared a funnel and emitted nothing into it")

    def test_the_reader_rebuilds_the_drop_off_from_those_events(self):
        # The whole circuit: Luau composition -> event stream -> the same
        # Python that reads the two published games.
        collected = self.values("""
        local collected = {}
        Telemetry.sink(function(batch)
            for _, entry in ipairs(batch) do table.insert(collected, entry) end
            return true
        end)
        for index = 1, 12 do
            local who = "player:" .. index
            loop:open(who, always(0.0))
            if index <= 6 then loop:kept(who) end
            if index <= 3 then loop:open(who, always(0.0)) end
        end
        Telemetry.flush()
        print(JSON({ events = collected }))
        """)["events"]

        report, = funnels([
            {"name": entry["name"], "props": entry.get("props") or {}}
            for entry in collected
        ])
        self.assertEqual(report["funnel"], "hatch")

        steps = {entry["step"]: entry for entry in report["steps"]}
        self.assertEqual(steps[1]["id"], "first_open")
        self.assertEqual(steps[1]["reached"], 12)
        self.assertEqual(steps[2]["id"], "first_keep")
        self.assertEqual(steps[2]["reached"], 6)
        self.assertEqual(steps[3]["id"], "second_open")
        self.assertEqual(steps[3]["reached"], 3)

    def test_the_steps_carry_names_rather_than_numbers(self):
        # A report that says "step 4" is one a designer has to go and look up.
        collected = self.values("""
        local collected = {}
        Telemetry.sink(function(batch)
            for _, entry in ipairs(batch) do table.insert(collected, entry) end
            return true
        end)
        loop:open("player:1", always(0.0))
        Telemetry.flush()
        print(JSON({ events = collected }))
        """)["events"]

        report, = funnels([
            {"name": entry["name"], "props": entry.get("props") or {}}
            for entry in collected
        ])
        self.assertTrue(all(not entry["id"].startswith("step_")
                            for entry in report["steps"]), report["steps"])

    def test_the_reader_measures_time_between_steps(self):
        # The column that found the 136-second hole. Without it a funnel can
        # say how many stopped and never where the time went.
        collected = self.values("""
        local collected = {}
        Telemetry.sink(function(batch)
            for _, entry in ipairs(batch) do table.insert(collected, entry) end
            return true
        end)
        Telemetry.seen("player:1", os.time() - 100)
        loop:open("player:1", always(0.0))
        Telemetry.flush()
        print(JSON({ events = collected }))
        """)["events"]

        report, = funnels([
            {"name": entry["name"], "props": entry.get("props") or {}}
            for entry in collected
        ])
        first = report["steps"][0]
        self.assertIsNotNone(first["meanSecondsToReach"])
        self.assertGreaterEqual(first["meanSecondsToReach"], 90)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
