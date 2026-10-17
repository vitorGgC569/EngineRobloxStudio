"""The operational shell: what a run cost, undoing a publish, resuming one.

Three things a tool needs when something goes wrong and nobody is watching, and
none of them existed. The repository measured the *product* exhaustively and the
*production* not at all; a bad publish could be seen and not undone; and a run
interrupted at stage nine redid the eight before it.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from rqe import ledger
from rqe.exits import NO_STUDIO, OK, USAGE, Problem
from rqe.producer.checkpoint import (
    RESUMABLE_STAGES,
    Checkpoint,
    identity,
    resumable_stages,
    unresumable,
)


class LedgerTests(unittest.TestCase):
    """Round trips to Studio, seconds, restarts -- the production metric."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_nothing_is_recorded_outside_a_run(self):
        # The hooks sit six frames below the CLI and fire on every bridge call.
        # Outside a run they must be free and silent, not an error.
        self.assertIsNone(ledger.current())
        ledger.record_bridge_call("dm.tree", 0.2)
        ledger.record_studio_restart()
        self.assertEqual(ledger.read(self.root), [])

    def test_a_run_writes_one_line_with_what_it_cost(self):
        with ledger.run("forge playtest", game="carvewood", root=self.root) as run:
            ledger.record_bridge_call("dm.tree", 0.5)
            ledger.record_bridge_call("dm.tree", 0.4)
            ledger.record_bridge_call("camera.set", 0.1, ok=False)
            ledger.record_studio_restart()
            ledger.record_build()
            run.exit_code = OK

        rows = ledger.read(self.root)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["command"], "forge playtest")
        self.assertEqual(row["game"], "carvewood")
        self.assertEqual(row["bridge"]["calls"], 3)
        self.assertEqual(row["bridge"]["failed"], 1)
        self.assertEqual(row["bridge"]["byMethod"]["dm.tree"], 2)
        self.assertEqual(row["studioRestarts"], 1)
        self.assertEqual(row["builds"], 1)
        self.assertEqual(row["kind"], "ok")

    def test_the_exit_kind_is_recorded_so_failures_are_countable(self):
        with ledger.run("forge inspect", root=self.root) as run:
            run.exit_code = NO_STUDIO
        self.assertEqual(ledger.read(self.root)[0]["kind"], "no-studio")

    def test_a_crashing_command_is_still_costed(self):
        # The line is written in a `finally`: the runs worth costing are
        # disproportionately the ones that went wrong.
        with self.assertRaises(RuntimeError):
            with ledger.run("forge build", root=self.root):
                ledger.record_bridge_call("dm.tree", 0.1)
                raise RuntimeError("deliberate")
        self.assertEqual(ledger.read(self.root)[0]["bridge"]["calls"], 1)

    def test_a_nested_run_belongs_to_the_outer_one(self):
        # A command that calls another command's function must not produce two
        # lines: the cost belongs to what the caller asked for.
        with ledger.run("forge playtest", root=self.root):
            ledger.record_bridge_call("dm.tree", 0.1)
            with ledger.run("forge build", root=self.root):
                ledger.record_bridge_call("dm.tree", 0.1)
        rows = ledger.read(self.root)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["command"], "forge playtest")
        self.assertEqual(rows[0]["bridge"]["calls"], 2)

    def test_recording_never_raises_into_the_run_it_measures(self):
        # A ledger that fails while recording a successful build has turned a
        # measurement into an outage.
        with ledger.run("forge build", root=self.root) as run:
            ledger.record_bridge_call(None, "not a number")  # type: ignore[arg-type]
            run.exit_code = OK
        self.assertGreaterEqual(ledger.read(self.root)[0]["dropped"], 1)

    def test_a_torn_line_does_not_hide_the_lines_after_it(self):
        with ledger.run("forge build", root=self.root):
            pass
        path = self.root / ledger.LEDGER_PATH
        with path.open("a", encoding="utf-8") as handle:
            handle.write('{"truncated": \n')
        with ledger.run("forge doctor", root=self.root):
            pass
        commands = [row["command"] for row in ledger.read(self.root)]
        self.assertEqual(commands, ["forge build", "forge doctor"])

    def test_reading_can_be_filtered_by_game_and_command(self):
        for command, game in (("forge build", "a"), ("forge build", "b"),
                              ("forge playtest", "a")):
            with ledger.run(command, game=game, root=self.root):
                pass
        self.assertEqual(len(ledger.read(self.root, game="a")), 2)
        self.assertEqual(len(ledger.read(self.root, command="forge build")), 2)

    def test_the_summary_answers_what_a_game_costs(self):
        for _ in range(2):
            with ledger.run("forge playtest", game="c", root=self.root) as run:
                for _ in range(10):
                    ledger.record_bridge_call("dm.tree", 1.0)
                run.exit_code = OK
        total = ledger.summarise(ledger.read(self.root, game="c"))
        self.assertEqual(total.runs, 2)
        self.assertEqual(total.bridge_calls, 20)
        self.assertEqual(total.calls_per_run, 10.0)
        self.assertEqual(total.failure_rate, 0.0)

    def test_waiting_on_studio_is_separated_from_working(self):
        # "this agent is inefficient" and "Studio is slow" are different
        # problems with different fixes.
        with ledger.run("forge playtest", root=self.root) as run:
            ledger.record_bridge_call("dm.tree", 5.0)
            self.assertGreater(run.waiting_fraction, 0.5)

    def test_an_empty_ledger_says_how_to_fill_it(self):
        self.assertIn("Run", ledger.render([]))


