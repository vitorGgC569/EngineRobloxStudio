"""A visual threshold must have an author independent of the candidate.

This is the third of the architectural problems raised against the gate, and the
only one the SDK was built to fix structurally rather than procedurally: art
direction lives in one file, and both the builder and the grader project from
it. These tests check the projection actually happened, and that its absence
blocks rather than passes.
"""

from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

from rqe.measurement_plan import compile_measurement_plan
from rqe.project import Project
from rqe.release_gate import _token_conformance_blockers
from rqe.token_conformance import check, projected_spec_fragment
from rqe.tokens import load_token_set


REPO = Path(__file__).resolve().parents[1]
SPEC = REPO / "contracts" / "visual" / "miners-ridge.visual-quality.v1.json"


def _tokens():
    return load_token_set(REPO, "tokens/brickfarm.json")


def _spec() -> dict:
    return json.loads(SPEC.read_text(encoding="utf-8"))


class _Plan:
    """Minimal stand-in carrying only the metadata the blocker check reads."""

    def __init__(self, metadata: dict) -> None:
        self.metadata = metadata


class TestConformanceCheck(unittest.TestCase):
    def test_the_shipped_spec_is_reported_as_divergent(self):
        """Honest baseline. This spec's numbers were typed by hand; recording
        that is the point, and quietly correcting them would hide it."""

        report = check(_spec(), _tokens())
        self.assertFalse(report.conforms)
        self.assertGreater(len(report.issues), 0)
        self.assertLess(report.coverage, 1.0)

    def test_the_building_envelope_disagreement_is_named_with_both_numbers(self):
        report = check(_spec(), _tokens())
        matches = [issue for issue in report.issues if "objectTypes.building.scale.minimumSize" in issue]
        self.assertEqual(len(matches), 1)
        self.assertIn("[8, 6, 8]", matches[0])
        self.assertIn("24.0", matches[0])

    def test_a_spec_projected_from_tokens_conforms(self):
        """The projection is round-trippable, or it is not a projection."""

        tokens = _tokens()
        fragment = projected_spec_fragment(tokens)
        spec = _spec()
        spec["palette"] = fragment["palette"]
        for type_id, definition in fragment["objectTypes"].items():
            spec.setdefault("objectTypes", {}).setdefault(type_id, {})
            spec["objectTypes"][type_id]["scale"] = {
                **spec["objectTypes"].get(type_id, {}).get("scale", {}),
                **definition["scale"],
            }
        for landmark in spec.get("landmarks", {}).values():
            landmark["maximumDistance"] = fragment["landmarkMaximumDistance"]

        report = check(spec, tokens)
        self.assertEqual(report.issues, [])
        self.assertTrue(report.conforms)
        self.assertEqual(report.coverage, 1.0)

    def test_a_single_altered_colour_is_caught(self):
        """Zero tolerance on colour is deliberate: "close enough" is how a second
        palette grows inside the first one."""

        tokens = _tokens()
        fragment = projected_spec_fragment(tokens)
        spec = _spec()
        spec["palette"] = copy.deepcopy(fragment["palette"])
        spec["palette"]["swatches"][0]["rgb"][0] += 1
        report = check(spec, tokens)
        self.assertTrue(any("is not a token role" in issue for issue in report.issues))

    def test_a_token_role_with_no_swatch_is_reported(self):
        """The other direction: the builder may paint with a role nothing grades."""

        tokens = _tokens()
        fragment = projected_spec_fragment(tokens)
        spec = _spec()
        spec["palette"] = copy.deepcopy(fragment["palette"])
        spec["palette"]["swatches"].pop()
        report = check(spec, tokens)
        self.assertTrue(any("no swatch in the visual spec" in issue for issue in report.issues))

    def test_the_report_carries_the_token_hash(self):
        tokens = _tokens()
        report = check(_spec(), tokens)
        self.assertEqual(report.to_dict()["tokenSha256"], tokens.sha256)


class TestPlanIntegration(unittest.TestCase):
    def test_the_measurement_plan_records_the_verdict(self):
        plan = compile_measurement_plan(Project.load(REPO))
        conformance = plan.metadata["tokenConformance"]
        self.assertEqual(conformance["status"], "DIVERGENT")
        self.assertEqual(conformance["tokenSet"], "tokens/brickfarm.json")
        self.assertEqual(conformance["tokenSha256"], _tokens().sha256)


class TestBlocking(unittest.TestCase):
    def test_conforming_thresholds_produce_no_blocker(self):
        blockers = _token_conformance_blockers(_Plan({"tokenConformance": {"status": "CONFORMS"}}))
        self.assertEqual(blockers, [])

    def test_a_missing_token_set_blocks(self):
        blockers = _token_conformance_blockers(
            _Plan({"tokenConformance": {"status": "NOT_DECLARED", "detail": "x"}})
        )
        self.assertEqual(len(blockers), 1)
        self.assertIn("independent of the candidate", blockers[0])

    def test_a_missing_report_blocks_rather_than_passing(self):
        """Absence of evidence is the failure mode this whole gate exists for."""

        self.assertEqual(len(_token_conformance_blockers(_Plan({}))), 1)

    def test_divergence_blocks_and_names_the_first_offenders(self):
        blockers = _token_conformance_blockers(
            _Plan({
                "tokenConformance": {
                    "status": "DIVERGENT",
                    "coverage": 0.24,
                    "issues": [f"issue {index}" for index in range(9)],
                }
            })
        )
        self.assertEqual(len(blockers), 6)
        self.assertIn("issue 0", blockers[0])
        self.assertIn("9 places", blockers[-1])

    def test_the_real_project_currently_blocks_on_this(self):
        plan = compile_measurement_plan(Project.load(REPO))
        self.assertTrue(_token_conformance_blockers(plan))


if __name__ == "__main__":
    unittest.main()
