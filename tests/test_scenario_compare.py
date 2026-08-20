"""Comparing two scenario runs.

A scenario that only reports PASS or FAIL is a test. One whose runs can be
compared is an instrument: it says *which* step changed verdict, which is the
difference between "something broke" and "step 4 stopped finding the prompt".
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from rqe.scenario_compare import (
    ScenarioCompareError,
    compare_files,
    compare_results,
)


def _run(scenario: str, statuses: list[str], kinds: list[str] | None = None, status: str = "PASS"):
    kinds = kinds or ["spawn", "navigate_to", "interact", "assert"][: len(statuses)]
    return {
        "scenario": scenario,
        "status": status,
        "steps": [
            {"index": index, "kind": kinds[index], "status": statuses[index]}
            for index in range(len(statuses))
        ],
    }


class TestComparison(unittest.TestCase):
    def test_identical_runs_report_no_change(self):
        before = _run("purchase", ["PASS", "PASS", "PASS"])
        after = _run("purchase", ["PASS", "PASS", "PASS"])
        result = compare_results(before, after).to_dict()
        self.assertTrue(result["identical"])
        self.assertEqual(result["regressionCount"], 0)

    def test_a_step_that_stopped_passing_is_a_regression(self):
        before = _run("purchase", ["PASS", "PASS", "PASS"])
        after = _run("purchase", ["PASS", "FAIL", "PASS"], status="FAIL")
        result = compare_results(before, after).to_dict()
        self.assertEqual(result["regressionCount"], 1)
        self.assertEqual(result["regressions"][0]["index"], 1)
        self.assertEqual(result["regressions"][0]["kind"], "navigate_to")

    def test_a_step_that_started_passing_is_a_fix(self):
        """A repair loop needs to know it worked rather than assume."""

        before = _run("purchase", ["PASS", "FAIL", "PASS"], status="FAIL")
        after = _run("purchase", ["PASS", "PASS", "PASS"])
        result = compare_results(before, after).to_dict()
        self.assertEqual(result["fixCount"], 1)
        self.assertEqual(result["regressionCount"], 0)

    def test_an_edited_scenario_is_incomparable(self):
        """Comparing across an edit produces a regression report about a step
        that no longer exists."""

        before = _run("purchase", ["PASS", "PASS", "PASS"])
        after = _run("purchase", ["PASS", "PASS"])
        result = compare_results(before, after).to_dict()
        self.assertFalse(result["comparable"])
        self.assertIn("edited between runs", result["incomparableReason"])

    def test_reordered_steps_are_incomparable(self):
        before = _run("purchase", ["PASS", "PASS"], kinds=["spawn", "interact"])
        after = _run("purchase", ["PASS", "PASS"], kinds=["interact", "spawn"])
        self.assertFalse(compare_results(before, after).comparable)

    def test_two_different_scenarios_are_incomparable(self):
        before = _run("purchase", ["PASS"])
        after = _run("rejoin", ["PASS"])
        result = compare_results(before, after).to_dict()
        self.assertFalse(result["comparable"])
        self.assertIn("different scenarios", result["incomparableReason"])

    def test_a_result_without_steps_is_refused(self):
        with self.assertRaises(ScenarioCompareError):
            compare_results({"scenario": "x"}, {"scenario": "x", "steps": []})

    def test_both_a_regression_and_a_fix_are_reported(self):
        before = _run("purchase", ["PASS", "FAIL", "PASS"], status="FAIL")
        after = _run("purchase", ["FAIL", "PASS", "PASS"], status="FAIL")
        result = compare_results(before, after).to_dict()
        self.assertEqual(result["regressionCount"], 1)
        self.assertEqual(result["fixCount"], 1)

    def test_the_summary_names_the_steps(self):
        before = _run("purchase", ["PASS", "PASS"])
        after = _run("purchase", ["PASS", "FAIL"], status="FAIL")
        summary = compare_results(before, after).summary()
        self.assertIn("step 1", summary)
        self.assertIn("PASS -> FAIL", summary)

    def test_files_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "a.json").write_text(json.dumps(_run("purchase", ["PASS", "PASS"])), encoding="utf-8")
            (root / "b.json").write_text(
                json.dumps(_run("purchase", ["PASS", "FAIL"], status="FAIL")), encoding="utf-8"
            )
            result = compare_files(root / "a.json", root / "b.json")
        self.assertEqual(result["regressionCount"], 1)
        self.assertIn("summary", result)

    def test_a_missing_file_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ScenarioCompareError):
                compare_files(Path(directory) / "missing.json", Path(directory) / "also.json")


if __name__ == "__main__":
    unittest.main()