class RollbackTests(unittest.TestCase):
    """Roblox has no restore endpoint, so a rollback re-publishes kept bytes."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _publish(self, version: int, body: bytes) -> None:
        from forge.cli import rollback as rb

        place = self.root / f"v{version}.rbxlx"
        place.write_bytes(body)
        rb.keep("g", place, {"versionType": "Published", "versionNumber": version},
                universe_id="1", place_id="2", root=self.root)

    def test_a_publish_keeps_the_exact_bytes_it_sent(self):
        from forge.cli import rollback as rb

        self._publish(10, b"<roblox>ten</roblox>")
        kept, = rb.restorable("g", self.root)
        self.assertEqual(kept.version_number, 10)
        self.assertEqual(kept.kept_path(self.root).read_bytes(),
                         b"<roblox>ten</roblox>")

    def test_rolling_back_defaults_to_the_one_before_the_current(self):
        from forge.cli import rollback as rb

        self._publish(10, b"good")
        self._publish(11, b"bad")
        self.assertEqual(rb.target("g", root=self.root).version_number, 10)

    def test_a_named_version_can_be_reached(self):
        from forge.cli import rollback as rb

        for version in (10, 11, 12):
            self._publish(version, f"v{version}".encode())
        self.assertEqual(rb.target("g", 10, root=self.root).version_number, 10)

    def test_edited_bytes_are_refused_rather_than_published(self):
        # A truncated or edited artifact must be a refusal, not a silent
        # publish of something nobody reviewed.
        from forge.cli import rollback as rb

        self._publish(10, b"good")
        self._publish(11, b"also good")
        kept = rb.history("g", self.root)[0].kept_path(self.root)
        kept.write_bytes(b"tampered")
        self.assertEqual([item.version_number for item in rb.restorable("g", self.root)],
                         [11])

    def test_a_game_with_no_kept_publish_is_told_why(self):
        from forge.cli import rollback as rb

        with self.assertRaises(Problem) as raised:
            rb.target("never-published", root=self.root)
        self.assertEqual(raised.exception.code, USAGE)
        self.assertIn("never", raised.exception.message)

    def test_one_publish_has_nothing_earlier_to_go_back_to(self):
        from forge.cli import rollback as rb

        self._publish(10, b"only")
        with self.assertRaises(Problem):
            rb.target("g", root=self.root)

    def test_an_unknown_version_lists_the_ones_that_exist(self):
        from forge.cli import rollback as rb

        self._publish(10, b"a")
        self._publish(11, b"b")
        with self.assertRaises(Problem) as raised:
            rb.target("g", 99, root=self.root)
        self.assertIn("10", raised.exception.detail)

    def test_the_listing_says_a_rollback_is_a_new_version(self):
        from forge.cli import rollback as rb

        self._publish(10, b"a")
        text = rb.render("g", self.root)
        self.assertIn("no restore endpoint", text)
        self.assertIn("restorable", text)


class CheckpointTests(unittest.TestCase):
    """A run interrupted at stage nine should not redo the eight before it."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.want = identity("a brief", "g", "tycoon", "forest", "t.json")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _saved(self, **stages) -> Checkpoint:
        point = Checkpoint(game_id="g", identity=self.want)
        for name, status in stages.items():
            point.record(name, status, {"did": name}, 1.0)
        output = self.root / "generated.lua"
        output.write_text("return true\n", encoding="utf-8")
        point.bind_outputs(self.root, ["generated.lua"])
        point.save(self.root)
        return point

    def test_a_finished_stage_is_offered_for_resume(self):
        self._saved(geometry="OK", build="OK")
        _, licensed, why = resumable_stages(self.root, "g", self.want)
        self.assertEqual(set(licensed), {"geometry", "build"})
        self.assertEqual(why, "")

    def test_a_failed_stage_is_retried_not_resumed(self):
        # The reason to resume is usually that something was fixed.
        self._saved(geometry="OK", build="FAILED")
        _, licensed, _ = resumable_stages(self.root, "g", self.want)
        self.assertEqual(licensed, ["geometry"])

    def test_a_changed_brief_refuses_to_resume_and_says_so(self):
        # Silently resuming across a changed brief produces a game half
        # designed from each.
        self._saved(geometry="OK")
        other = identity("a different brief", "g", "tycoon", "forest", "t.json")
        _, licensed, why = resumable_stages(self.root, "g", other)
        self.assertEqual(licensed, [])
        self.assertIn("changed", why)

    def test_modified_or_missing_output_refuses_to_resume(self):
        self._saved(build="OK")
        output = self.root / "generated.lua"
        output.write_text("return false", encoding="utf-8")
        self.assertEqual(resumable_stages(self.root, "g", self.want)[1], [])
        output.unlink()
        self.assertEqual(resumable_stages(self.root, "g", self.want)[1], [])

    def test_checkpoint_without_artifact_hashes_has_no_authority(self):
        point = Checkpoint(game_id="g", identity=self.want)
        point.record("build", "OK", {}, 0)
        point.save(self.root)
        self.assertEqual(resumable_stages(self.root, "g", self.want)[1], [])

    def test_no_checkpoint_is_not_a_refusal(self):
        _, licensed, why = resumable_stages(self.root, "g", self.want)
        self.assertEqual(licensed, [])
        self.assertIn("no checkpoint", why)

    def test_only_the_file_producing_stages_are_safe_to_skip(self):
        # `design` and `art` hand objects to later stages through an in-memory
        # context that does not survive a process; skipping them would leave
        # every stage after them deciding against holes.
        self.assertEqual(unresumable(["design", "art", "geometry", "build"]),
                         ["art", "design"])
        self.assertEqual(RESUMABLE_STAGES,
                         {"scaffold", "geometry", "implement", "build"})

    def test_a_truncated_checkpoint_is_ignored_rather_than_fatal(self):
        self._saved(build="OK")
        path = Checkpoint(game_id="g", identity="").path(self.root)
        path.write_text("{ truncated", encoding="utf-8")
        self.assertIsNone(Checkpoint.load(self.root, "g"))

    def test_the_checkpoint_is_replaced_atomically(self):
        # A run killed mid-write must not leave a half-written record of what
        # succeeded, which is worse than none.
        point = self._saved(build="OK")
        path = point.path(self.root)
        self.assertTrue(path.is_file())
        self.assertFalse(path.with_suffix(".part").exists())
        payload = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(payload["stages"]["build"]["status"], "OK")

    def test_clearing_starts_the_next_run_from_the_beginning(self):
        self._saved(build="OK")
        self.assertTrue(Checkpoint.clear(self.root, "g"))
        self.assertIsNone(Checkpoint.load(self.root, "g"))


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
