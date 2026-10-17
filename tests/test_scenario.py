from __future__ import annotations

import contextlib
import unittest

from rqe.scenario import ScenarioRunner, _compare


class FakeScenarioBridge:
    def __init__(self) -> None:
        self.attributes = {"PlotName": "PlotA", "JoinCount": 1}

    def actor_attach(self, _player=None):
        return {"isRealPlayer": True, "playerAttributes": dict(self.attributes)}

    def player_state(self):
        return {"attributes": dict(self.attributes)}

    def actor_navigate_to(self, _target, _tolerance, _timeout):
        return {"success": True}

    def client_input(self, **params):
        return {"delivered": True, "source": "VirtualInput", "player": "Tester", **params}

    def actor_state(self):
        return {"position": [0.0, 5.0, 0.0]}

    def bounds(self, _path):
        return {"center": [0.0, 5.0, -10.0]}

    def client_camera_set(self, position, look_at, field_of_view=70.0, player=None):
        return {"applied": True, "position": position, "lookAt": look_at, "fieldOfView": field_of_view, "player": player}

    def client_camera_release(self, player=None):
        return {"released": True, "cameraType": "Custom", "player": player}


class LeaseAwareScenarioBridge(FakeScenarioBridge):
    def __init__(self) -> None:
        self.events: list[str] = []
        self.counter = 0

    @contextlib.contextmanager
    def lease_scope(self, **_kwargs):
        self.counter += 1
        lease = {"leaseId": str(self.counter)}
        self.events.append(f"acquire:{self.counter}")
        try:
            yield lease
        finally:
            self.events.append(f"release:{self.counter}")

    def renew_lease(self, lease, ttl_seconds=300):
        self.events.append(f"renew:{lease['leaseId']}")
        return dict(lease)

    def unpin(self):
        self.events.append("unpin")


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

    def test_virtual_input_is_a_real_player_action_but_does_not_fake_delivery(self) -> None:
        result = ScenarioRunner(FakeScenarioBridge()).run({
            "id": "combat-input",
            "steps": [
                {"attach": {}},
                {"input": {"action": "keys", "keys": ["F"], "duration": 0.1}},
            ],
        })
        self.assertEqual(result.status, "PASS")
        self.assertEqual(result.validation_level, "E2E_VALIDATED")
        self.assertEqual(result.steps[1].detail["source"], "VirtualInput")

    def test_invalid_input_shape_fails_closed(self) -> None:
        result = ScenarioRunner(FakeScenarioBridge()).run({
            "id": "bad-input",
            "steps": [{"attach": {}}, {"input": {"action": "keys", "keys": []}}],
        })
        self.assertEqual(result.status, "FAIL")
        self.assertIn("non-empty", result.steps[1].reason)

    def test_aim_at_uses_measured_actor_and_target_positions(self) -> None:
        result = ScenarioRunner(FakeScenarioBridge()).run({
            "id": "aim",
            "steps": [
                {"attach": {}},
                {"aim_at": {"target": "game.Workspace.Enemy"}},
                {"input": {"action": "keys", "keys": ["E"], "duration": 0.4}},
                {"release_camera": {}},
            ],
        })
        self.assertEqual(result.status, "PASS")
        self.assertEqual(result.validation_level, "E2E_VALIDATED")
        self.assertTrue(result.steps[1].detail["applied"])
        self.assertTrue(result.steps[3].detail["released"])

    def test_remembered_delta_survives_a_session_reset(self) -> None:
        bridge = FakeScenarioBridge()

        def reset():
            bridge.attributes["JoinCount"] += 1
            return {"started": True}

        result = ScenarioRunner(bridge, reset_session=reset).run({
            "id": "rejoin",
            "steps": [
                {"attach": {}},
                {"remember": {"attribute": "JoinCount", "as": "before"}},
                {"reset": {}},
                {"attach": {}},
                {"assert": {"rememberedDelta": {"JoinCount": {"from": "before", "expect": ">= 1"}}}},
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

    def test_reset_releases_old_session_fence_and_next_step_gets_a_new_one(self) -> None:
        bridge = LeaseAwareScenarioBridge()

        def reset():
            bridge.events.append("reset")
            return {"started": True}

        result = ScenarioRunner(bridge, reset_session=reset).run({
            "id": "fenced-reset",
            "steps": [{"wait": 0}, {"reset": {}}, {"wait": 0}],
        })
        self.assertEqual(result.status, "PASS")
        self.assertEqual(
            bridge.events,
            ["acquire:1", "release:1", "unpin", "reset", "acquire:2", "release:2"],
        )


if __name__ == "__main__":
    unittest.main()
