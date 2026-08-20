"""The read-back, the manual, and the trap catalogue.

Three things were added on the same argument: an engine that only *writes*
teaches an agent nothing. Telemetry that nobody queries, balance numbers with
no reference, and hard-won traps buried in comments are all the same failure —
information that exists and cannot be reached.

These tests are about the reachable part. The summaries are computed from
synthetic events rather than live ones on purpose: the arithmetic is what can
be wrong here, and a test that needs a published game and a week of players is
a test nobody runs.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from forge.cli import analytics, doctor  # noqa: E402

ENGINE = REPO / "forge" / "luau" / "Forge"


def _event(name: str, **props) -> dict:
    return {"at": 0, "name": name, "props": props, "day": "2026-08-20"}


class SessionTests(unittest.TestCase):
    def test_bounce_is_measured_against_completed_sessions(self) -> None:
        events = [_event("session.start") for _ in range(10)]
        events += [_event("session.end", seconds=n) for n in (5, 10, 20, 300, 400)]
        report = analytics.sessions(events)

        self.assertEqual(report["starts"], 10)
        self.assertEqual(report["completed"], 5)
        self.assertEqual(report["underThirtySeconds"], 3)
        self.assertAlmostEqual(report["bounceRate"], 0.6)

    def test_median_is_used_rather_than_mean(self) -> None:
        """One idler must not move the number that describes everyone else."""
        events = [_event("session.end", seconds=n) for n in (60, 60, 60, 60, 14400)]
        report = analytics.sessions(events)
        self.assertEqual(report["medianSeconds"], 60)
        self.assertGreater(report["meanSeconds"], 2000)

    def test_sessions_that_start_and_never_close_are_named(self) -> None:
        notes = analytics.observations([_event("session.start") for _ in range(3)])
        self.assertTrue(any("none ended" in note for note in notes))


class FunnelTests(unittest.TestCase):
    def test_furthest_step_wins_per_subject(self) -> None:
        events = [
            _event("funnel.onboarding", subject="a", step=1),
            _event("funnel.onboarding", subject="a", step=3),
            _event("funnel.onboarding", subject="b", step=1),
            _event("funnel.onboarding", subject="c", step=1),
        ]
        report = analytics.funnels(events)[0]

        self.assertEqual(report["subjects"], 3)
        self.assertEqual(report["steps"][0]["reached"], 3)
        # Only 'a' got past step one, so the loss is at step two.
        self.assertEqual(report["steps"][1]["reached"], 1)
        self.assertEqual(report["worstStep"], 2)

    def test_a_steep_drop_is_reported_in_words(self) -> None:
        events = [_event("funnel.tutorial", subject=str(n), step=1) for n in range(10)]
        events.append(_event("funnel.tutorial", subject="0", step=2))
        notes = analytics.observations(events)
        self.assertTrue(any("step 2" in note for note in notes))


class BehaviourTests(unittest.TestCase):
    def test_worst_heartbeat_is_reported_next_to_the_median(self) -> None:
        events = [_event("server.health", heartbeatMs=ms, players=4, instances=100)
                  for ms in (10, 11, 12, 90)]
        server = analytics.behaviour(events)["server"]
        self.assertEqual(server["worstHeartbeatMs"], 90)
        self.assertLess(server["medianHeartbeatMs"], 15)

        notes = analytics.observations(events)
        self.assertTrue(any("16.7ms budget" in note for note in notes))

    def test_an_empty_day_says_why_it_might_be_empty(self) -> None:
        notes = analytics.observations([])
        self.assertEqual(len(notes), 1)
        self.assertIn("flush", notes[0])

    def test_a_lopsided_roster_is_noticed(self) -> None:
        events = [_event("ability.dash") for _ in range(500)]
        events += [_event("ability.shield") for _ in range(2)]
        notes = analytics.observations(events)
        self.assertTrue(any("ability.dash" in note and "more often" in note
                            for note in notes))


class ReaderMatchesWriterTests(unittest.TestCase):
    """The read path and the write path must name the same store.

    They were separately correct and separately useless for as long as nobody
    checked they agreed. This is the check.
    """

    def test_store_and_key_prefix_match_the_engine(self) -> None:
        source = (ENGINE / "Telemetry" / "init.lua").read_text(encoding="utf-8")
        self.assertIn(f'Telemetry.STORE = "{analytics.STORE}"', source)
        self.assertIn(f'Telemetry.KEY_PREFIX = "{analytics.KEY_PREFIX}"', source)

    def test_the_sink_writes_the_columns_the_reader_reads(self) -> None:
        source = (ENGINE / "Telemetry" / "init.lua").read_text(encoding="utf-8")
        for column in ("t = entry.at", "n = entry.name", "p = entry.props"):
            self.assertIn(column, source)


class DoctorTelemetryTests(unittest.TestCase):
    """The check that found the bug, and the fix that stopped it lying."""

    def _findings(self, body: str) -> list:
        import tempfile

        findings: list = []
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "src").mkdir()
            (root / "src" / "init.server.lua").write_text(body, encoding="utf-8")
            doctor.check_forge_wiring(root, findings)
        return [f for f in findings if "Telemetry" in f.message]

    def test_a_sink_with_no_pump_is_an_error(self) -> None:
        findings = self._findings("Telemetry.sink(function() return true end)")
        self.assertTrue(any("never called" in f.message for f in findings))

    def test_events_with_no_sink_are_a_warning(self) -> None:
        findings = self._findings('Telemetry.start()\nTelemetry.event("x")')
        self.assertTrue(any("no sink" in f.message for f in findings))

    def test_the_engine_sink_counts_as_a_sink(self) -> None:
        """The first version of this check flagged both real games. It was wrong."""
        findings = self._findings(
            'Telemetry.dataStoreSink()\nTelemetry.start()\nTelemetry.event("x")')
        self.assertEqual(findings, [])


class ReferenceTests(unittest.TestCase):
    """The manual is Luau, so what is testable here is that it is consulted."""

    def test_the_engine_carries_a_reference_module(self) -> None:
        self.assertTrue((ENGINE / "Reference" / "init.lua").exists())

    def test_a_game_actually_reads_it(self) -> None:
        """An unexercised module is inventory with an engine address."""
        content = (REPO / "games" / "provingground" / "src" / "shared" / "Content.lua")
        source = content.read_text(encoding="utf-8")
        self.assertIn("Reference.check", source)

        server = (REPO / "games" / "provingground" / "src" / "server"
                  / "init.server.lua").read_text(encoding="utf-8")
        self.assertIn("Content.review()", server)

    def test_it_understands_both_units_a_weapon_declares_its_rate_in(self) -> None:
        """Melee declares a cooldown; ranged declares a rate. Both or neither."""
        source = (ENGINE / "Reference" / "init.lua").read_text(encoding="utf-8")
        self.assertIn("60 / cooldown", source)


class TrapTests(unittest.TestCase):
    """Traps as data, which is the only form an agent can query."""

    def setUp(self) -> None:
        path = REPO / "forge" / "catalog" / "traps.json"
        self.traps = json.loads(path.read_text(encoding="utf-8"))["traps"]

    def test_every_trap_is_complete(self) -> None:
        for trap in self.traps:
            for field in ("id", "symptom", "rule", "why", "instead", "modules", "severity"):
                self.assertIn(field, trap, f"{trap.get('id')} is missing {field}")
            self.assertIn(trap["severity"], ("error", "warning", "note"))

    def test_ids_are_unique(self) -> None:
        ids = [trap["id"] for trap in self.traps]
        self.assertEqual(len(ids), len(set(ids)))

    def test_every_named_module_exists(self) -> None:
        """A trap pointing at a module that was renamed is a trap nobody finds."""
        path = REPO / "forge" / "catalog" / "traps.json"
        catalogue = json.loads(path.read_text(encoding="utf-8"))
        # Some traps are about tooling rather than engine modules. Those areas
        # are declared in the catalogue, so an undeclared name is still a
        # dangling pointer rather than an exception to the rule.
        known = set(catalogue.get("areas", {}))
        for trap in self.traps:
            for module in trap["modules"]:
                exists = (ENGINE / module / "init.lua").exists() or module in known
                self.assertTrue(exists,
                                f"{trap['id']} names a module that is not there: {module}")

    def test_instead_says_what_to_do(self) -> None:
        """A trap that only says 'do not' leaves the agent exactly where it was."""
        for trap in self.traps:
            self.assertGreater(len(trap["instead"]), 30, trap["id"])


if __name__ == "__main__":
    unittest.main()
