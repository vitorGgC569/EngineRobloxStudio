"""The producer.

Ten layers exist and each answers to a different call. Driving them by hand
means knowing that the economy needs the model, the asset plan needs the world,
and the world needs the zones the design inferred -- and getting the order wrong
produces a plan for a game the design already said would not work.

The property that earns the layer its place is not the sequencing, which is a
graph walk. It is `test_a_failed_stage_does_not_abandon_the_run`: the document
lists nine agents precisely because most of their work is independent, and a run
that gave up on the first refusal would throw away nine-tenths of what it had
already done.
"""

from __future__ import annotations

import shutil
import pytest
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from rqe.producer import FAILED, OK, SKIPPED, ProducerError, produce, stages
from rqe.producer.pipeline import Stage

REPO = Path(__file__).resolve().parents[1]

BRIEF = ("Quero um simulator de criaturas inspirado em recifes e cavernas, "
         "publico 9-15 anos, mobile-first, com loja e sessoes de 12 minutos.")


#: Marked slow: every class here runs a real production pipeline in
#: `setUpClass` -- rojo, geometry, the whole producer -- which is 77 seconds
#: per class and is the work, not waste. `test_engine.py` was the other kind:
#: 107 seconds of copying 34 GB to edit one JSON field, and that was fixed
#: rather than marked.
#:
#: The full suite is the gate and CI runs all of it. `pytest -m "not slow"` is
#: the working loop, and the deselected count is printed so the difference is
#: never invisible.
pytestmark = pytest.mark.slow

class TestTheGraph(unittest.TestCase):
    def test_the_graph_is_readable_before_anything_runs(self):
        graph = stages()
        self.assertTrue(graph)
        for stage in graph:
            self.assertTrue(stage["summary"].strip(), stage["id"])

    def test_every_dependency_names_a_real_stage(self):
        """A stage waiting on something that does not exist would never run and
        would report no reason."""

        graph = stages()
        known = {stage["id"] for stage in graph}
        for stage in graph:
            for dependency in stage["after"] + stage["optionalAfter"]:
                self.assertIn(dependency, known, f"{stage['id']} -> {dependency}")

    def test_dependencies_come_before_their_dependents(self):
        order = [stage["id"] for stage in stages()]
        for stage in stages():
            for dependency in stage["after"] + stage["optionalAfter"]:
                self.assertLess(order.index(dependency), order.index(stage["id"]))

    def test_the_economy_does_not_wait_on_the_world(self):
        """Ordered by what each stage genuinely needs. A world that will not
        expand must not stop a curve from being solved."""

        economy = next(s for s in stages() if s["id"] == "economy")
        self.assertNotIn("world", economy["after"])

    def test_the_asset_plan_does_wait_on_the_world(self):
        """Without it the plan cannot see the region kinds, and would budget for
        an experience icon and nothing else."""

        assets = next(s for s in stages() if s["id"] == "assets")
        self.assertIn("world", assets["after"])

    def test_implementation_consumes_geometry_without_losing_the_degraded_build(self):
        implement = next(s for s in stages() if s["id"] == "implement")
        self.assertIn("assets", implement["after"])
        self.assertIn("geometry", implement["optionalAfter"])
        release = next(s for s in stages() if s["id"] == "release_candidate")
        self.assertIn("geometry", release["after"])

    def test_repair_is_packaged_and_remeasured_before_regression(self):
        graph = {stage["id"]: stage for stage in stages()}
        self.assertIn("repair", graph["build"]["after"])
        self.assertIn("build", graph["reevaluate"]["after"])
        self.assertIn("reevaluate", graph["regression"]["after"])
        self.assertIn("reevaluate", graph["release_candidate"]["after"])


