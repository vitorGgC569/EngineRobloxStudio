"""The knowledge base.

The document asks that game #20 benefit from games #1 to #19. Half of what it
lists is available from engine-side work and half is not, and the difference is
the whole design.

Curves, layouts, budgets, system sets and failure patterns come out of real
producer runs -- decided by a layer and checked by it. Player funnels, retention
and monetization need shipped games with players, and no amount of engine work
produces them.

So the test that matters most is `test_a_category_needing_players_is_never_zero`.
An empty average for retention looks like an answer, and that is worse than
having no retention question at all.
"""

from __future__ import annotations

import shutil
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from rqe.knowledge import (
    CATEGORIES,
    FROM_ENGINE,
    FROM_LIVE,
    KnowledgeError,
    advise,
    coverage,
    failures,
    load,
    observe,
    query,
    record,
)
from rqe.producer import produce

REPO = Path(__file__).resolve().parents[1]

BRIEFS = [
    ("kb-reef-sim", "Simulator de criaturas em recifes e cavernas, com loja, "
                    "sessoes de 12 minutos."),
    ("kb-sky-sim", "Simulator de coleta nas ilhas flutuantes com loja e ranking."),
    ("kb-mine-tyc", "Tycoon de mina com automacao, esteiras e producao."),
]


class KnowledgeCase(unittest.TestCase):
    """Three real producer runs, recorded into a throwaway store."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.store = ".tmp/test-knowledge.jsonl"
        (REPO / cls.store).unlink(missing_ok=True)
        for game_id, brief in BRIEFS:
            shutil.rmtree(REPO / "games" / game_id, ignore_errors=True)
            run = produce(REPO, brief, game_id=game_id, scaffold=True)
            record(REPO, run, store=cls.store)
            shutil.rmtree(REPO / "games" / game_id, ignore_errors=True)

    @classmethod
    def tearDownClass(cls) -> None:
        (REPO / cls.store).unlink(missing_ok=True)


class TestWhatItCanKnow(KnowledgeCase):
    def test_runs_accumulate(self):
        self.assertEqual(len(load(REPO, store=self.store)), 3)

    def test_a_curve_is_measured_from_real_runs(self):
        result = query(REPO, "economy_curves", genre="simulator", store=self.store)
        self.assertEqual(result["status"], "MEASURED")
        self.assertIn("stepRatio", result["fields"])
        self.assertGreater(result["fields"]["stepRatio"]["median"], 1.0)

    def test_advice_is_scoped_to_the_genre(self):
        """A tycoon's curve is not advice for a simulator."""

        result = advise(REPO, "simulator", store=self.store)
        self.assertEqual(sorted(result["priorGames"]), ["kb-reef-sim", "kb-sky-sim"])
        self.assertNotIn("kb-mine-tyc", result["priorGames"])

    def test_list_fields_become_frequencies_rather_than_being_dropped(self):
        """"Which systems does a simulator end up needing" is the most useful
        question here, and it has no median."""

        result = query(REPO, "system_sets", genre="simulator", store=self.store)
        self.assertIn("frequencies", result)
        self.assertIn("implemented", result["frequencies"])

    def test_the_recurring_gap_surfaces(self):
        """Game #3 telling game #4 where the hole is.

        Asserted on the shape rather than on a particular system: the fixture's
        gap was `shop`, and `shop` has since been authored. A knowledge base
        whose test names one system stops testing anything the moment that
        system ships."""

        result = query(REPO, "system_sets", genre="simulator", store=self.store)
        self.assertIn("planned", result["frequencies"])
        recorded = {
            name
            for record in load(REPO, store=self.store)
            for name in ((record.facts.get("system_sets") or {}).get("planned") or ())
        }
        for name in recorded:
            self.assertIn(name, result["frequencies"]["planned"], name)

    def test_frequencies_are_counts_not_percentages(self):
        """With three records a percentage implies a precision nobody has."""

        result = query(REPO, "system_sets", genre="simulator", store=self.store)
        for value in result["frequencies"]["implemented"].values():
            self.assertIn(" of ", value)

    def test_a_world_layout_records_whether_it_validated(self):
        result = query(REPO, "world_layouts", genre="simulator", store=self.store)
        self.assertEqual(result["status"], "MEASURED")
        self.assertIn("regions", result["fields"])

    def test_advice_says_it_is_not_a_recommendation(self):
        """A median is where the engine has been, and following it without
        thinking is how twenty games become one game twenty times."""

        self.assertIn("not what is correct", advise(REPO, "simulator",
                                                    store=self.store)["note"])


