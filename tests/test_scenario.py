from __future__ import annotations

import unittest

from rqe.scenario import ScenarioRunner, _compare


class FakeScenarioBridge:
    def actor_attach(self, _player=None):
        return {"isRealPlayer": True, "playerAttributes": {"PlotName": "PlotA"}}

    def actor_navigate_to(self, _target, _tolerance, _timeout):
        return {"success": True}


class ScenarioTruthTests(unittest.TestCase):
    def test_nil_comparison_does_not_treat_missing_as_the_string_nil(self) -> None:
        self.assertFalse(_compare(None, "!= nil")[0])
        self.assertTrue(_compare("PlotA", "!= nil")[0])
        self.assertTrue(_compare(None, "== nil")[0])

    def test_ordering_a_non_number_fails_instead_of_raising(self) -> None:
        self.assertFalse(_compare(None, ">= 100")[0])
        self.assertFalse(_compare("many", "> 1")[0])

    def test_wait_only_scenario_is_not_labeled_e2e(self) -> None:
        result = ScenarioRunner(FakeScenarioBridge()).run({
            "id": "wait-only",
            "steps": [{"wait": 0}],
        })
        self.assertEqual(result.status, "PASS")
        self.assertEqual(result.validation_level, "NOT_VALIDATED")

    def test_real_player_action_earns_e2e_level(self) -> None:
        result = ScenarioRunner(FakeScenarioBridge()).run({
            "id": "walk",
            "steps": [
                {"attach": {}},
                {"navigate_to": {"target": "game.Workspace.Goal"}},
            ],
        })
        self.assertEqual(result.status, "PASS")
        self.assertEqual(result.validation_level, "E2E_VALIDATED")

    def test_oversized_wait_fails_instead_of_reporting_unperformed_time(self) -> None:
        result = ScenarioRunner(FakeScenarioBridge()).run({
            "id": "too-long",
            "steps": [{"wait": 31}],
        })
        self.assertEqual(result.status, "FAIL")
        self.assertEqual(result.steps[0].detail["requestedSeconds"], 31)


if __name__ == "__main__":
    unittest.main()