class TestARealRun(unittest.TestCase):
    """One brief, every layer, in the repository that has the toolchain."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.game_id = "producer-probe"
        shutil.rmtree(REPO / "games" / cls.game_id, ignore_errors=True)
        cls.production = produce(REPO, BRIEF, game_id=cls.game_id, scaffold=True)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(REPO / "games" / cls.game_id, ignore_errors=True)

    def test_the_static_package_finishes_without_claiming_release(self):
        """A source/build run is useful, but no Studio evidence is no release.

        This used to assert ``production.ok`` and therefore required an
        unplayed place to look completely successful.  The producer now makes
        the missing runtime evidence a real failed stage while preserving every
        completed static artifact.
        """

        self.assertFalse(self.production.ok)
        self.assertEqual(self.production.failed, ["release_candidate"])
        candidate = self.production.result("release_candidate")
        self.assertEqual(candidate.detail["status"], "BLOCKED")
        self.assertTrue(candidate.detail["outstanding"])
        self.assertTrue(any(
            "approved, integrated production-asset receipt" in blocker
            for blocker in candidate.detail["blockers"]
        ))
        self.assertTrue(any(
            "not observed on a running game" in blocker
            for blocker in candidate.detail["blockers"]
        ))

    def test_the_build_and_final_evaluation_share_one_source_receipt(self):
        build = self.production.result("build").detail
        final = self.production.result("reevaluate").detail
        self.assertTrue(build["compiles"])
        self.assertEqual(build["source"]["sha256"], final["source"]["sha256"])
        self.assertRegex(build["buildId"], r"^[0-9a-f]{64}$")
        self.assertRegex(build["placeSha256"], r"^[0-9a-f]{64}$")

    def test_the_brief_reached_a_genre(self):
        self.assertEqual(self.production.result("design").detail["genre"], "simulator")

    def test_the_economy_was_verified_against_the_shipped_module(self):
        detail = self.production.result("economy").detail
        self.assertTrue(detail["tierCosts"])
        self.assertIsNotNone(detail["verifiedMinutes"])

    def test_the_world_was_validated_rather_than_merely_built(self):
        self.assertTrue(self.production.result("world").detail["ok"])

    def test_the_asset_plan_saw_the_world(self):
        """A plan that ran before the world would budget for an icon and
        nothing else."""

        self.assertGreater(self.production.result("assets").detail["distinct"], 2)

    def test_the_screens_follow_the_declared_systems(self):
        screens = self.production.result("interface").detail["screens"]
        self.assertIn("shop", screens)
        self.assertIn("hud", screens)

    def test_the_run_ends_in_a_production_plan(self):
        detail = self.production.result("plan").detail
        self.assertGreater(detail["tasks"], 10)
        self.assertGreater(len(detail["stages"]), 5)

    def test_the_package_does_not_claim_to_be_a_game(self):
        """A built place without Studio evidence is still not release-ready."""

        note = self.production.to_dict()["note"]
        self.assertIn("not a release-ready game", note)
        self.assertIn("Studio runtime evidence is still required", note)


class TestPartialFailure(unittest.TestCase):
    """The property the layer exists for."""

    def test_a_returned_refusal_fails_and_cannot_satisfy_dependents(self):
        """A normal return is transport success, not a successful stage.

        Both refusal forms used by production stages are covered: an explicit
        negative verdict and a named operational block.
        """

        called: list[str] = []
        graph = (
            Stage("negative", (), lambda _context: {"ok": False}),
            Stage("after-negative", ("negative",),
                  lambda _context: called.append("after-negative") or {}),
            Stage("blocked", (),
                  lambda _context: {"blocked": "Blender is unavailable"}),
            Stage("after-blocked", ("blocked",),
                  lambda _context: called.append("after-blocked") or {}),
            Stage("independent", (),
                  lambda _context: called.append("independent") or {}),
        )

        with patch("rqe.producer.pipeline._stages", return_value=graph):
            run = produce(REPO, "A valid brief", game_id="verdict-probe")

        self.assertEqual(run.result("negative").status, FAILED)
        self.assertEqual(run.result("negative").error, "stage reported ok=false")
        self.assertEqual(run.result("blocked").status, FAILED)
        self.assertEqual(run.result("blocked").error, "Blender is unavailable")
        self.assertEqual(run.result("after-negative").status, SKIPPED)
        self.assertEqual(run.result("after-negative").blocked_by, "negative")
        self.assertEqual(run.result("after-blocked").status, SKIPPED)
        self.assertEqual(run.result("after-blocked").blocked_by, "blocked")
        self.assertEqual(run.result("independent").status, OK)
        self.assertEqual(called, ["independent"])

    def test_an_explicitly_omitted_stage_only_blocks_hard_dependents(self):
        called: list[str] = []
        graph = (
            Stage("geometry", (), lambda _context: called.append("geometry") or {}),
            Stage(
                "implement",
                (),
                lambda _context: called.append("implement") or {},
                optional_after=("geometry",),
            ),
            Stage(
                "release",
                ("geometry", "implement"),
                lambda _context: called.append("release") or {},
            ),
        )

        with patch("rqe.producer.pipeline._stages", return_value=graph):
            run = produce(
                REPO,
                "A valid brief",
                game_id="degraded-probe",
                skip_stages=("geometry",),
            )

        self.assertEqual(run.result("geometry").status, SKIPPED)
        self.assertEqual(run.result("geometry").blocked_by, "execution profile")
        self.assertEqual(run.result("implement").status, OK)
        self.assertEqual(run.result("release").status, SKIPPED)
        self.assertEqual(run.result("release").blocked_by, "geometry")
        self.assertEqual(called, ["implement"])

    def test_an_unknown_omitted_stage_is_refused(self):
        with self.assertRaisesRegex(ProducerError, "unknown stage.*typo"):
            produce(REPO, "A valid brief", game_id="skip-probe", skip_stages=("typo",))

    def test_a_failed_stage_does_not_abandon_the_run(self):
        """Run against a root with no Luau toolchain: three stages cannot work,
        and everything independent of them still must."""

        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "schemas").mkdir()
            (root / "tokens").mkdir()
            for schema in (REPO / "schemas").glob("*.json"):
                shutil.copyfile(schema, root / "schemas" / schema.name)
            for token in (REPO / "tokens").glob("*.json"):
                shutil.copyfile(token, root / "tokens" / token.name)

            run = produce(root, BRIEF, game_id="partial-probe", scaffold=True)

        self.assertFalse(run.ok)
        self.assertTrue(run.failed)
        # The work that did not depend on the toolchain survived.
        self.assertIn("design", run.completed)
        self.assertIn("content", run.completed)
        self.assertIn("interface", run.completed)
        # Plan is intentionally downstream of scaffold; a partial repository
        # may lack the operational-contract inputs scaffold now requires.
        plan = run.result("plan")
        if plan.status == SKIPPED:
            self.assertEqual(plan.blocked_by, "scaffold")

    def test_a_skipped_stage_names_what_blocked_it(self):
        """The difference between "this stage is broken" and "this stage never
        ran"."""

        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "schemas").mkdir()
            (root / "tokens").mkdir()
            for schema in (REPO / "schemas").glob("*.json"):
                shutil.copyfile(schema, root / "schemas" / schema.name)
            for token in (REPO / "tokens").glob("*.json"):
                shutil.copyfile(token, root / "tokens" / token.name)
            run = produce(root, BRIEF, game_id="partial-probe", scaffold=True)

        skipped = [item for item in run.results if item.status == SKIPPED]
        self.assertTrue(skipped)
        for item in skipped:
            self.assertTrue(item.blocked_by, item.stage)

    def test_a_stage_that_has_nothing_to_do_says_so(self):
        """A tower defense has no purchased ladder to solve. That is an answer,
        not a crash."""

        game_id = "no-curve-probe"
        shutil.rmtree(REPO / "games" / game_id, ignore_errors=True)
        try:
            run = produce(
                REPO,
                "A tower defense holding an arena through waves.",
                game_id=game_id, scaffold=False)
            economy = run.result("economy")
            self.assertIn(economy.status, (OK, FAILED))
            if economy.status == FAILED:
                self.assertIn("curve", economy.error)
        finally:
            shutil.rmtree(REPO / "games" / game_id, ignore_errors=True)

    def test_an_empty_brief_is_refused_before_the_run_starts(self):
        with self.assertRaises(ProducerError):
            produce(REPO, "   ", game_id="x")


class TestReporting(unittest.TestCase):
    def test_the_summary_marks_each_stage(self):
        game_id = "summary-probe"
        shutil.rmtree(REPO / "games" / game_id, ignore_errors=True)
        try:
            run = produce(REPO, BRIEF, game_id=game_id, scaffold=True)
            summary = run.summary()
            for stage in run.completed:
                self.assertIn(stage, summary)
        finally:
            shutil.rmtree(REPO / "games" / game_id, ignore_errors=True)

    def test_the_report_separates_failed_from_skipped(self):
        game_id = "report-probe"
        shutil.rmtree(REPO / "games" / game_id, ignore_errors=True)
        try:
            payload = produce(REPO, BRIEF, game_id=game_id, scaffold=True).to_dict()
            self.assertIn("failed", payload)
            self.assertIn("skipped", payload)
            self.assertIn("completed", payload)
        finally:
            shutil.rmtree(REPO / "games" / game_id, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