class TestWhatItCannotKnow(KnowledgeCase):
    def test_a_category_needing_players_is_never_zero(self):
        """The failure this module was shaped to avoid: an empty average looks
        like an answer."""

        for category, definition in CATEGORIES.items():
            if definition.source == FROM_ENGINE:
                continue
            result = query(REPO, category, store=self.store)
            self.assertEqual(result["status"], "UNAVAILABLE", category)
            self.assertTrue(result["unlockedBy"].strip(), category)
            self.assertNotIn("fields", result)

    def test_retention_names_what_would_unlock_it(self):
        result = query(REPO, "retention_patterns", store=self.store)
        self.assertIn("shipped game", result["unlockedBy"])

    def test_advice_keeps_the_unknown_half_in_view(self):
        """Deleting these would make the base look complete and quietly stop
        anybody asking."""

        result = advise(REPO, "simulator", store=self.store)
        unknown = {item["category"] for item in result["stillUnknown"]}
        self.assertIn("retention_patterns", unknown)
        self.assertIn("player_funnels", unknown)

    def test_coverage_separates_no_data_from_unavailable(self):
        """"Nobody has recorded this yet" and "this cannot be recorded" need
        opposite actions."""

        statuses = {item["id"]: item["status"] for item in
                    coverage(REPO, store=self.store)["categories"]}
        self.assertEqual(statuses["economy_curves"], "MEASURED")
        self.assertEqual(statuses["retention_patterns"], "UNAVAILABLE")


class TestFailurePatterns(KnowledgeCase):
    def test_failures_are_recorded_by_type(self):
        """A message carries the paths and ids of one run; the pattern is what
        repeats."""

        report = failures(REPO, store=self.store)
        self.assertEqual(report["records"], 3)
        for errors in report["byStage"].values():
            for name in errors:
                self.assertNotIn("/", name)

    def test_a_stage_with_nothing_to_do_is_not_a_failure(self):
        """The mine tycoon has no zoned world. Recording that as a failure would
        make a correct design look broken."""

        report = failures(REPO, store=self.store)
        self.assertNotIn("world", report["byStage"])


class TestStore(unittest.TestCase):
    def test_an_empty_base_answers_no_data_rather_than_guessing(self):
        with TemporaryDirectory() as directory:
            result = query(Path(directory), "economy_curves", store="k.jsonl")
        self.assertEqual(result["status"], "NO_DATA")

    def test_an_unknown_category_lists_the_real_ones(self):
        with TemporaryDirectory() as directory:
            with self.assertRaises(KnowledgeError) as caught:
                query(Path(directory), "vibes", store="k.jsonl")
        self.assertIn("economy_curves", str(caught.exception))

    def test_the_store_must_stay_inside_the_project(self):
        with TemporaryDirectory() as directory:
            run = produce(REPO, BRIEFS[0][1], game_id="kb-escape", scaffold=False)
            with self.assertRaises(KnowledgeError):
                record(Path(directory), run, store="../escaped.jsonl")

    def test_writing_is_append_only(self):
        """A run is a fact about a moment; rewriting history makes "did the
        curve get steeper" unanswerable."""

        store = ".tmp/test-knowledge-append.jsonl"
        (REPO / store).unlink(missing_ok=True)
        try:
            shutil.rmtree(REPO / "games" / "kb-append", ignore_errors=True)
            run = produce(REPO, BRIEFS[0][1], game_id="kb-append", scaffold=False)
            record(REPO, run, store=store)
            record(REPO, run, store=store)
            self.assertEqual(len(load(REPO, store=store)), 2)
        finally:
            (REPO / store).unlink(missing_ok=True)
            shutil.rmtree(REPO / "games" / "kb-append", ignore_errors=True)

    def test_a_run_is_reduced_rather_than_stored_whole(self):
        """A base that stored everything would be a log, and nobody queries a
        log."""

        shutil.rmtree(REPO / "games" / "kb-observe", ignore_errors=True)
        try:
            run = produce(REPO, BRIEFS[0][1], game_id="kb-observe", scaffold=False)
            entry = observe(run)
            self.assertTrue(entry.facts)
            self.assertNotIn("stages", entry.to_dict())
        finally:
            shutil.rmtree(REPO / "games" / "kb-observe", ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
